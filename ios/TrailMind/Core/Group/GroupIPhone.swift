#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What iPhones add to the trip-group protocol. iOS doesn't let apps fill Bluetooth advertisements, so iPhones carry the
/// group between themselves over MultipeerConnectivity (peer-to-peer Wi-Fi and Bluetooth, no network needed), still as
/// the Android advert payload (`GroupAdvert`), so the frames, sealing, relaying and tags are one protocol.
enum GroupIPhone {
    /// MultipeerConnectivity service type (Info.plist NSBonjourServices: _trailmind-grp._tcp and ._udp).
    static let serviceType = "trailmind-grp"
    /// Position-frame capability: this iPhone can be found up close with Nearby Interaction (UWB between iPhones).
    /// Android defines the bits up to 32 and ignores this one.
    static let capNearbyInteraction = 64
    /// `RangeFrame.configId` of a Nearby Interaction find (Android's raw UWB configurations are 1 and 3).
    static let configNearbyInteraction = 0x4E
}

/// The tag an iPhone puts in its MultipeerConnectivity discovery info: the group's rotating Bluetooth tag, so only the
/// group recognises it, it changes every 15 minutes, and the group id itself is never broadcast.
enum GroupPeerTag {
    static let key = "t"

    static func value(_ keys: GroupKeys, unixSeconds: Int64) -> String {
        FrontierCompat.hex(keys.tag(GroupKeys.epoch(unixSeconds)))
    }

    /// Whether `value` is this group's tag now or in either neighbouring epoch (clocks up to 15 minutes apart).
    static func matches(_ keys: GroupKeys, _ value: String?, unixSeconds: Int64) -> Bool {
        guard let value, let bytes = unhex(value), bytes.count == GroupKeys.tagBytes else { return false }
        return keys.matches(bytes, offset: 0, unixSeconds: unixSeconds)
    }

    static func unhex(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
}

/// Which of two group iPhones that found each other sends the invitation, so they don't both invite at once: the one
/// that isn't advertising (the other can't see it), or else the one whose random peer name sorts first. Discovery can
/// be one-sided for a while, so once `fallbackS` has passed without a connection the other phone invites too.
enum GroupPeerInvite {
    static let fallbackS: Double = 12

    static func shouldInvite(advertising: Bool, myName: String, peerName: String, waitedS: Double) -> Bool {
        !advertising || myName < peerName || waitedS >= fallbackS
    }
}

/// A Nearby Interaction discovery token for one UWB find between iPhones, sealed for the group and sent over their
/// direct link. Each iPhone needs the other's token, which is far bigger than a 30-byte frame, so it travels beside the
/// find's `RangeFrame`s (asked, answered and stopped in the adverts exactly as on Android) rather than in them.
struct GroupTokenMessage: Hashable {
    /// First byte. Adverts start with `GroupAdvert.version`, so neither can be taken for the other.
    static let marker: UInt8 = 0x4E
    static let fromFinder = 1
    static let fromFound = 2
    static let headerBytes = 1 + GroupKeys.tagBytes
    static let nonceBytes = 12
    static let tagBytes = 16
    static let fieldBytes = 1 + 4 + 4 + 8
    static let maxTokenBytes = 4_096

    var kind: Int
    var memberId: Int
    var targetId: Int
    /// The find's nonce, as in its `RangeFrame`s.
    var nonce: Int64
    var token: [UInt8]

    /// Marker and group tag (also authenticated), a random nonce, then the AES-GCM sealed fields and token.
    func seal(_ keys: GroupKeys, unixSeconds: Int64, random: SecureRandom = SecureRandom()) throws -> [UInt8] {
        try FrontierError.require(
            kind == GroupTokenMessage.fromFinder || kind == GroupTokenMessage.fromFound, "unknown token message kind \(kind)"
        )
        try FrontierError.require(!token.isEmpty && token.count <= GroupTokenMessage.maxTokenBytes, "token size out of range")
        let header = [GroupTokenMessage.marker] + keys.tag(GroupKeys.epoch(unixSeconds))
        var plain = GroupByteWriter(count: GroupTokenMessage.fieldBytes + token.count)
        plain.put(kind)
        plain.putInt(memberId)
        plain.putInt(targetId)
        plain.putLong(nonce)
        plain.put(token)
        let nonceBytes = random.nextBytes(GroupTokenMessage.nonceBytes)
        let box = try AES.GCM.seal(
            plain.bytes, using: SymmetricKey(data: GroupTokenMessage.key(keys)), nonce: AES.GCM.Nonce(data: nonceBytes),
            authenticating: header
        )
        return header + nonceBytes + Array(box.ciphertext) + Array(box.tag)
    }

    /// The message in `bytes` if it was sealed for this group in this or a neighbouring epoch, else nil.
    static func open(_ keys: GroupKeys, _ bytes: [UInt8], unixSeconds: Int64) -> GroupTokenMessage? {
        guard bytes.count > headerBytes + nonceBytes + tagBytes + fieldBytes, bytes[0] == marker,
              keys.matches(bytes, offset: 1, unixSeconds: unixSeconds) else { return nil }
        let header = Array(bytes[0..<headerBytes])
        let body = Array(bytes[(headerBytes + nonceBytes)...])
        guard let nonce = try? AES.GCM.Nonce(data: bytes[headerBytes..<(headerBytes + nonceBytes)]),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body.dropLast(tagBytes), tag: body.suffix(tagBytes)),
              let opened = try? AES.GCM.open(box, using: SymmetricKey(data: key(keys)), authenticating: header) else { return nil }
        let plain = Array(opened)
        var reader = GroupByteReader(plain)
        let kind = reader.get()
        let memberId = reader.getInt()
        let targetId = reader.getInt()
        let nonceValue = reader.getLong()
        let token = Array(plain.dropFirst(fieldBytes))
        guard kind == fromFinder || kind == fromFound, !token.isEmpty else { return nil }
        return GroupTokenMessage(kind: kind, memberId: memberId, targetId: targetId, nonce: nonceValue, token: token)
    }

    /// A key of its own from the group's UWB key material, so these never share a key with the adverts.
    static func key(_ keys: GroupKeys) -> [UInt8] { Hkdf.expand(keys.uwbKey, Array("iphone nearby token".utf8), 16) }
}

/// The group code at rest: sealed with AES-256-GCM under a key kept in the iPhone's Keychain, laid out as Android's
/// GroupKeyStore writes it (12-byte nonce, ciphertext, 16-byte tag).
enum GroupCodeVault {
    static let keyBytes = 32
    static let nonceBytes = 12
    static let tagBytes = 16

    static func newKey(_ random: SecureRandom = SecureRandom()) -> [UInt8] { random.nextBytes(keyBytes) }

    static func wrap(_ plain: [UInt8], key: [UInt8], random: SecureRandom = SecureRandom()) throws -> [UInt8] {
        try FrontierError.require(key.count == keyBytes, "group code key must be \(keyBytes) bytes")
        let nonce = random.nextBytes(nonceBytes)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
        return nonce + Array(box.ciphertext) + Array(box.tag)
    }

    /// Nil if `key` isn't the one it was sealed with (after a restore to another phone, say): the user joins again.
    static func unwrap(_ wrapped: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard key.count == keyBytes, wrapped.count >= nonceBytes + tagBytes,
              let nonce = try? AES.GCM.Nonce(data: wrapped.prefix(nonceBytes)),
              let box = try? AES.GCM.SealedBox(
                  nonce: nonce, ciphertext: wrapped.dropFirst(nonceBytes).dropLast(tagBytes), tag: wrapped.suffix(tagBytes)
              ),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return Array(plain)
    }
}
