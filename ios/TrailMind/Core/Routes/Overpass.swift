import Foundation

/// Facilities found near a route with Overpass, as the Android app saves them for offline use.
struct SavedFacilities: Hashable {
    var fetchedMs: Int64
    var items: [Facility]
    var partial: Bool = false

    /// The saved file, in the Android app's format.
    func json() -> String {
        let list: [RoutesJSON.Value] = items.map { item in
            .object(RoutesJSON.Object([
                ("category", .string(item.category.rawValue)),
                ("lat", .double(item.position.lat)),
                ("lon", .double(item.position.lon)),
                ("name", .string(item.name)),
                ("ele", .string(item.ele)),
                ("openingHours", .string(item.openingHours)),
                ("fee", .string(item.fee)),
                ("access", .string(item.access)),
                ("website", .string(item.website)),
                ("alongM", .double(item.alongM)),
                ("offM", .double(item.offM)),
            ]))
        }
        return RoutesJSON.Value.object(RoutesJSON.Object([
            ("fetchedMs", .long(fetchedMs)), ("partial", .bool(partial)), ("items", .array(list)),
        ])).serialized()
    }

    /// A saved file read back; nil when it is damaged or holds a category this version doesn't know.
    static func from(_ text: String) -> SavedFacilities? {
        guard let json = try? RoutesJSON.parse(text) else { return nil }
        do {
            let array = try json.getJSONArray("items")
            let items = try array.indices.map { index -> Facility in
                let item = try RoutesJSON.getJSONObject(array, index)
                guard let category = FacilityCategory(rawValue: try item.getString("category")) else {
                    throw RoutesJSON.JSONError("Unknown category")
                }
                return Facility(category: category, position: LatLon(try item.getDouble("lat"), try item.getDouble("lon")),
                                name: item.optString("name"), ele: item.optString("ele"), openingHours: item.optString("openingHours"),
                                fee: item.optString("fee"), access: item.optString("access"), website: item.optString("website"),
                                alongM: try item.getDouble("alongM"), offM: try item.getDouble("offM"))
            }
            return SavedFacilities(fetchedMs: try json.getLong("fetchedMs"), items: items, partial: json.optBoolean("partial", false))
        } catch {
            return nil
        }
    }
}

/// Overpass queries for the facilities along a route, and reading the reply (OverpassFacilities.kt's query and
/// parse). The app layer sends one query at a time and keeps to the operators' back-off rules.
enum Overpass {
    static let attribution = "Facilities: © OpenStreetMap contributors"
    // overpass.openstreetmap.fr now answers only whitelisted users (HTTP 403), so the main instance is the only one.
    static let servers = ["https://overpass-api.de/api/interpreter"]
    // Its operators ban clients that retry soon after a 429 or 406: wait at least 30 s, and send one query at a time.
    static let backoffMs: Int64 = 30_000
    static let maxBytes = 12 * 1024 * 1024
    static let maxElements = 900

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func query(_ points: [LatLon]) -> String {
        let radius = RouteFacilities.corridorM(points)
        let corridor = RouteFacilities.simplify(points, maxPoints: radius < 250 ? 50 : 150)
            .map { "\(RoutesJSON.javaDoubleString($0.lat)),\(RoutesJSON.javaDoubleString($0.lon))" }.joined(separator: ",")
        let start = points[0]
        let finish = points[points.count - 1]
        let filters = [
            "[amenity~\"^(drinking_water|water_point|toilets|pub|cafe|restaurant|parking|shelter)$\"]",
            "[man_made=water_tap][drinking_water=yes]", "[shop~\"^(convenience|supermarket)$\"]",
            "[highway=bus_stop]", "[railway~\"^(station|halt)$\"]",
            "[tourism~\"^(camp_site|hostel|guest_house|hotel|wilderness_hut|viewpoint)$\"]",
            "[building=hut]", "[natural=peak][name]",
        ]
        let around = points.count == 1
            ? "around:\(radius),\(RoutesJSON.javaDoubleString(start.lat)),\(RoutesJSON.javaDoubleString(start.lon))"
            : "around:\(radius),\(corridor)"
        var out = "[out:json][timeout:120];("
        for f in filters { out += "nwr(\(around))\(f);" }
        for point in (start == finish ? [start] : [start, finish]) {
            let nearby = "around:800,\(RoutesJSON.javaDoubleString(point.lat)),\(RoutesJSON.javaDoubleString(point.lon))"
            for f in ["[amenity=parking]", "[highway=bus_stop]", "[railway~\"^(station|halt)$\"]"] { out += "nwr(\(nearby))\(f);" }
        }
        out += ");out center tags \(maxElements);"
        return out
    }

    /// The form body for a query.
    static func body(_ query: String) -> String { "data=" + RoutesJSON.formEncode(query) }

    /// When to try again after an answer of `status`: at least `backoffMs`, longer if Retry-After asks; nil when no
    /// wait is needed.
    static func backoffUntil(status: Int, retryAfter: String?, nowMs: Int64) -> Int64? {
        guard status == 429 || status == 406 else { return nil }
        let seconds = retryAfter.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        return nowMs + max(backoffMs, seconds * 1000)
    }

    static func busyMessage(waitMs: Int64) -> String { "Overpass is busy. Try again in \((waitMs + 999) / 1000) s." }

    static let anotherSearchMessage = "Another facilities search is running. Try again when it finishes."

    /// Facilities in a reply, located along `points`, and whether the results are a limited selection. `truncated`
    /// says the reply was cut off at `maxBytes`: what arrived before the cut is kept, as the Android reader does.
    static func parse(_ bytes: [UInt8], truncated: Bool, points: [LatLon]) throws -> (items: [Facility], partial: Bool) {
        var items: [Facility] = []
        var elements = 0
        var partial = false
        var reader = RoutesJSON.Reader(bytes, truncated: truncated)
        do {
            try reader.beginObject()
            var first = true
            while try reader.hasNext(first: &first, closing: UInt8(ascii: "}")) {
                switch try reader.nextName() {
                case "elements":
                    try reader.beginArray()
                    var firstElement = true
                    while try reader.hasNext(first: &firstElement, closing: UInt8(ascii: "]")) {
                        if let item = try element(try reader.value()) { items.append(item) }
                        elements += 1
                    }
                case "remark":
                    let remark = try nextString(try reader.value())
                    if remark.range(of: "runtime error", options: .caseInsensitive) != nil { partial = true }
                default:
                    try reader.skipValue()
                }
            }
        } catch is RoutesJSON.EndOfInput where truncated {
            partial = true
        }
        if partial && items.isEmpty && elements == 0 { throw Failure("Overpass returned no facilities before its limit.") }
        return (RouteFacilities.locate(points, items, corridorM: RouteFacilities.corridorM(points)), partial || elements >= maxElements)
    }

    private static func element(_ value: RoutesJSON.Value) throws -> Facility? {
        guard let object = value.objectValue else { throw Failure("Expected an element object") }
        var lat: Double?
        var lon: Double?
        var tags: [String: String] = [:]
        for key in object.keys {
            guard let v = object[key] else { continue }
            switch key {
            case "lat": lat = try nextDouble(v)
            case "lon": lon = try nextDouble(v)
            case "center":
                guard let centre = v.objectValue else { throw Failure("Expected a centre object") }
                for k in centre.keys {
                    if k == "lat" { lat = try nextDouble(centre[k]!) }
                    if k == "lon" { lon = try nextDouble(centre[k]!) }
                }
            case "tags":
                guard let t = v.objectValue else { throw Failure("Expected a tags object") }
                for k in t.keys { tags[k] = try nextString(t[k]!) }
            default:
                break
            }
        }
        guard let category = FacilityCategory.fromTags(tags), let lat, let lon else { return nil }
        return Facility(category: category, position: LatLon(lat, lon), name: tags["name"] ?? "", ele: tags["ele"] ?? "",
                        openingHours: tags["opening_hours"] ?? "", fee: tags["fee"] ?? "", access: tags["access"] ?? "",
                        website: tags["website"] ?? "")
    }

    /// `JsonReader.nextDouble`: a number, or a string holding one.
    private static func nextDouble(_ v: RoutesJSON.Value) throws -> Double {
        switch v {
        case .number(let literal):
            if let d = RoutesJSON.numberDouble(literal), d.isFinite { return d }
        case .string(let s):
            if let d = RoutesJSON.parseJavaDouble(s), d.isFinite { return d }
        default:
            break
        }
        throw Failure("Expected a double but was \(v.javaString)")
    }

    /// `JsonReader.nextString`: a string, or a number's literal text.
    private static func nextString(_ v: RoutesJSON.Value) throws -> String {
        switch v {
        case .string(let s): return s
        case .number(let literal): return literal
        default: throw Failure("Expected a string but was \(v.javaString)")
        }
    }
}
