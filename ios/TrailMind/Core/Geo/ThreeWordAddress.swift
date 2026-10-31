import Foundation

enum ThreeWordAddress {
    private static let words = try! NSRegularExpression(
        pattern: #"\A(?:[\p{L}]+(?:[-'][\p{L}]+)*\.[\p{L}]+(?:[-'][\p{L}]+)*\.[\p{L}]+(?:[-'][\p{L}]+)*)\z"#)

    static func normalize(_ input: String) -> String? {
        let value = lowercase(removePrefix(KotlinText.trim(input), "///"))
        return value.utf16.count <= 100 && words.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            ? value : nil
    }

    static func looksLike(_ input: String) -> Bool {
        KotlinText.trim(input).unicodeScalars.starts(with: "///".unicodeScalars) || normalize(input) != nil
    }

    static func canShare(_ lookupFixMs: Int64, _ currentFixMs: Int64, _ nowMs: Int64, _ sameSquare: Bool) -> Bool {
        sameSquare && (0...60_000).contains(nowMs - lookupFixMs) && (0...60_000).contains(nowMs - currentFixMs)
    }

    /// Kotlin's `removePrefix`, which compares chars rather than Swift's grapheme clusters.
    private static func removePrefix(_ s: String, _ prefix: String) -> String {
        s.unicodeScalars.starts(with: prefix.unicodeScalars)
            ? String(Substring(s.unicodeScalars.dropFirst(prefix.unicodeScalars.count))) : s
    }

    /// Kotlin's `lowercase(Locale.ROOT)`: Swift's `lowercased()` plus Java's Greek final sigma, which Swift leaves out.
    /// Java makes Σ final when a cased letter comes before it and none after it within the word, and an address's dots,
    /// hyphens and apostrophes all sit inside one word.
    private static func lowercase(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        let firstCased = scalars.firstIndex { $0.properties.isCased }
        let lastCased = scalars.lastIndex { $0.properties.isCased }
        var out = String.UnicodeScalarView()
        for (i, c) in scalars.enumerated() {
            if c == "\u{3A3}", let first = firstCased, first < i, i == lastCased {
                out.append("\u{3C2}")
            } else {
                out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }
}
