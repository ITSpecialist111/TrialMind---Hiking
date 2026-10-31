#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A trip group's secret, written as 16 Crockford base32 characters ("K7QM-2XRA-9PTW-4HNE"). The first 75 bits are
/// random and the last 5 are a check, so most typing mistakes are rejected instead of silently joining an empty group.
struct GroupCode: Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let length = 16
    /// Kotlin's `BYTES` (renamed so it can't be mistaken for the `bytes` of a code).
    static let byteCount = 10
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf16)

    private let raw: [UInt8]

    private init(_ raw: [UInt8]) { self.raw = raw }

    var bytes: [UInt8] { raw }

    /// The 16 characters without separators.
    var text: String { GroupCode.encode(raw) }

    /// For reading out and typing: four groups of four.
    var formatted: String {
        let units = Array(text.utf16)
        return stride(from: 0, to: units.count, by: 4)
            .map { String(decoding: units[$0..<min($0 + 4, units.count)], as: UTF16.self) }
            .joined(separator: "-")
    }

    /// Never the code itself, so it can't end up in a log.
    var description: String { "GroupCode(****)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    static func generate(_ random: SecureRandom = SecureRandom()) -> GroupCode {
        GroupCode(withCheck(random.nextBytes(byteCount)))
    }

    /// Accepts any case, spaces and dashes, and the usual look-alikes (O for 0, I and L for 1). Nil if invalid.
    static func parse(_ input: String) -> GroupCode? {
        let chars = input.uppercased().utf16
            .filter { $0 != 0x2D && !FrontierCompat.isWhitespace($0) }
            .map { c -> UInt16 in
                switch c {
                case 0x4F: return 0x30 // O -> 0
                case 0x49, 0x4C: return 0x31 // I, L -> 1
                default: return c
                }
            }
        if chars.count != length { return nil }
        var b = [UInt8](repeating: 0, count: byteCount)
        var bit = 0
        for c in chars {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            for i in stride(from: 4, through: 0, by: -1) {
                if (v >> i) & 1 == 1 { b[bit / 8] |= UInt8(0x80 >> (bit % 8)) }
                bit += 1
            }
        }
        return withCheck(b) == b ? GroupCode(b) : nil
    }

    /// The last 5 bits become the first 5 bits of the SHA-256 of the code with those bits cleared.
    private static func withCheck(_ input: [UInt8]) -> [UInt8] {
        var b = input
        b[byteCount - 1] &= 0xE0
        let digest = Array(SHA256.hash(data: b))
        b[byteCount - 1] |= digest[0] >> 3
        return b
    }

    private static func encode(_ b: [UInt8]) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(length)
        for i in 0..<length {
            var v = 0
            for j in 0..<5 {
                let bit = i * 5 + j
                v = (v << 1) | ((Int(b[bit / 8]) >> (7 - bit % 8)) & 1)
            }
            units.append(alphabet[v])
        }
        return String(decoding: units, as: UTF16.self)
    }
}
