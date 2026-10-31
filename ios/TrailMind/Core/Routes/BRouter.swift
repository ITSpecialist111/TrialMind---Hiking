import Foundation

/// BRouter (brouter.de) legs for the route planner, on its hiking-mountain profile: request building and response
/// parsing (BRouter.kt). The app layer sends the requests, one at a time, and keeps a small cache.
enum BRouter {
    static let attribution = "Routing: BRouter, © OpenStreetMap contributors"
    static let cacheSize = 50

    /// No path joins the two points (BRouter's "no track", an island, a point off the network...).
    struct NoPath: Error, LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct HTTPFailure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The request, written exactly as the Android app writes it.
    static func urlString(_ start: LatLon, _ end: LatLon) -> String {
        fmt("https://brouter.de/brouter?lonlats=%.6f,%.6f|%.6f,%.6f&profile=hiking-mountain&alternativeidx=0&format=geojson",
            start.lon, start.lat, end.lon, end.lat)
    }

    /// The request as a URL, with the separator between the two points escaped.
    static func url(_ start: LatLon, _ end: LatLon) -> URL? {
        URL(string: urlString(start, end).replacingOccurrences(of: "|", with: "%7C"))
    }

    /// What an answer other than 200 means: no path between the points, or the service failing.
    static func failure(status: Int, body: String) -> Error {
        let excerpt = String(body.prefix(160))
        if status == 400 && body.range(of: "no track|no route|no path|island|position.*not mapped",
                                       options: [.regularExpression, .caseInsensitive]) != nil {
            return NoPath(excerpt)
        }
        return HTTPFailure(message: "BRouter HTTP \(status): \(excerpt)")
    }

    /// The leg's points from a GeoJSON answer.
    static func parse(_ json: RoutesJSON.Value) throws -> [TrackPoint] {
        let features = try json.getJSONArray("features")
        if features.isEmpty { throw NoPath("No path") }
        let feature = try RoutesJSON.getJSONObject(features, 0)
        let geometry = try feature.getJSONObject("geometry")
        if try geometry.getString("type") != "LineString" { throw NoPath("No path") }
        let coords = try geometry.getJSONArray("coordinates")
        let points = try coords.indices.map { index -> TrackPoint in
            let c = try RoutesJSON.getJSONArray(coords, index)
            return TrackPoint(lat: try RoutesJSON.getDouble(c, 1), lon: try RoutesJSON.getDouble(c, 0),
                              ele: c.count > 2 && !RoutesJSON.isNull(c, 2) ? try RoutesJSON.getDouble(c, 2) : nil)
        }
        if points.count < 2 { throw NoPath("No path") }
        return points
    }
}
