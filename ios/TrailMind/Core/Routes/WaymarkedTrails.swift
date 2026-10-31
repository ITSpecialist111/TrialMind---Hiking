import Foundation

/// Waymarked walking routes from OpenStreetMap, found and downloaded through the Waymarked Trails API: request
/// building and response parsing (the app layer does the networking). The data is © OpenStreetMap contributors under
/// the ODbL, so `attribution` must be shown with it.
enum WaymarkedTrails {
    static let api = "https://hiking.waymarkedtrails.org/api/v1"
    static let attribution = "Routes © OpenStreetMap contributors (ODbL), found with Waymarked Trails. Heights: ASTER GDEM is a product of METI and NASA."

    /// Height samples come every 2 m (about 30 kB per km), so they are skipped for longer trails.
    static let elevationMaxM = 60_000.0
    static let sampleSpacingM = 10.0
    static let maxBytes = 12 * 1024 * 1024

    struct Trail: Hashable, Identifiable {
        var id: Int64
        var name: String
        var ref: String?
        var group: String

        var kind: String {
            switch group {
            case "INT": return "International trail"
            case "NAT": return "National trail"
            case "REG": return "Regional route"
            case "LOC": return "Local walk"
            default: return "Waymarked route"
            }
        }

        var webUrl: String { "https://hiking.waymarkedtrails.org/#route?id=\(id)" }
    }

    struct Download: Hashable {
        var name: String
        var points: [TrackPoint]
        var lengthM: Double
        var hasElevation: Bool
    }

    /// A height sample along a way, in Web Mercator metres, with its distance along the way.
    struct Sample: Hashable {
        var x: Double
        var y: Double
        var ele: Double?
        var pos: Double

        func sq(_ ox: Double, _ oy: Double) -> Double { (x - ox) * (x - ox) + (y - oy) * (y - oy) }
    }

    struct NoLine: Error, LocalizedError {
        var errorDescription: String? { "OpenStreetMap has no usable line for this route yet." }
    }

    // MARK: Requests

    static func searchURL(_ query: String) -> String {
        "\(api)/list/search?query=\(RoutesJSON.formEncode(query))&limit=30"
    }

    /// Routes crossing `box`, most important (international, national) first.
    static func areaURL(_ box: BoundingBox) -> String {
        let a = WebMercator.toMetres(LatLon(box.minLat, box.minLon))
        let b = WebMercator.toMetres(LatLon(box.maxLat, box.maxLon))
        return "\(api)/list/by_area?bbox=\(kTruncateL(a.x)),\(kTruncateL(a.y)),\(kTruncateL(b.x)),\(kTruncateL(b.y))&limit=40"
    }

    static func detailsURL(_ id: Int64) -> String { "\(api)/details/relation/\(id)" }

    static func elevationURL(_ id: Int64) -> String { "\(api)/details/relation/\(id)/way-elevation" }

    // MARK: Responses

    /// A search or area listing.
    static func trails(_ json: RoutesJSON.Value) throws -> [Trail] {
        guard let results = json.optJSONArray("results") else { return [] }
        var out: [Trail] = []
        for i in results.indices {
            let r = try RoutesJSON.getJSONObject(results, i)
            if r.optString("type", "relation") != "relation" { continue }
            var name = r.optString("name")
            if name.isBlank { name = r.optString("ref") }
            if name.isBlank { continue }
            let ref = r.optString("ref")
            out.append(Trail(id: try r.getLong("id"), name: name, ref: ref.isBlank ? nil : ref, group: r.optString("group")))
        }
        return out
    }

    /// The route's length from its details, which decides whether heights are worth downloading.
    static func lengthM(details: RoutesJSON.Value) throws -> Double {
        try details.getJSONObject("route").optDouble("length", 0.0)
    }

    static func wantsHeights(lengthM: Double) -> Bool { lengthM > 0 && lengthM <= elevationMaxM }

    /// The way-elevation response: height samples by way id.
    static func heights(_ json: RoutesJSON.Value) throws -> [Int64: [Sample]] {
        guard let segments = json.optJSONObject("segments"), let object = segments.objectValue else { return [:] }
        var out: [Int64: [Sample]] = [:]
        for key in object.keys {
            guard let wayId = Int64(key) else { continue }
            var list: [Sample] = []
            for e in objects(segments.optJSONObject(key)?.optJSONArray("elevation")) {
                let ele = e.optDouble("ele")
                list.append(Sample(x: try e.getDouble("x"), y: try e.getDouble("y"), ele: ele.isNaN ? nil : ele, pos: e.optDouble("pos", 0.0)))
            }
            if !list.isEmpty { out[wayId] = list }
        }
        return out
    }

    /// The route's line from its details, using `heights` (from `heights(_:)`) where there are some.
    static func download(details: RoutesJSON.Value, heights: [Int64: [Sample]]?, trail: Trail) throws -> Download {
        let route = try details.getJSONObject("route")
        let lengthM = route.optDouble("length", 0.0)
        var pieces: [[TrackPoint]] = []
        try collect(route, heights, &pieces)
        let points = PathJoin.join(pieces, ordered: route.optString("linear") != "no")
        guard points.count >= 2 else { throw NoLine() }
        let name = details.optString("name")
        return Download(name: name.isBlank ? trail.name : name, points: points, lengthM: lengthM,
                        hasElevation: !(heights ?? [:]).isEmpty)
    }

    /// Flattens the route tree into lines: "route" and "split" segments hold further segments ("split" has a forward
    /// and a backward branch, forward is used), "linear" holds ways that already join up in route order. Appendices
    /// (alternatives and detours) are left out.
    private static func collect(_ seg: RoutesJSON.Value, _ heights: [Int64: [Sample]]?, _ out: inout [[TrackPoint]]) throws {
        switch seg.optString("route_type") {
        case "route":
            for child in objects(seg.optJSONArray("main")) { try collect(child, heights, &out) }
        case "split":
            for child in objects(seg.optJSONArray("forward")) { try collect(child, heights, &out) }
        case "linear":
            var line: [TrackPoint] = []
            for way in objects(seg.optJSONArray("ways")) {
                for p in try wayPoints(way, heights) where line.isEmpty || line[line.count - 1].lat != p.lat || line[line.count - 1].lon != p.lon {
                    line.append(p)
                }
            }
            if line.count >= 2 { out.append(line) }
        case "base":
            let points = try wayPoints(seg, heights)
            if points.count >= 2 { out.append(points) }
        default:
            break
        }
    }

    /// A way's line, using its height samples (thinned to every `sampleSpacingM`) when there are some.
    private static func wayPoints(_ way: RoutesJSON.Value, _ heights: [Int64: [Sample]]?) throws -> [TrackPoint] {
        guard let coords = way.optJSONObject("geometry")?.optJSONArray("coordinates") else { return [] }
        if coords.count < 2 { return [] }
        if let samples = heights?[way.optLong("id")], samples.count >= 2 {
            let first = try RoutesJSON.getJSONArray(coords, 0)
            let x0 = try RoutesJSON.getDouble(first, 0)
            let y0 = try RoutesJSON.getDouble(first, 1)
            // Samples follow the way as drawn in OpenStreetMap, which can be against the route direction.
            let s = samples[samples.count - 1].sq(x0, y0) < samples[0].sq(x0, y0) ? Array(samples.reversed()) : samples
            var out: [TrackPoint] = []
            var lastPos = 0.0
            for (i, p) in s.enumerated() where i == 0 || i == s.count - 1 || abs(p.pos - lastPos) >= sampleSpacingM {
                let ll = WebMercator.fromMetres(p.x, p.y)
                out.append(TrackPoint(lat: ll.lat, lon: ll.lon, ele: p.ele))
                lastPos = p.pos
            }
            return out
        }
        return try coords.indices.map { i in
            let c = try RoutesJSON.getJSONArray(coords, i)
            let ll = WebMercator.fromMetres(try RoutesJSON.getDouble(c, 0), try RoutesJSON.getDouble(c, 1))
            return TrackPoint(lat: ll.lat, lon: ll.lon)
        }
    }

    /// The objects in an array, skipping anything else (`optJSONObject(i)?.let`).
    private static func objects(_ array: [RoutesJSON.Value]?) -> [RoutesJSON.Value] {
        (array ?? []).filter { $0.objectValue != nil }
    }
}
