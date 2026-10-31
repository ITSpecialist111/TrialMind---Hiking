import Foundation

/// What the frontier and trip-group code throws: Kotlin's IllegalArgumentException (a `require` failing) and
/// IOException (bytes that are not a valid payload), with the same messages as on Android.
enum FrontierError: Error, Equatable, CustomStringConvertible {
    case illegalArgument(String)
    case io(String)

    var description: String {
        switch self {
        case .illegalArgument(let message): return "IllegalArgumentException: " + message
        case .io(let message): return "IOException: " + message
        }
    }

    /// Kotlin's `require`.
    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw FrontierError.illegalArgument(message()) }
    }
}

/// Kotlin string and collection behaviour the frontier code relies on, so texts, names and codes come out exactly as
/// on Android. Kotlin strings are UTF-16, so these work on UTF-16 code units.
enum FrontierCompat {
    /// Kotlin's `Char.isWhitespace()`: Java whitespace or any Unicode space, line or paragraph separator.
    static func isWhitespace(_ unit: UInt16) -> Bool {
        if (0x09...0x0D).contains(unit) || (0x1C...0x1F).contains(unit) { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// Kotlin's `String.trim()`.
    static func trim(_ text: String) -> String {
        let units = Array(text.utf16)
        var start = 0
        var end = units.count
        while start < end && isWhitespace(units[start]) { start += 1 }
        while end > start && isWhitespace(units[end - 1]) { end -= 1 }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    /// Kotlin's `String.isBlank()`.
    static func isBlank(_ text: String) -> Bool { text.utf16.allSatisfy(isWhitespace) }

    /// Kotlin's `String.length`: UTF-16 code units.
    static func length(_ text: String) -> Int { text.utf16.count }

    /// The sign of Kotlin's `String.compareTo`, which orders by UTF-16 code unit.
    static func compare(_ a: String, _ b: String) -> Int {
        if a.utf16.elementsEqual(b.utf16) { return 0 }
        return a.utf16.lexicographicallyPrecedes(b.utf16) ? -1 : 1
    }

    /// Kotlin's `sortedWith`, which is stable: elements the comparator ranks equal keep their order.
    static func stableSorted<T>(_ items: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Lower-case hex, as Kotlin's `joinToString("") { "%02x".format(it) }`.
    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
