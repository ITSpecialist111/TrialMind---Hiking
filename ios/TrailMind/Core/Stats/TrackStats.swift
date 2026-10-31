import Foundation

struct TrackSummary: Hashable {
    var distanceM: Double
    var ascentM: Double
    var descentM: Double
    var minEleM: Double?
    var maxEleM: Double?
    var durationMs: Int64
    var movingMs: Int64
    var pointCount: Int

    var avgMovingSpeedMps: Double { movingMs > 0 ? distanceM / (Double(movingMs) / 1000.0) : 0.0 }

    static let empty = TrackSummary(distanceM: 0.0, ascentM: 0.0, descentM: 0.0, minEleM: nil, maxEleM: nil,
                                    durationMs: 0, movingMs: 0, pointCount: 0)
}

enum TrackStats {
    /// Elevation changes smaller than this are treated as GPS/barometer noise.
    static let defaultElevationThresholdM = 4.0
    static let movingSpeedMps = 0.3

    static func summarize(_ points: [TrackPoint], elevationThresholdM: Double = defaultElevationThresholdM) -> TrackSummary {
        if points.isEmpty { return .empty }
        var distance = 0.0
        var moving: Int64 = 0
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            let d = Geo.distanceM(a.lat, a.lon, b.lat, b.lon)
            distance += d
            if let ta = a.timeMs, let tb = b.timeMs, tb > ta {
                let dt = tb - ta
                // Gaps over 10 minutes are pauses (e.g. app paused) rather than slow walking.
                if dt < 10 * 60_000 && d / (Double(dt) / 1000.0) >= movingSpeedMps { moving += dt }
            }
        }
        let (ascent, descent) = ascentDescent(points.compactMap { $0.ele }, threshold: elevationThresholdM)
        let eles = points.compactMap { $0.ele }
        let times = points.compactMap { $0.timeMs }
        let duration: Int64 = times.count >= 2 ? times[times.count - 1] - times[0] : 0
        // Kotlin's minOrNull/maxOrNull on doubles: NaN if any height is NaN.
        let minEle = eles.first.map { first in eles.dropFirst().reduce(first) { kMinOf($0, $1) } }
        let maxEle = eles.first.map { first in eles.dropFirst().reduce(first) { kMaxOf($0, $1) } }
        return TrackSummary(distanceM: distance, ascentM: ascent, descentM: descent, minEleM: minEle, maxEleM: maxEle,
                            durationMs: duration, movingMs: moving, pointCount: points.count)
    }

    /// Hysteresis-based ascent/descent: only counts a change once it exceeds `threshold`.
    static func ascentDescent(_ elevations: [Double], threshold: Double = defaultElevationThresholdM) -> (ascent: Double, descent: Double) {
        guard var ref = elevations.first else { return (0.0, 0.0) }
        var up = 0.0
        var down = 0.0
        for e in elevations {
            let d = e - ref
            if d >= threshold {
                up += d
                ref = e
            } else if -d >= threshold {
                down += -d
                ref = e
            }
        }
        return (up, down)
    }
}
