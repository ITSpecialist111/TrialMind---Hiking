import Foundation

enum SatelliteSky {
    struct Point: Hashable {
        var x: Double
        var y: Double
    }

    /// North-up sky plot, horizon radius 1, zenith at the origin.
    static func project(_ azimuth: Double, _ elevation: Double) -> Point? {
        if !azimuth.isFinite || !elevation.isFinite || !(0.0...90.0).contains(elevation) { return nil }
        let radius = 1.0 - elevation / 90.0
        let angle = toRadians(azimuth)
        return Point(x: radius * sin(angle), y: -radius * cos(angle))
    }
}
