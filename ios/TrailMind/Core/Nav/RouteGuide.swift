import Foundation

/// Where the walker is relative to a followed route line.
struct RouteFix: Hashable {
    var segmentIndex: Int
    var snapped: LatLon
    /// Perpendicular distance from the route, metres.
    var offRouteM: Double
    /// Distance travelled along the route to the snapped point, metres.
    var alongM: Double
    var remainingM: Double
    var remainingAscentM: Double
    /// Direction the route heads at this point, degrees true.
    var routeBearingDeg: Double
    var progress: Double
    var nextWaypoint: WaypointAhead?
    /// True when the closest point is the very end of the route.
    var atEnd: Bool
}

struct WaypointAhead: Hashable {
    var waypoint: Waypoint
    var alongRouteM: Double
    var directM: Double
    var bearingDeg: Double
}

/// Follows an imported line (GPX track or route). This is *guidance along a pre-planned line*, not turn-by-turn routing
/// on a path network: TrailMind does not compute new routes.
final class RouteGuide {
    /// Thrown for a line without two distinct points (Kotlin's `require` failure, which the app catches).
    struct InvalidRoute: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let points: [TrackPoint]
    let cumulative: [Double]
    let totalM: Double

    /// ascentFrom[i] = hysteresis-free positive elevation gain from point i to the end.
    private let ascentFrom: [Double]

    private var waypointsAlong: [(waypoint: Waypoint, along: Double)] = []

    private var lastAlong: Double?
    private var lastTimeMs: Int64?
    private var pendingJump = 0

    private static let ambiguityM = 20.0

    init(_ points: [TrackPoint], waypoints: [Waypoint] = []) throws {
        let kept = points.indices.filter { i in
            i == 0 || Geo.distanceM(points[i - 1].lat, points[i - 1].lon, points[i].lat, points[i].lon) > 0.01
        }.map { points[$0] }
        self.points = kept
        cumulative = Geo.cumulativeDistances(kept)
        totalM = cumulative.last ?? 0.0
        var arr = [Double](repeating: 0.0, count: kept.count)
        for i in stride(from: kept.count - 2, through: 0, by: -1) {
            let a = kept[i].ele
            let b = kept[i + 1].ele
            var gain = 0.0
            if let a, let b, b > a { gain = b - a }
            arr[i] = arr[i + 1] + gain
        }
        ascentFrom = arr
        waypointsAlong = waypoints.compactMap { w -> (waypoint: Waypoint, along: Double)? in
            guard let fix = nearest(w.latLon(), nil) else { return nil }
            return fix.distanceM > 200.0 ? nil : (w, fix.along)
        }.enumerated().sorted { ($0.element.along, $0.offset) < ($1.element.along, $1.offset) }.map { $0.element }
        guard kept.count >= 2 else { throw InvalidRoute(message: "A route needs at least two distinct points") }
    }

    func reset() {
        lastAlong = nil
        lastTimeMs = nil
        pendingJump = 0
    }

    /// Snaps `pos` to the route. For loops/out-and-back routes, among near-equal candidates the one closest to the
    /// previous progress wins so the walker doesn't "teleport" to the return leg.
    @discardableResult
    func locate(_ pos: LatLon, timeMs: Int64 = nowMs()) -> RouteFix {
        let prev = lastAlong
        let elapsed = lastTimeMs.map { min(Double(max(timeMs - $0, 0)) / 1000.0, 3600.0) } ?? 0.0
        let window = 150.0 + 12.0 * elapsed
        let (i, proj) = nearestSegment(pos, prev, window: window, elapsed: elapsed)
        let along = cumulative[i] + proj.fraction * (cumulative[i + 1] - cumulative[i])
        if let prev, (along < prev - window || along > prev + max(window, 750.0)) && elapsed < 300.0 {
            pendingJump += 1
            if pendingJump < 2 { return fixAt(prev, pos) }
        }
        pendingJump = 0
        lastAlong = along
        lastTimeMs = timeMs
        return makeFix(i, proj, along, pos)
    }

    private func fixAt(_ along: Double, _ pos: LatLon) -> RouteFix {
        let snapped = pointAt(along)
        let found = Self.binarySearch(cumulative, along)
        let i = found >= 0 ? min(found, points.count - 2) : (-found - 2).clamped(0, points.count - 2)
        let fraction = ((along - cumulative[i]) / (cumulative[i + 1] - cumulative[i])).clamped(0.0, 1.0)
        let projection = SegmentProjection(fraction: fraction, distanceM: Geo.distanceM(pos, snapped), closest: snapped)
        return makeFix(i, projection, along, pos)
    }

    private func makeFix(_ i: Int, _ proj: SegmentProjection, _ along: Double, _ pos: LatLon) -> RouteFix {
        let remainingAscent = remainingAscent(i, proj.fraction)
        let next = waypointsAlong.first(where: { $0.along > along + 5.0 }).map { w in
            WaypointAhead(waypoint: w.waypoint, alongRouteM: w.along - along, directM: Geo.distanceM(pos, w.waypoint.latLon()),
                          bearingDeg: Geo.bearingDeg(pos, w.waypoint.latLon()))
        }
        return RouteFix(
            segmentIndex: i,
            snapped: proj.closest,
            offRouteM: proj.distanceM,
            alongM: along,
            remainingM: max(totalM - along, 0.0),
            remainingAscentM: remainingAscent,
            routeBearingDeg: Geo.bearingDeg(points[i].latLon(), points[i + 1].latLon()),
            progress: totalM > 0 ? (along / totalM).clamped(0.0, 1.0) : 0.0,
            nextWaypoint: next,
            atEnd: totalM - along < 25.0
        )
    }

    /// The point `alongM` metres from the start of the route, clamped to its ends.
    func pointAt(_ alongM: Double) -> LatLon {
        let d = alongM.clamped(0.0, totalM)
        let found = Self.binarySearch(cumulative, d)
        let i = (found >= 0 ? found : -found - 2).clamped(0, points.count - 2)
        let span = cumulative[i + 1] - cumulative[i]
        let f = span > 0 ? (d - cumulative[i]) / span : 0.0
        let a = points[i]
        let b = points[i + 1]
        return LatLon(a.lat + (b.lat - a.lat) * f, a.lon + (b.lon - a.lon) * f)
    }

    private func remainingAscent(_ i: Int, _ fraction: Double) -> Double {
        var partial = 0.0
        if let a = points[i].ele, let b = points[i + 1].ele, b > a { partial = (b - a) * (1 - fraction) }
        return ascentFrom[i + 1] + partial
    }

    private func nearest(_ pos: LatLon, _ prev: Double?) -> (along: Double, distanceM: Double)? {
        if points.count < 2 { return nil }
        let (i, proj) = nearestSegment(pos, prev)
        return (cumulative[i] + proj.fraction * (cumulative[i + 1] - cumulative[i]), proj.distanceM)
    }

    private func alongOf(_ candidate: (Int, SegmentProjection)) -> Double {
        let (i, p) = candidate
        return cumulative[i] + p.fraction * (cumulative[i + 1] - cumulative[i])
    }

    private func nearestSegment(_ pos: LatLon, _ prevAlong: Double?, window: Double = Double.greatestFiniteMagnitude,
                                elapsed: Double = 0.0) -> (Int, SegmentProjection) {
        var projections: [(Int, SegmentProjection)] = []
        projections.reserveCapacity(points.count)
        var minDist = Double.greatestFiniteMagnitude
        for i in 0..<(points.count - 1) {
            let proj = Geo.projectOntoSegment(pos, points[i].latLon(), points[i + 1].latLon())
            projections.append((i, proj))
            if proj.distanceM < minDist { minDist = proj.distanceM }
        }
        // Kotlin's minBy/minByOrNull: the first of the smallest.
        func first(_ items: [(Int, SegmentProjection)], by key: ((Int, SegmentProjection)) -> Double) -> (Int, SegmentProjection)? {
            items.min { key($0) < key($1) }
        }
        let best = first(projections) { $0.1.distanceM }!
        guard let prevAlong else { return best }
        let forward = first(projections.filter { c in
            let along = alongOf(c)
            return along >= prevAlong - window && along <= prevAlong + window && c.1.distanceM <= 100.0
        }) { $0.1.distanceM }
        let bestAlong = alongOf(best)
        if elapsed < 300.0 && bestAlong < prevAlong - window, let forward {
            let forwardAlong = alongOf(forward)
            if forward.1.distanceM * 3.0 + abs(forwardAlong - prevAlong) * 0.1 <
                best.1.distanceM * 3.0 + abs(bestAlong - prevAlong) * 0.1 { return forward }
        }
        if bestAlong < prevAlong - window {
            let ahead = first(projections.filter { c in
                let along = alongOf(c)
                return c.1.distanceM <= minDist + Self.ambiguityM &&
                    along > prevAlong && (along <= prevAlong + max(window, 750.0) || along - prevAlong < prevAlong - bestAlong)
            }) { alongOf($0) }
            if let ahead { return ahead }
        }
        let candidates = projections.filter { c in
            c.1.distanceM <= minDist + Self.ambiguityM && abs(alongOf(c) - prevAlong) <= window
        }
        if candidates.isEmpty { return best }
        return first(candidates) { c in
            let along = alongOf(c)
            return c.1.distanceM * 3.0 + abs(along - prevAlong) * 0.1 + (along < prevAlong - 5.0 ? 3.0 : 0.0)
        }!
    }

    /// `java.util.Arrays.binarySearch` on doubles: the index of `key`, or `-(insertion point) - 1`.
    private static func binarySearch(_ a: [Double], _ key: Double) -> Int {
        func bits(_ v: Double) -> Int64 { v.isNaN ? 0x7ff8_0000_0000_0000 : Int64(bitPattern: v.bitPattern) }
        var low = 0
        var high = a.count - 1
        while low <= high {
            let mid = (low + high) >> 1
            let midVal = a[mid]
            if midVal < key {
                low = mid + 1
            } else if midVal > key {
                high = mid - 1
            } else {
                let midBits = bits(midVal)
                let keyBits = bits(key)
                if midBits == keyBits { return mid }
                if midBits < keyBits { low = mid + 1 } else { high = mid - 1 }
            }
        }
        return -(low + 1)
    }
}

/// Hysteresis so a single bad GPS fix doesn't trigger an alarm: requires `confirmFixes` consecutive fixes beyond
/// `thresholdM` (after subtracting reported accuracy) to go off-route, and a fix back inside 70% of the threshold to
/// return.
final class OffRouteDetector {
    enum Event { case none, leftRoute, rejoinedRoute }

    let thresholdM: Double
    private let confirmFixes: Int
    private(set) var isOffRoute = false
    private var strikes = 0

    init(thresholdM: Double = 50.0, confirmFixes: Int = 3) {
        self.thresholdM = thresholdM
        self.confirmFixes = confirmFixes
    }

    @discardableResult
    func update(_ offRouteM: Double, accuracyM: Double = 0.0) -> Event {
        let effective = offRouteM - accuracyM.clamped(0.0, thresholdM)
        if !isOffRoute {
            strikes = effective > thresholdM ? strikes + 1 : 0
            if strikes >= confirmFixes {
                isOffRoute = true
                strikes = 0
                return .leftRoute
            }
        } else if offRouteM < thresholdM * 0.7 {
            isOffRoute = false
            strikes = 0
            return .rejoinedRoute
        }
        return .none
    }
}
