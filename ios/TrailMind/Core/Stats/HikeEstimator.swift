import Foundation

struct HikeEstimate: Hashable {
    /// Naismith (flat pace + 10 min per 100 m ascent) with Langmuir descent corrections.
    var naismithMinutes: Double
    /// Tobler's hiking function integrated per segment, scaled to the user's flat pace.
    var toblerMinutes: Double
    var distanceM: Double
    var ascentM: Double
    var descentM: Double

    /// Conservative planning figure: the slower of the two methods.
    var planningMinutes: Double { kMaxOf(naismithMinutes, toblerMinutes) }
}

struct PaceSettings: Hashable {
    let flatSpeedKmh: Double
    /// Additional multiplier for load, group, conditions (1.0 = none, 1.2 = 20% slower).
    let conditionsFactor: Double

    /// A setting out of range (Kotlin's `require` failure, which the app catches to fall back to the defaults).
    struct OutOfRange: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The defaults: 5 km/h on the flat, no allowance for conditions.
    init() {
        flatSpeedKmh = 5.0
        conditionsFactor = 1.0
    }

    init(flatSpeedKmh: Double = 5.0, conditionsFactor: Double = 1.0) throws {
        guard flatSpeedKmh >= 1.0 && flatSpeedKmh <= 10.0 else { throw OutOfRange(message: "flat speed must be 1-10 km/h") }
        guard conditionsFactor >= 0.5 && conditionsFactor <= 3.0 else { throw OutOfRange(message: "conditions factor must be 0.5-3") }
        self.flatSpeedKmh = flatSpeedKmh
        self.conditionsFactor = conditionsFactor
    }
}

/// A route's highest point and the planning time, before breaks, to walk there from the start.
struct HighPoint: Hashable {
    var position: LatLon
    var eleM: Double
    var minutesFromStart: Double
}

/// Walking-time estimates. These are rules of thumb for fit adults on paths: always allow extra for rough ground,
/// navigation, weather and breaks.
enum HikeEstimator {
    private static let segmentM = 50.0

    static func estimate(_ points: [TrackPoint], pace: PaceSettings = PaceSettings()) -> HikeEstimate {
        let segs = resample(points)
        var distance = 0.0
        var ascent = 0.0
        var descent = 0.0
        var toblerH = 0.0
        var gentleDescent = 0.0
        var steepDescent = 0.0
        let toblerScale = pace.flatSpeedKmh / toblerFlatKmh
        for s in segs {
            distance += s.lengthM
            if s.dEle > 0 { ascent += s.dEle } else { descent += -s.dEle }
            let slope = s.lengthM > 0 ? s.dEle / s.lengthM : 0.0
            if s.dEle < 0 {
                let deg = toDegrees(atan(abs(slope)))
                if deg >= 5.0 && deg <= 12.0 {
                    gentleDescent += -s.dEle
                } else if deg > 12.0 {
                    steepDescent += -s.dEle
                }
            }
            let speedKmh = toblerA * exp(-3.5 * abs(slope + 0.05)) * toblerScale
            toblerH += (s.lengthM / 1000.0) / max(speedKmh, 0.5)
        }
        var naismithH = distance / 1000.0 / pace.flatSpeedKmh + ascent / 600.0
        // Langmuir: -10 min per 300 m of gentle descent, +10 min per 300 m of steep descent.
        naismithH += (-gentleDescent + steepDescent) / 300.0 * (10.0 / 60.0)
        naismithH = max(naismithH, distance / 1000.0 / pace.flatSpeedKmh)
        return HikeEstimate(
            naismithMinutes: naismithH * 60.0 * pace.conditionsFactor,
            toblerMinutes: toblerH * 60.0 * pace.conditionsFactor,
            distanceM: distance,
            ascentM: ascent,
            descentM: descent
        )
    }

    /// The first of the highest points of `points`, or nil when they have no heights.
    static func highPoint(_ points: [TrackPoint], pace: PaceSettings = PaceSettings()) -> HighPoint? {
        var best = -1
        var bestEle = -Double.infinity
        for (i, p) in points.enumerated() {
            if let e = p.ele, e > bestEle {
                best = i
                bestEle = e
            }
        }
        if best < 0 { return nil }
        let minutes = best == 0 ? 0.0 : estimate(Array(points[0...best]), pace: pace).planningMinutes
        return HighPoint(position: points[best].latLon(), eleM: bestEle, minutesFromStart: minutes)
    }

    private static let toblerA = 6.0
    private static let toblerFlatKmh = toblerA * exp(-3.5 * 0.05)

    struct Seg: Hashable {
        var lengthM: Double
        var dEle: Double
    }

    /// Groups points into ~50 m chunks so GPS jitter doesn't create fake slopes. Elevation deltas are only used if
    /// both chunk ends have elevation.
    static func resample(_ points: [TrackPoint]) -> [Seg] {
        if points.count < 2 { return [] }
        var out: [Seg] = []
        var startEle = points[0].ele
        var acc = 0.0
        var lastEle = startEle
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            acc += Geo.distanceM(a.lat, a.lon, b.lat, b.lon)
            if let e = b.ele { lastEle = e }
            if acc >= segmentM || i == points.count - 1 {
                var d = 0.0
                if let s = startEle, let l = lastEle { d = l - s }
                if acc > 0 { out.append(Seg(lengthM: acc, dEle: d)) }
                acc = 0.0
                startEle = lastEle
            }
        }
        return out
    }
}
