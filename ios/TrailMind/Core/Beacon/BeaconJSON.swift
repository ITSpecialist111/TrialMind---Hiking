import Foundation

/// The `org.json` readings the Android app makes of Open-Meteo's and Strava's answers (`optString`, `optLong`, `isNull`,
/// `getLong`...), applied to `JSONSerialization` output, so a missing, null or oddly typed field comes out the same on
/// both platforms.
enum BeaconJSON {
    struct Malformed: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// `JSONObject(text)`: the top-level object, or throws.
    static func object(_ data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw Malformed("The answer wasn't JSON.")
        }
        guard let object = value as? [String: Any] else { throw Malformed("The answer wasn't a JSON object.") }
        return object
    }

    /// `JSONObject(text)` that gives nil instead of throwing.
    static func optObject(_ data: Data) -> [String: Any]? { try? object(data) }

    /// `isNull(name)`: missing or a JSON null.
    static func isNull(_ value: Any?) -> Bool { value == nil || value is NSNull }

    /// `optString(name)`: a string as it is, any other value as text (a JSON null reads "null", as in org.json), and ""
    /// when missing.
    static func optString(_ object: [String: Any], _ key: String) -> String { string(object[key]) ?? "" }

    /// `optLong(name, fallback)`.
    static func optLong(_ object: [String: Any], _ key: String, _ fallback: Int64 = 0) -> Int64 { long(object[key]) ?? fallback }

    /// `optBoolean(name, fallback)`.
    static func optBoolean(_ object: [String: Any], _ key: String, _ fallback: Bool = false) -> Bool {
        boolean(object[key]) ?? fallback
    }

    /// `getLong(name)`: throws when missing or not a number.
    static func getLong(_ object: [String: Any], _ key: String) throws -> Int64 {
        guard let value = long(object[key]) else { throw Malformed("No number for \(key).") }
        return value
    }

    /// `getDouble(name)`: throws when missing or not a number.
    static func getDouble(_ object: [String: Any], _ key: String) throws -> Double {
        guard let value = double(object[key]) else { throw Malformed("No number for \(key).") }
        return value
    }

    /// `getString(name)`: throws when missing or null.
    static func getString(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key], !(value is NSNull), let text = string(value) else { throw Malformed("No text for \(key).") }
        return text
    }

    // MARK: - org.json's JSON.toString / toLong / toDouble / toBoolean

    /// `JSON.toString`: nil only for a missing value.
    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return "null" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if isBoolean(number) { return number.boolValue ? "true" : "false" }
            return isFloating(number) ? javaDouble(number.doubleValue) : String(number.int64Value)
        }
        return "\(value)"
    }

    /// `JSON.toLong`: a number (a fraction cut towards zero) or numeric text; nil for anything else, true and false
    /// included.
    static func long(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return parseJavaDouble(text).map(kTruncateL) }
        if let number = value as? NSNumber {
            if isBoolean(number) { return nil }
            return isFloating(number) ? kTruncateL(number.doubleValue) : number.int64Value
        }
        return nil
    }

    /// `JSON.toDouble`: a number or numeric text; nil for anything else.
    static func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return parseJavaDouble(text) }
        if let number = value as? NSNumber {
            if isBoolean(number) { return nil }
            return number.doubleValue
        }
        return nil
    }

    /// `JSON.toBoolean`: true or false, or the text "true"/"false" in any case.
    static func boolean(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String {
            switch text.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        if let number = value as? NSNumber, isBoolean(number) { return number.boolValue }
        return nil
    }

    /// `Double.parseDouble`: surrounding spaces and control characters are ignored, as Java does.
    static func parseJavaDouble(_ text: String) -> Double? {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
        while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
        guard !scalars.isEmpty else { return nil }
        return Double(String(scalars))
    }

    /// Java's `Double.toString`: plain decimals from 10⁻³ up to 10⁷ ("54.46", "100.0"), and "5.0E-4" or "1.25E7"
    /// outside that, with the fewest digits that read back as the same double.
    static func javaDouble(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let magnitude = abs(d)
        let sign = d < 0 ? "-" : ""
        if magnitude >= 1e-3 && magnitude < 1e7 {
            let plain = "\(magnitude)"
            // Swift writes this range without an exponent too; make sure of it before trusting it.
            if !plain.contains("e") { return sign + (plain.contains(".") ? plain : plain + ".0") }
        }
        let (digits, exponent) = shortestDigits(magnitude)
        if magnitude >= 1e-3 && magnitude < 1e7 {
            let point = exponent + 1
            if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
            if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) + ".0" }
            let i = digits.index(digits.startIndex, offsetBy: point)
            return sign + String(digits[..<i]) + "." + String(digits[i...])
        }
        let first = String(digits.prefix(1))
        let rest = String(digits.dropFirst())
        return sign + first + "." + (rest.isEmpty ? "0" : rest) + "E" + String(exponent)
    }

    /// The shortest round-tripping significant digits of a positive finite `x`, and the power of ten of the first.
    private static func shortestDigits(_ x: Double) -> (digits: String, exponent: Int) {
        let text = "\(x)"
        var mantissa = text
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[..<e])
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0])
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        var all = Array(whole + fraction)
        var leadingZeros = 0
        while all.count > 1, all.first == "0" { all.removeFirst(); leadingZeros += 1 }
        while all.count > 1, all.last == "0" { all.removeLast() }
        exponent += whole.count - 1 - leadingZeros
        return (String(all), exponent)
    }

    /// JSON true and false arrive as NSNumber booleans ("c", a C char), which no JSON number is read as.
    private static func isBoolean(_ number: NSNumber) -> Bool { String(cString: number.objCType) == "c" }

    private static func isFloating(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "d" || type == "f"
    }
}
