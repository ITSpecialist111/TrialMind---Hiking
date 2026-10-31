#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The service data TrailMind puts in its Bluetooth advertisements: a version byte, the group's rotating tag, then one
/// to `maxFrames` frames, each sealed with AES-128-GCM under its own random nonce. Without the group code nothing in
/// it is readable, and the tag changes every `GroupKeys.epochSeconds` so the group can't be followed for long.
///
/// Byte for byte what Android sends and reads: each sealed frame is nonce, ciphertext, then the first 96 bits of the
/// GCM tag (Java's `GCMParameterSpec(96, nonce)`), and the version and group tag are the additional authenticated data.
enum GroupAdvert {
    /// 128-bit service-data UUID. 16-bit UUIDs are assigned by the Bluetooth SIG, so TrailMind uses its own random one.
    static let serviceUuid = "79085c44-3375-4f46-b449-c00580560a2b"
    static let version = 1
    static let headerBytes = 1 + GroupKeys.tagBytes
    static let nonceBytes = 12
    static let tagBits = 96
    static let sealedBytes = nonceBytes + GroupFrames.size + tagBits / 8
    static let maxFrames = 3

    /// What the service-data AD structure adds around the payload: length, type and the 128-bit UUID.
    static let adOverhead = 2 + 16

    /// How many frames fit in one advertisement when the controller takes up to `maxAdvertisingDataBytes`.
    static func maxFrames(_ maxAdvertisingDataBytes: Int) -> Int {
        ((maxAdvertisingDataBytes - adOverhead - headerBytes) / sealedBytes).clamped(0, GroupAdvert.maxFrames)
    }

    static func build(
        _ keys: GroupKeys, unixSeconds: Int64, frames: [any GroupFrame], random: SecureRandom = SecureRandom()
    ) throws -> [UInt8] {
        try FrontierError.require((1...maxFrames).contains(frames.count), "1 to \(maxFrames) frames per advertisement")
        var out = [UInt8](repeating: 0, count: headerBytes + frames.count * sealedBytes)
        out[0] = UInt8(truncatingIfNeeded: version)
        out.replaceSubrange(1..<headerBytes, with: keys.tag(GroupKeys.epoch(unixSeconds)))
        let header = Array(out[0..<headerBytes])
        for (i, frame) in frames.enumerated() {
            let at = headerBytes + i * sealedBytes
            let nonce = random.nextBytes(nonceBytes)
            out.replaceSubrange(at..<(at + nonceBytes), with: nonce)
            out.replaceSubrange((at + nonceBytes)..<(at + sealedBytes), with: try seal(keys, nonce, header, GroupFrames.encode(frame)))
        }
        return out
    }

    struct Opened {
        let keys: GroupKeys
        let frames: [any GroupFrame]
    }

    /// The frames in `payload` for whichever of `groups` it belongs to, or nil if it isn't theirs.
    static func open<C: Collection>(_ groups: C, payload: [UInt8], unixSeconds: Int64) -> Opened? where C.Element == GroupKeys {
        let count = (payload.count - headerBytes) / sealedBytes
        if !(1...maxFrames).contains(count) || payload.count != headerBytes + count * sealedBytes { return nil }
        if Int(payload[0]) != version { return nil }
        let header = Array(payload[0..<headerBytes])
        for keys in groups {
            if !keys.matches(payload, offset: 1, unixSeconds: unixSeconds) { continue }
            var frames: [any GroupFrame] = []
            frames.reserveCapacity(count)
            for i in 0..<count {
                let at = headerBytes + i * sealedBytes
                let nonce = Array(payload[at..<(at + nonceBytes)])
                let sealed = Array(payload[(at + nonceBytes)..<(at + sealedBytes)])
                if let plain = unseal(keys, nonce, header, sealed), let frame = GroupFrames.decode(plain) {
                    frames.append(frame)
                }
            }
            if !frames.isEmpty { return Opened(keys: keys, frames: frames) }
        }
        return nil
    }

    /// Ciphertext then the 96-bit tag, as Java's AES/GCM/NoPadding writes them.
    private static func seal(_ keys: GroupKeys, _ nonce: [UInt8], _ header: [UInt8], _ plain: [UInt8]) throws -> [UInt8] {
        let box = try AES.GCM.seal(
            plain, using: SymmetricKey(data: keys.encKey), nonce: AES.GCM.Nonce(data: nonce), authenticating: header
        )
        return Array(box.ciphertext) + Array(box.tag.prefix(tagBits / 8))
    }

    /// The plaintext of a sealed frame, or nil if it fails authentication. CryptoKit can only check full 128-bit tags,
    /// so this does what Java does for a 96-bit one: GCM's CTR keystream is its own inverse, so sealing the ciphertext
    /// under the same nonce gives back the plaintext; sealing that with the header gives the full tag for exactly
    /// this ciphertext, whose first 96 bits must equal the frame's, compared in constant time. Nothing is returned
    /// unless they do.
    private static func unseal(_ keys: GroupKeys, _ nonce: [UInt8], _ header: [UInt8], _ sealed: [UInt8]) -> [UInt8]? {
        let tagLength = tagBits / 8
        guard sealed.count >= tagLength else { return nil }
        let ciphertext = Array(sealed[0..<(sealed.count - tagLength)])
        let tag = Array(sealed[(sealed.count - tagLength)...])
        do {
            let key = SymmetricKey(data: keys.encKey)
            let gcmNonce = try AES.GCM.Nonce(data: nonce)
            let plain = Array(try AES.GCM.seal(ciphertext, using: key, nonce: gcmNonce).ciphertext)
            let expected = Array(try AES.GCM.seal(plain, using: key, nonce: gcmNonce, authenticating: header).tag.prefix(tagLength))
            var difference: UInt8 = 0
            for i in 0..<tagLength { difference |= expected[i] ^ tag[i] }
            return difference == 0 ? plain : nil
        } catch {
            return nil
        }
    }
}
