import Foundation

/// A what3words address: the three words, the middle and corners of its 3 m square, and the nearest place
/// (data/What3words.kt `Address`).
struct What3wordsAddress: Hashable {
    var words: String
    var position: LatLon
    var southwest: LatLon
    var northeast: LatLon
    var nearby: String

    func contains(_ point: LatLon) -> Bool {
        point.lat >= southwest.lat && point.lat < northeast.lat && point.lon >= southwest.lon && point.lon < northeast.lon
    }
}

/// Why a what3words look-up failed, in words for the user (Android's IOException messages, all starting "what3words:").
struct What3wordsError: Error, Equatable, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Requests and responses for the what3words API (data/What3words.kt). TrailMind looks up only when the user asks: never
/// from tracking or emergency flows, which must not wait for the network. The app sends the request with the user's key
/// in `X-Api-Key` and TrailMind's User-Agent, does not follow redirects, and reads at most `maxResponseBytes`.
enum What3wordsApi {
    static let base = "https://api.what3words.com/v3/"
    static let maxResponseBytes = 32_768
    static let connectTimeoutS = 8.0
    static let readTimeoutS = 10.0
    /// A position look-up needs a fix at most this old; its answer is shared only while this fresh (ThreeWordAddress.canShare).
    static let freshMs: Int64 = 60_000

    static let needKey = "what3words: add your API key in Settings first. Your plan must allow both conversions."
    static let needFreshFix = "what3words: wait for a fresh GPS fix before looking up your position."
    static let needThreeWords = "what3words: enter three words separated by dots, such as ///filled.count.soap."
    static let wrongAddress = "what3words: response did not match the requested address."
    static let wrongLocation = "what3words: response did not match the requested location."
    static let cancelled = "what3words: lookup cancelled."
    static let tooLarge = "what3words: response was too large."
    static let couldNotConnect = "what3words: could not connect. Coordinates and grid references still work offline."
    static let conversionFailed = "what3words: conversion failed. Check the address and your API plan."
    static let invalidCoordinates = "what3words: invalid coordinates in response."
    static let invalidAddress = "what3words: invalid address in response."
    static let invalidSquare = "what3words: invalid square in response."
    static let unreadable = "what3words: unreadable service response."

    /// The convert-to-3wa request for a position, answered in English.
    static func locateURL(_ lat: Double, _ lon: Double) -> String {
        base + "convert-to-3wa?coordinates=" + formEncode(decimal(lat) + "," + decimal(lon)) + "&language=en"
    }

    /// The convert-to-coordinates request for typed words (with or without "///"), and the words it asks for.
    static func searchURL(_ input: String) throws -> (url: String, words: String) {
        guard let words = ThreeWordAddress.normalize(input) else { throw What3wordsError(needThreeWords) }
        return (base + "convert-to-coordinates?words=" + formEncode(words), words)
    }

    static func checkKey(_ key: String) throws {
        if KotlinText.isBlank(key) { throw What3wordsError(needKey) }
    }

    /// Only a fix from the last minute is looked up, so the three words name where you are now.
    static func checkFresh(fixMs: Int64, nowMs: Int64) throws {
        if !(0...freshMs).contains(nowMs - fixMs) { throw What3wordsError(needFreshFix) }
    }

    /// What to tell the user about an HTTP status other than 200, or nil for 200.
    static func statusMessage(_ code: Int) -> String? {
        switch code {
        case 200: return nil
        case 400, 404: return "what3words: address not found. Check all three words; spelling changes can point to a different country."
        case 401, 402, 403: return "what3words: check your API key, plan and conversion permissions in Settings."
        case 429: return "what3words: request limit reached. Try again later."
        default: return "what3words: service returned HTTP \(code). Use coordinates or a grid reference instead."
        }
    }

    /// A position look-up's answer must be the square the position is in.
    static func checkLocated(_ address: What3wordsAddress, _ lat: Double, _ lon: Double) throws {
        if !address.contains(LatLon(lat, lon)) { throw What3wordsError(wrongLocation) }
    }

    /// A search's answer must be the address asked for.
    static func checkSearched(_ address: What3wordsAddress, _ words: String) throws {
        if address.words != words { throw What3wordsError(wrongAddress) }
    }

    /// Reads a convert-to-3wa or convert-to-coordinates response, with the same checks (in the same order) as Android.
    static func parseResponse(_ body: String) throws -> What3wordsAddress {
        guard let data = body.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let json) = root else { throw What3wordsError(unreadable) }
        if json["error"] != nil { throw What3wordsError(conversionFailed) }
        guard let wordsValue = json["words"] else { throw What3wordsError(unreadable) }
        guard case .string(let rawWords) = wordsValue, let words = ThreeWordAddress.normalize(rawWords) else {
            throw What3wordsError(invalidAddress)
        }
        let square = try object(json["square"])
        let position = try point(try object(json["coordinates"]))
        let southwest = try point(try object(square["southwest"]))
        let northeast = try point(try object(square["northeast"]))
        let result = What3wordsAddress(words: words, position: position, southwest: southwest, northeast: northeast,
                                       nearby: optString(json["nearestPlace"]))
        if !result.contains(result.position) { throw What3wordsError(invalidSquare) }
        return result
    }

    /// `java.net.URLEncoder.encode(s, "UTF-8")`: letters, digits and `.-*_` stay, a space becomes `+`, every other
    /// UTF-8 byte becomes `%XX`.
    static func formEncode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "):
                out += "+"
            default:
                out += "%" + String(byte, radix: 16, uppercase: true).padStart(2, "0")
            }
        }
        return out
    }

    /// A coordinate in plain decimals with all its digits, as Kotlin prints a Double, but never in E notation (Kotlin
    /// writes 0.0005 as "5.0E-4"), so positions beside the Greenwich meridian or the equator ask for the right square.
    static func decimal(_ x: Double) -> String {
        let s = "\(x)"
        guard s.contains("e") || s.contains("E") else { return s }
        var t = javaFixed(x, 12)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t += "0" }
        return t
    }

    // MARK: JSON, read as Android's org.json reads these fields

    private static func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let o)? = value else { throw What3wordsError(unreadable) }
        return o
    }

    private static func point(_ o: [String: JSONValue]) throws -> LatLon {
        let lat = try number(o["lat"])
        let lon = try number(o["lng"])
        if !lat.isFinite || !lon.isFinite || !(-90.0...90.0).contains(lat) || !(-180.0...180.0).contains(lon) {
            throw What3wordsError(invalidCoordinates)
        }
        return LatLon(lat, lon)
    }

    /// `JSONObject.getDouble`: a number, or a string that reads as one.
    private static func number(_ value: JSONValue?) throws -> Double {
        switch value {
        case .number(let d)?: return d
        case .string(let s)?:
            if let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
            throw What3wordsError(unreadable)
        default: throw What3wordsError(unreadable)
        }
    }

    /// `JSONObject.optString`: empty when missing.
    private static func optString(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s)?: return s
        case .number(let d)?: return "\(d)"
        case .bool(let b)?: return b ? "true" : "false"
        case .null?: return "null"
        default: return ""
        }
    }

    private enum JSONValue: Decodable {
        case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
            self = .object(try c.decode([String: JSONValue].self))
        }
    }
}
