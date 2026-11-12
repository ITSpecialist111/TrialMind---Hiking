import Foundation

/// WGS84 coordinate in decimal degrees.
struct LatLon: Hashable, Codable {
    var lat: Double
    var lon: Double

    init(_ lat: Double, _ lon: Double) { self.lat = lat; self.lon = lon }
    init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }

    var isValid: Bool { (-90.0...90.0).contains(lat) && (-180.0...180.0).contains(lon) && !lat.isNaN && !lon.isNaN }
}

/// A recorded or imported point. Elevation in metres above sea level, time in epoch millis.
struct TrackPoint: Hashable, Codable {
    var lat: Double
    var lon: Double
    var ele: Double? = nil
    var timeMs: Int64? = nil
    var accuracyM: Float? = nil

    init(lat: Double, lon: Double, ele: Double? = nil, timeMs: Int64? = nil, accuracyM: Float? = nil) {
        self.lat = lat; self.lon = lon; self.ele = ele; self.timeMs = timeMs; self.accuracyM = accuracyM
    }

    func latLon() -> LatLon { LatLon(lat, lon) }
}

struct Waypoint: Hashable, Codable {
    var lat: Double
    var lon: Double
    var name: String
    var ele: Double? = nil
    var description: String? = nil

    init(lat: Double, lon: Double, name: String, ele: Double? = nil, description: String? = nil) {
        self.lat = lat; self.lon = lon; self.name = name; self.ele = ele; self.description = description
    }

    func latLon() -> LatLon { LatLon(lat, lon) }
}

struct BoundingBox: Hashable, Codable {
    var minLat: Double
    var minLon: Double
    var maxLat: Double
    var maxLon: Double

    init(_ minLat: Double, _ minLon: Double, _ maxLat: Double, _ maxLon: Double) {
        self.minLat = minLat; self.minLon = minLon; self.maxLat = maxLat; self.maxLon = maxLon
    }

    init(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        self.init(minLat, minLon, maxLat, maxLon)
    }

    var center: LatLon { LatLon((minLat + maxLat) / 2.0, (minLon + maxLon) / 2.0) }

    func contains(_ p: LatLon) -> Bool { (minLat...maxLat).contains(p.lat) && (minLon...maxLon).contains(p.lon) }

    func expandedByMetres(_ metres: Double) -> BoundingBox {
        let dLat = toDegrees(metres / Geo.earthRadiusM)
        let cosLat = max(cos(toRadians(center.lat)), 0.01)
        let dLon = dLat / cosLat
        return BoundingBox(
            max(minLat - dLat, -85.0), max(minLon - dLon, -180.0),
            min(maxLat + dLat, 85.0), min(maxLon + dLon, 180.0)
        )
    }

    static func of<S: Sequence>(_ points: S) -> BoundingBox? where S.Element == LatLon {
        var minLat = Double.infinity, minLon = Double.infinity
        var maxLat = -Double.infinity, maxLon = -Double.infinity
        var any = false
        for p in points {
            any = true
            if p.lat < minLat { minLat = p.lat }
            if p.lat > maxLat { maxLat = p.lat }
            if p.lon < minLon { minLon = p.lon }
            if p.lon > maxLon { maxLon = p.lon }
        }
        return any ? BoundingBox(minLat, minLon, maxLat, maxLon) : nil
    }
}
