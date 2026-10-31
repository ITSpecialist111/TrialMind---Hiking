import Foundation

/// Spherical-earth helpers. Accurate to well under 0.5% for hiking distances.
enum Geo {
    static let earthRadiusM = 6_371_008.8

    static func distanceM(_ a: LatLon, _ b: LatLon) -> Double { distanceM(a.lat, a.lon, b.lat, b.lon) }

    static func distanceM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = toRadians(lat1)
        let p2 = toRadians(lat2)
        let dp = p2 - p1
        let dl = toRadians(lon2 - lon1)
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadiusM * asin(sqrt(h.clamped(0.0, 1.0)))
    }

    /// Initial great-circle bearing from `a` to `b`, degrees clockwise from true north in [0, 360).
    static func bearingDeg(_ a: LatLon, _ b: LatLon) -> Double {
        let p1 = toRadians(a.lat)
        let p2 = toRadians(b.lat)
        let dl = toRadians(b.lon - a.lon)
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return normalizeDeg(toDegrees(atan2(y, x)))
    }

    static func destination(_ from: LatLon, bearingDeg: Double, distanceM: Double) -> LatLon {
        let d = distanceM / earthRadiusM
        let br = toRadians(bearingDeg)
        let p1 = toRadians(from.lat)
        let l1 = toRadians(from.lon)
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(br))
        let l2 = l1 + atan2(sin(br) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        return LatLon(toDegrees(p2), normalizeLon(toDegrees(l2)))
    }

    static func normalizeDeg(_ deg: Double) -> Double {
        let r = deg.truncatingRemainder(dividingBy: 360.0)
        return r < 0 ? r + 360.0 : r
    }

    static func normalizeLon(_ lon: Double) -> Double {
        var l = (lon + 180.0).truncatingRemainder(dividingBy: 360.0)
        if l < 0 { l += 360.0 }
        return l - 180.0
    }

    /// Signed smallest difference target - current in (-180, 180].
    static func angleDiffDeg(_ current: Double, _ target: Double) -> Double {
        var d = normalizeDeg(target - current)
        if d > 180.0 { d -= 360.0 }
        return d
    }

    private static let cardinals = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
    ]

    static func cardinal(_ bearingDeg: Double) -> String {
        cardinals[Int((normalizeDeg(bearingDeg) + 11.25) / 22.5) % 16]
    }

    /// Projects `p` onto segment `a`-`b` using a local equirectangular approximation (fine for segments shorter than
    /// a few km). Returns the clamped fraction along the segment and the distance in metres from `p` to the closest point.
    static func projectOntoSegment(_ p: LatLon, _ a: LatLon, _ b: LatLon) -> SegmentProjection {
        let cosLat = cos(toRadians((a.lat + b.lat) / 2.0))
        let ax = 0.0, ay = 0.0
        let bx = toRadians(b.lon - a.lon) * cosLat * earthRadiusM
        let by = toRadians(b.lat - a.lat) * earthRadiusM
        let px = toRadians(p.lon - a.lon) * cosLat * earthRadiusM
        let py = toRadians(p.lat - a.lat) * earthRadiusM
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 <= 1e-9 ? 0.0 : (((px - ax) * dx + (py - ay) * dy) / len2).clamped(0.0, 1.0)
        let cx = ax + t * dx, cy = ay + t * dy
        let dist = sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
        let closest = LatLon(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t)
        return SegmentProjection(fraction: t, distanceM: dist, closest: closest)
    }

    /// Cumulative distance along `points`; element i is the distance from point 0 to point i.
    static func cumulativeDistances(_ points: [TrackPoint]) -> [Double] {
        var out = [Double](repeating: 0, count: points.count)
        if points.count > 1 {
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                out[i] = out[i - 1] + distanceM(a.lat, a.lon, b.lat, b.lon)
            }
        }
        return out
    }
}

struct SegmentProjection: Hashable {
    var fraction: Double
    var distanceM: Double
    var closest: LatLon
}
