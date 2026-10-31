import Foundation

/// Kotlin's whitespace, `trim()` and `isBlank()`, which differ from Swift's at the edges: Kotlin counts Java's
/// whitespace (including U+001C to U+001F) and every Unicode space, line and paragraph separator, but not U+0085,
/// one UTF-16 unit at a time.
enum KotlinText {
    /// Kotlin's `Char.isWhitespace()`.
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
        return start == 0 && end == units.count ? text : String(decoding: units[start..<end], as: UTF16.self)
    }

    /// Kotlin's `String.isBlank()`.
    static func isBlank(_ text: String) -> Bool { text.utf16.allSatisfy(isWhitespace) }
}
