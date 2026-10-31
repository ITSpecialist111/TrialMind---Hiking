import Foundation

/// what3words "convert to coordinates" for Search: explicit look-ups only, with the user's own key. The request is built
/// and the answer checked here; the app does the networking. Follows the Android app's data/What3words.kt.
enum ThreeWordsSearch {
    struct Address: Hashable {
        var words: String
        var position: LatLon
        var southwest: LatLon
        var northeast: LatLon
        var nearby: String

        func contains(_ p: LatLon) -> Bool {
            p.lat >= southwest.lat && p.lat < northeast.lat && p.lon >= southwest.lon && p.lon < northeast.lon
        }
    }

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static let badInput = "what3words: enter three words separated by dots, such as ///filled.count.soap."
    static let noKey = "what3words: add your API key in Settings first. Your plan must allow both conversions."
    static let mismatch = "what3words: response did not match the requested address."
    static let tooLarge = "what3words: response was too large."
    static let unreachable = "what3words: could not connect. Coordinates and grid references still work offline."
    static let cancelled = "what3words: lookup cancelled."
    static let fallback = "what3words lookup failed."
    static let maxResponseBytes = 32_768
    static let connectMs = 8_000
    static let readMs = 10_000

    /// The request for `input` ("///filled.count.soap" or "filled.count.soap"), or the reason there is none.
    static func requestURL(_ input: String) throws -> (url: String, words: String) {
        guard let words = ThreeWordAddress.normalize(input) else { throw Failure(message: badInput) }
        return ("https://api.what3words.com/v3/convert-to-coordinates?words=\(OsNames.urlEncode(words))", words)
    }

    static func httpError(_ code: Int) -> String {
        switch code {
        case 400, 404: return "what3words: address not found. Check all three words; spelling changes can point to a different country."
        case 401, 402, 403: return "what3words: check your API key, plan and conversion permissions in Settings."
        case 429: return "what3words: request limit reached. Try again later."
        default: return "what3words: service returned HTTP \(code). Use coordinates or a grid reference instead."
        }
    }

    /// Reads a conversion answer, refusing anything malformed, out of range or for a different address than `words`.
    static func parse(_ body: String, requested words: String) throws -> Address {
        let result = try parse(body)
        if result.words != words { throw Failure(message: mismatch) }
        return result
    }

    static func parse(_ body: String) throws -> Address {
        guard let data = body.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            throw Failure(message: "what3words: unreadable service response.")
        }
        if json["error"] != nil { throw Failure(message: "what3words: conversion failed. Check the address and your API plan.") }
        func position(_ value: Any?) throws -> LatLon {
            guard let obj = value as? [String: Any], let lat = number(obj["lat"]), let lon = number(obj["lng"]) else {
                throw Failure(message: "what3words: unreadable service response.")
            }
            if !lat.isFinite || !lon.isFinite || !(-90.0...90.0).contains(lat) || !(-180.0...180.0).contains(lon) {
                throw Failure(message: "what3words: invalid coordinates in response.")
            }
            return LatLon(lat, lon)
        }
        guard json["words"] != nil else { throw Failure(message: "what3words: unreadable service response.") }
        guard let words = ThreeWordAddress.normalize(OsNames.optString(json, "words")) else {
            throw Failure(message: "what3words: invalid address in response.")
        }
        guard let square = json["square"] as? [String: Any] else { throw Failure(message: "what3words: unreadable service response.") }
        let result = Address(words: words, position: try position(json["coordinates"]), southwest: try position(square["southwest"]),
                             northeast: try position(square["northeast"]), nearby: OsNames.optString(json, "nearestPlace"))
        if !result.contains(result.position) { throw Failure(message: "what3words: invalid square in response.") }
        return result
    }

    /// `JSONObject.getDouble`: a number, or text that reads as one.
    private static func number(_ value: Any?) -> Double? {
        if let s = value as? String { return Double(KotlinText.trim(s)) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// The search result it becomes: the address, what3words as its type, the nearby place and a 10-figure grid reference.
    static func place(_ address: Address) -> OsNames.Place {
        OsNames.Place(name: "///\(address.words)", type: "what3words", area: address.nearby, position: address.position,
                      grid: OsGrid.fromWgs84(address.position)?.format(10), zoom: 18.0)
    }
}
