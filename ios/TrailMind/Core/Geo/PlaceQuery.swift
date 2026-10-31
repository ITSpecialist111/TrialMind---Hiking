import Foundation

enum PlaceQuery {
    // The Kotlin patterns spelled out for ICU: Java's `\d` and `\s` are ASCII only, and Kotlin's IGNORE_CASE (Java's
    // CASE_INSENSITIVE with UNICODE_CASE) lets [A-Z] also match ı and ſ, and S match ſ, where ICU's would differ.
    private static let space = #"[ \t\n\x0B\f\r]"#
    private static let decimal = entire(
        #"^([+-]?[0-9]+(?:\.[0-9]+)?)\#(space)*([NnSs\x{17F}])?(?:\#(space)*,\#(space)*|\#(space)+)([+-]?[0-9]+(?:\.[0-9]+)?)\#(space)*([EeWw])?$"#)
    private static let gridLike = entire(#"^[A-Za-z\x{131}\x{17F}]{2}[0-9 \t\n\x0B\f\r]+$"#)

    static func looksLikeCoordinates(_ text: String) -> Bool { matchEntire(decimal, trim(text)) != nil }
    static func looksLikeGrid(_ text: String) -> Bool { matchEntire(gridLike, trim(text)) != nil }

    static func coordinates(_ text: String) -> LatLon? {
        guard let match = matchEntire(decimal, trim(text)) else { return nil }
        guard let lat = Double(match[1]) else { return nil }
        guard let lon = Double(match[3]) else { return nil }
        let ns = match[2].uppercased()
        let ew = match[4].uppercased()
        if (!ns.isEmpty && lat < 0) || (!ew.isEmpty && lon < 0) { return nil }
        let latitude = ns == "S" ? -lat : lat
        let longitude = ew == "W" ? -lon : lon
        return (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude) ? LatLon(latitude, longitude) : nil
    }

    private static func trim(_ text: String) -> String { KotlinText.trim(text) }

    /// Kotlin's `Regex.matches`/`matchEntire`: the pattern must match all of the text.
    private static func entire(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"\A(?:"# + pattern + #")\z"#)
    }

    /// The group values of a match of all of `text` ("" for a group that took no part), as Kotlin's `groupValues`.
    private static func matchEntire(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }
}
