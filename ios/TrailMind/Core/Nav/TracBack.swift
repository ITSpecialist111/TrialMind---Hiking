import Foundation

/// "Retrace my steps": the recorded breadcrumb reversed, so route guidance leads back to where the hike began.
enum TracBack {
    static let routeName = "Retrace steps"
    static let startName = "Start of hike"

    /// The recorded points reversed and thinned to at most `maxPoints`, or nil if there is nothing to retrace.
    static func line(_ recorded: [TrackPoint], maxPoints: Int = 3000) -> [TrackPoint]? {
        if recorded.count < 2 { return nil }
        let step = max(kTruncate(ceil(Double(recorded.count) / Double(maxPoints))), 1)
        let kept = recorded.indices.filter { $0 % step == 0 || $0 == recorded.count - 1 }.map { recorded[$0] }
        return kept.reversed().map { TrackPoint(lat: $0.lat, lon: $0.lon, ele: $0.ele) }
    }
}
