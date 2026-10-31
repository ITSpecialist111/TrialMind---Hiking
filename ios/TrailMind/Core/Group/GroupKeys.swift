#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// HKDF with HMAC-SHA256 (RFC 5869), written out step by step as on Android so both phones derive the same keys.
enum Hkdf {
    private static let hashBytes = 32

    static func extract(_ salt: [UInt8], _ ikm: [UInt8]) -> [UInt8] {
        hmac(salt.isEmpty ? [UInt8](repeating: 0, count: hashBytes) : salt, ikm)
    }

    /// `length` is always a constant in TrailMind, so a bad one is a programming error (Kotlin's `require`).
    static func expand(_ prk: [UInt8], _ info: [UInt8], _ length: Int) -> [UInt8] {
        precondition((1...255 * hashBytes).contains(length), "bad HKDF length \(length)")
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var t: [UInt8] = []
        var i = 1
        while out.count < length {
            t = hmac(prk, t + info + [UInt8(truncatingIfNeeded: i)])
            out += t.prefix(length - out.count)
            i += 1
        }
        return out
    }

    static func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

/// Keys derived from a group code: a local id, the frame encryption key and the key for the rotating group tag.
final class GroupKeys {
    static let epochSeconds: Int64 = 900
    static let tagBytes = 4
    private static let salt = Array("TrailMind group v1".utf8)

    private let secret: [UInt8]
    /// Identifies the group in this phone's database. Never broadcast.
    let groupId: String
    let encKey: [UInt8]
    let uwbKey: [UInt8]
    private let tagKey: [UInt8]
    private var tags: [Int64: [UInt8]] = [:]
    private let lock = NSLock()

    init(_ code: GroupCode) {
        secret = Hkdf.extract(GroupKeys.salt, code.bytes)
        groupId = FrontierCompat.hex(Hkdf.expand(secret, Array("id".utf8), 8))
        encKey = Hkdf.expand(secret, Array("enc".utf8), 16)
        uwbKey = Hkdf.expand(secret, Array("uwb".utf8), 32)
        tagKey = Hkdf.expand(secret, Array("tag".utf8), 32)
    }

    /// The `tagBytes`-byte tag the group's advertisements carry during `epoch`.
    func tag(_ epoch: Int64) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = tags[epoch] { return cached }
        if tags.count >= 8 { tags.removeAll() }
        // Kotlin's `epoch.toInt()`: the low 32 bits, big-endian.
        let e = UInt32(truncatingIfNeeded: epoch)
        let message = [UInt8(truncatingIfNeeded: e >> 24), UInt8(truncatingIfNeeded: e >> 16), UInt8(truncatingIfNeeded: e >> 8), UInt8(truncatingIfNeeded: e)]
        let tag = Array(Hkdf.hmac(tagKey, message).prefix(GroupKeys.tagBytes))
        tags[epoch] = tag
        return tag
    }

    /// Whether the tag at `offset` in `payload` is this group's for the epoch of `unixSeconds` or either neighbour,
    /// which allows for phone clocks up to a quarter of an hour apart.
    func matches(_ payload: [UInt8], offset: Int, unixSeconds: Int64) -> Bool {
        if payload.count < offset + GroupKeys.tagBytes { return false }
        let now = GroupKeys.epoch(unixSeconds)
        return (now - 1...now + 1).contains { e in
            let t = tag(e)
            return (0..<GroupKeys.tagBytes).allSatisfy { payload[offset + $0] == t[$0] }
        }
    }

    /// Java's `Math.floorDiv(unixSeconds, EPOCH_SECONDS)`.
    static func epoch(_ unixSeconds: Int64) -> Int64 {
        let q = unixSeconds / epochSeconds
        return unixSeconds % epochSeconds != 0 && unixSeconds < 0 ? q - 1 : q
    }
}

/// Where group codes and advert nonces get their random bytes: Kotlin's `SecureRandom`. `SecureRandom()` is the
/// system's cryptographically secure generator; tests can pass a fixed source so their bytes repeat.
struct SecureRandom {
    private let source: (Int) -> [UInt8]

    /// `SystemRandomNumberGenerator`, which is cryptographically secure on every platform Swift supports.
    init() {
        source = { count in
            var generator = SystemRandomNumberGenerator()
            var out: [UInt8] = []
            out.reserveCapacity(count)
            while out.count < count {
                var word = generator.next()
                for _ in 0..<min(8, count - out.count) {
                    out.append(UInt8(truncatingIfNeeded: word))
                    word >>= 8
                }
            }
            return out
        }
    }

    /// A source that returns exactly the requested number of bytes.
    init(_ nextBytes: @escaping (Int) -> [UInt8]) { source = nextBytes }

    func nextBytes(_ count: Int) -> [UInt8] {
        let bytes = source(count)
        precondition(bytes.count == count, "random source returned \(bytes.count) bytes, not \(count)")
        return bytes
    }
}
