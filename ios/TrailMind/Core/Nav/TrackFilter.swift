import Foundation

/// Decides which GPS fixes are recorded as breadcrumbs. Rejects poor-accuracy fixes, jitter while standing still, and
/// physically implausible jumps for someone on foot.
final class TrackFilter {
    private let maxAccuracyM: Float
    private let minDistanceM: Double
    private let maxSpeedMps: Double
    private let keepAliveMs: Int64
    private var last: TrackPoint?

    init(maxAccuracyM: Float = 35, minDistanceM: Double = 5.0, maxSpeedMps: Double = 12.0, keepAliveMs: Int64 = 60_000) {
        self.maxAccuracyM = maxAccuracyM
        self.minDistanceM = minDistanceM
        self.maxSpeedMps = maxSpeedMps
        self.keepAliveMs = keepAliveMs
    }

    func reset(_ lastAccepted: TrackPoint? = nil) {
        last = lastAccepted
    }

    func accept(_ p: TrackPoint) -> Bool {
        if let acc = p.accuracyM, acc > maxAccuracyM { return false }
        guard let prev = last else {
            last = p
            return true
        }
        let d = Geo.distanceM(prev.lat, prev.lon, p.lat, p.lon)
        if let t0 = prev.timeMs, let t1 = p.timeMs {
            let dt = Double(t1 - t0) / 1000.0
            if dt <= 0 { return false }
            if d / dt > maxSpeedMps && d > 50 { return false }
            if d < minDistanceM && (t1 - t0) < keepAliveMs { return false }
        } else if d < minDistanceM {
            return false
        }
        last = p
        return true
    }
}
