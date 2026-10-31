import Foundation

/// OS Names API (OS Data Hub): place search, and names for downloaded areas from the place nearest their centre.
/// Requests are built and responses read here; the app does the networking. Ported from the Android app's
/// data/OsNames.kt.
enum OsNames {
    struct Place: Hashable {
        var name: String
        var type: String
        var area: String
        var position: LatLon
        var grid: String?
        var zoom: Double
    }

    /// A message to show the user, as the Kotlin's IOException carries it.
    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static let noKey = "Add your OS Data Hub API key in Settings to search places."
    static let unreachable = "Could not reach OS Names. Check your connection and try again."
    static let tooLarge = "OS Names response was too large."
    static let maxResponseBytes = 1_000_000

    // Timeouts in milliseconds: place search, then each of the up to three "nearest" look-ups that name an area.
    static let searchConnectMs = 10_000
    static let searchReadMs = 15_000
    static let nearestTimeoutMs = 4_000

    static let settlements = "LOCAL_TYPE:City LOCAL_TYPE:Town LOCAL_TYPE:Village LOCAL_TYPE:Hamlet LOCAL_TYPE:Other_Settlement LOCAL_TYPE:Suburban_Area"
    // Only types the API accepts: an unknown LOCAL_TYPE fails the whole request.
    static let landscape = "LOCAL_TYPE:Hill_Or_Mountain LOCAL_TYPE:Hill_Or_Mountain_Ranges LOCAL_TYPE:Valley LOCAL_TYPE:Woodland_Or_Forest " +
        "LOCAL_TYPE:Inland_Water LOCAL_TYPE:Waterfall LOCAL_TYPE:Cirque_Or_Hollow LOCAL_TYPE:Cliff_Or_Slope LOCAL_TYPE:Island LOCAL_TYPE:Bay " +
        "LOCAL_TYPE:Beach LOCAL_TYPE:Other_Landform LOCAL_TYPE:Other_Landcover"

    /// The filters tried in turn when naming an area: a settlement, else a hill, wood or water, else anything.
    static let areaFilters: [String?] = [settlements, landscape, nil]

    static func findURL(_ query: String, _ key: String) -> String {
        "https://api.os.uk/search/names/v1/find?query=\(urlEncode(query))&maxresults=20&key=\(urlEncode(key))"
    }

    static func nearestURL(_ point: String, _ key: String, _ filter: String?) -> String {
        "https://api.os.uk/search/names/v1/nearest?point=\(point)&radius=1000" +
            (filter.map { "&fq=" + urlEncode($0).replacingOccurrences(of: "+", with: "%20") } ?? "") +
            "&key=" + urlEncode(key)
    }

    /// The grid position ("easting,northing" in whole metres) of the middle of `box`, or nil outside Great Britain.
    static func nearestPoint(_ box: BoundingBox) -> String? {
        guard let grid = OsGrid.fromWgs84(box.center) else { return nil }
        return "\(kRound(grid.easting)),\(kRound(grid.northing))"
    }

    /// The message for a refused request, as the Kotlin words it.
    static func httpError(_ code: Int) -> String {
        switch code {
        case 401, 403: return "OS Names could not use this API key. Check it in Settings."
        case 429: return "OS Names is busy. Please try again later."
        default: return "OS Names returned HTTP \(code)."
        }
    }

    /// What the search page shows for a failed search: OS Names' own messages, otherwise the connection advice.
    static func userMessage(_ message: String?) -> String {
        guard let message else { return unreachable }
        if message.hasPrefix("OS Names") || message.hasPrefix("Add your OS") || message.hasPrefix("Could not reach OS Names") {
            return message
        }
        return unreachable
    }

    /// Places in a `find` answer; entries without a name or a position are left out. Throws on a body that is not JSON.
    static func parse(_ json: String) throws -> [Place] {
        let root = try object(json)
        guard let results = root["results"] as? [Any] else { return [] }
        return results.compactMap { item -> Place? in
            guard let entry = (item as? [String: Any])?["GAZETTEER_ENTRY"] as? [String: Any] else { return nil }
            let name = optString(entry, "NAME1")
            if KotlinText.isBlank(name) { return nil }
            let east = optDouble(entry, "GEOMETRY_X")
            let north = optDouble(entry, "GEOMETRY_Y")
            if !east.isFinite || !north.isFinite { return nil }
            let type = optString(entry, "LOCAL_TYPE")
            let area = ["POPULATED_PLACE", "DISTRICT_BOROUGH", "COUNTY_UNITARY", "POSTCODE_DISTRICT"]
                .map { optString(entry, $0) }
                .first { !KotlinText.isBlank($0) && $0 != name } ?? ""
            let grid = OsGrid.letters(east, north) != nil ? OsGridRef(east, north).format(6) : nil
            let wide = type.range(of: "County", options: .caseInsensitive) != nil || type.range(of: "City", options: .caseInsensitive) != nil
            return Place(name: name, type: type, area: area, position: OsGrid.toWgs84(east, north), grid: grid, zoom: wide ? 12.0 : 15.0)
        }
    }

    /// The first entry of a `nearest` answer, or nil when it found nothing. Throws on a body that is not JSON.
    static func parseNearest(_ json: String) throws -> [String: Any]? {
        let root = try object(json)
        return ((root["results"] as? [Any])?.first as? [String: Any])?["GAZETTEER_ENTRY"] as? [String: Any]
    }

    /// A name for a downloaded `box` from its nearest gazetteer entry, e.g. "Parkend, Forest of Dean".
    static func areaName(_ entry: [String: Any], _ box: BoundingBox) -> String? {
        let district = optString(entry, "DISTRICT_BOROUGH")
        return areaName(optString(entry, "NAME1"), optString(entry, "LOCAL_TYPE"), optString(entry, "POPULATED_PLACE"),
                        KotlinText.isBlank(district) ? optString(entry, "COUNTY_UNITARY") : district,
                        Geo.distanceM(box.minLat, box.minLon, box.maxLat, box.maxLon) / 1000)
    }

    /// Big areas are named after their district; roads and postcodes give way to the place they are in.
    static func areaName(_ name: String, _ type: String, _ populatedPlace: String, _ district: String, _ diagonalKm: Double) -> String? {
        let area = KotlinText.trim(substringBefore(district, " - "))
        let roadOrPostcode = type.range(of: "Road", options: .caseInsensitive) != nil || type.range(of: "Postcode", options: .caseInsensitive) != nil
        let place = KotlinText.trim(roadOrPostcode ? populatedPlace : name)
        if diagonalKm >= 20 && !area.isEmpty { return area }
        if place.isEmpty { return area.isEmpty ? nil : area }
        if area.isEmpty || area.caseInsensitiveCompare(place) == .orderedSame { return place }
        return "\(place), \(area)"
    }

    /// `java.net.URLEncoder.encode(s, "UTF-8")`: letters, digits and `.-*_` stay, a space becomes `+`, every other byte
    /// of the UTF-8 form becomes `%XX`.
    static func urlEncode(_ s: String) -> String {
        let hex = Array("0123456789ABCDEF")
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E, 0x2D, 0x2A, 0x5F:
                out.append(Character(Unicode.Scalar(byte)))
            case 0x20:
                out.append("+")
            default:
                out.append("%")
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
        }
        return out
    }

    // MARK: org.json's lenient readers

    /// The top-level object of a response; anything else is unreadable, as `JSONObject(json)` would throw.
    static func object(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            throw Failure(message: unreachable)
        }
        return root
    }

    /// `JSONObject.optString(key)`: the value as text, or "" when it is missing or null.
    static func optString(_ obj: [String: Any], _ key: String) -> String {
        guard let value = obj[key], !(value is NSNull) else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return "\(value)"
    }

    /// `JSONObject.optDouble(key)`: a number, or text that reads as one; NaN otherwise.
    static func optDouble(_ obj: [String: Any], _ key: String) -> Double {
        guard let value = obj[key], !(value is NSNull) else { return .nan }
        if let s = value as? String { return Double(KotlinText.trim(s)) ?? .nan }
        if let n = value as? NSNumber { return n.doubleValue }
        return .nan
    }

    /// Kotlin's `substringBefore(delimiter)`: the whole text when the delimiter is missing.
    private static func substringBefore(_ s: String, _ delimiter: String) -> String {
        guard let r = s.range(of: delimiter) else { return s }
        return String(s[..<r.lowerBound])
    }
}
