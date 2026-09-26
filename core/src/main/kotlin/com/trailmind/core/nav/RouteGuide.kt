package com.trailmind.core.nav

import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Waypoint
import kotlin.math.abs

/** Where the walker is relative to a followed route line. */
data class RouteFix(
    val segmentIndex: Int,
    val snapped: LatLon,
    /** Perpendicular distance from the route, metres. */
    val offRouteM: Double,
    /** Distance travelled along the route to the snapped point, metres. */
    val alongM: Double,
    val remainingM: Double,
    val remainingAscentM: Double,
    /** Direction the route heads at this point, degrees true. */
    val routeBearingDeg: Double,
    val progress: Double,
    val nextWaypoint: WaypointAhead?,
    /** True when the closest point is the very end of the route. */
    val atEnd: Boolean,
)

data class WaypointAhead(val waypoint: Waypoint, val alongRouteM: Double, val directM: Double, val bearingDeg: Double)

/**
 * Follows an imported line (GPX track or route). This is *guidance along a pre-planned line*, not
 * turn-by-turn routing on a path network: TrailMind does not compute new routes.
 */
class RouteGuide(points: List<TrackPoint>, waypoints: List<Waypoint> = emptyList()) {
    val points: List<TrackPoint> = points.filterIndexed { i, p ->
        i == 0 || Geo.distanceM(points[i - 1].lat, points[i - 1].lon, p.lat, p.lon) > 0.01
    }
    val cumulative: DoubleArray = Geo.cumulativeDistances(this.points)
    val totalM: Double = cumulative.lastOrNull() ?: 0.0

    /** ascentFrom[i] = hysteresis-free positive elevation gain from point i to the end. */
    private val ascentFrom: DoubleArray = DoubleArray(this.points.size).also { arr ->
        for (i in this.points.size - 2 downTo 0) {
            val a = this.points[i].ele
            val b = this.points[i + 1].ele
            val gain = if (a != null && b != null && b > a) b - a else 0.0
            arr[i] = arr[i + 1] + gain
        }
    }

    private val waypointsAlong: List<Pair<Waypoint, Double>> = waypoints.mapNotNull { w ->
        val fix = nearest(w.latLon(), null) ?: return@mapNotNull null
        if (fix.second > 200.0) null else w to fix.first
    }.sortedBy { it.second }

    init {
        require(this.points.size >= 2) { "A route needs at least two distinct points" }
    }

    private var lastAlong: Double? = null
    private var lastTimeMs: Long? = null
    private var pendingJump = 0

    fun reset() {
        lastAlong = null
        lastTimeMs = null
        pendingJump = 0
    }

    /**
     * Snaps [pos] to the route. For loops/out-and-back routes, among near-equal candidates the one
     * closest to the previous progress wins so the walker doesn't "teleport" to the return leg.
     */
    fun locate(pos: LatLon, timeMs: Long = System.currentTimeMillis()): RouteFix {
        val prev = lastAlong
        val elapsed = lastTimeMs?.let { ((timeMs - it).coerceAtLeast(0L) / 1000.0).coerceAtMost(3600.0) } ?: 0.0
        val window = 150.0 + 12.0 * elapsed
        val best = nearestSegment(pos, prev, window, elapsed)
        val (i, proj) = best
        val a = points[i]
        val b = points[i + 1]
        val along = cumulative[i] + proj.fraction * (cumulative[i + 1] - cumulative[i])
        if (prev != null && (along < prev - window || along > prev + maxOf(window, 750.0)) && elapsed < 300.0) {
            pendingJump++
            if (pendingJump < 2) return fixAt(prev, pos)
        }
        pendingJump = 0
        lastAlong = along
        lastTimeMs = timeMs
        return makeFix(i, proj, along, pos)
    }

    private fun fixAt(along: Double, pos: LatLon): RouteFix {
        val snapped = pointAt(along)
        val i = cumulative.binarySearch(along).let { if (it >= 0) it.coerceAtMost(points.size - 2) else (-it - 2).coerceIn(0, points.size - 2) }
        val fraction = ((along - cumulative[i]) / (cumulative[i + 1] - cumulative[i])).coerceIn(0.0, 1.0)
        val projection = com.trailmind.core.geo.SegmentProjection(fraction, Geo.distanceM(pos, snapped), snapped)
        return makeFix(i, projection, along, pos)
    }

    private fun makeFix(i: Int, proj: com.trailmind.core.geo.SegmentProjection, along: Double, pos: LatLon): RouteFix {
        val remainingAscent = remainingAscent(i, proj.fraction)
        val next = waypointsAlong.firstOrNull { it.second > along + 5.0 }?.let { (w, wAlong) ->
            WaypointAhead(w, wAlong - along, Geo.distanceM(pos, w.latLon()), Geo.bearingDeg(pos, w.latLon()))
        }
        return RouteFix(
            segmentIndex = i,
            snapped = proj.closest,
            offRouteM = proj.distanceM,
            alongM = along,
            remainingM = (totalM - along).coerceAtLeast(0.0),
            remainingAscentM = remainingAscent,
            routeBearingDeg = Geo.bearingDeg(points[i].latLon(), points[i + 1].latLon()),
            progress = if (totalM > 0) (along / totalM).coerceIn(0.0, 1.0) else 0.0,
            nextWaypoint = next,
            atEnd = totalM - along < 25.0,
        )
    }

    /** The point [alongM] metres from the start of the route, clamped to its ends. */
    fun pointAt(alongM: Double): LatLon {
        val d = alongM.coerceIn(0.0, totalM)
        val i = cumulative.binarySearch(d).let { if (it >= 0) it else -it - 2 }.coerceIn(0, points.size - 2)
        val span = cumulative[i + 1] - cumulative[i]
        val f = if (span > 0) (d - cumulative[i]) / span else 0.0
        val a = points[i]
        val b = points[i + 1]
        return LatLon(a.lat + (b.lat - a.lat) * f, a.lon + (b.lon - a.lon) * f)
    }

    private fun remainingAscent(i: Int, fraction: Double): Double {
        val a = points[i].ele
        val b = points[i + 1].ele
        val partial = if (a != null && b != null && b > a) (b - a) * (1 - fraction) else 0.0
        return ascentFrom[i + 1] + partial
    }

    private fun nearest(pos: LatLon, prev: Double?): Pair<Double, Double>? {
        if (points.size < 2) return null
        val (i, proj) = nearestSegment(pos, prev)
        return (cumulative[i] + proj.fraction * (cumulative[i + 1] - cumulative[i])) to proj.distanceM
    }

    private fun nearestSegment(pos: LatLon, prevAlong: Double?, window: Double = Double.MAX_VALUE,
        elapsed: Double = 0.0): Pair<Int, com.trailmind.core.geo.SegmentProjection> {
        val projections = ArrayList<Pair<Int, com.trailmind.core.geo.SegmentProjection>>(points.size)
        var minDist = Double.MAX_VALUE
        for (i in 0 until points.size - 1) {
            val proj = Geo.projectOntoSegment(pos, points[i].latLon(), points[i + 1].latLon())
            projections.add(i to proj)
            if (proj.distanceM < minDist) minDist = proj.distanceM
        }
        val best = projections.minBy { it.second.distanceM }
        if (prevAlong == null) return best
        val forward = projections.filter { (i, p) ->
            val along = cumulative[i] + p.fraction * (cumulative[i + 1] - cumulative[i])
            along in (prevAlong - window)..(prevAlong + window) && p.distanceM <= 100.0
        }.minByOrNull { it.second.distanceM }
        val bestAlong = cumulative[best.first] + best.second.fraction * (cumulative[best.first + 1] - cumulative[best.first])
        if (elapsed < 300.0 && bestAlong < prevAlong - window && forward != null) {
            val forwardAlong = cumulative[forward.first] + forward.second.fraction * (cumulative[forward.first + 1] - cumulative[forward.first])
            if (forward.second.distanceM * 3.0 + abs(forwardAlong - prevAlong) * 0.1 <
                best.second.distanceM * 3.0 + abs(bestAlong - prevAlong) * 0.1) return forward
        }
        if (bestAlong < prevAlong - window) {
            val ahead = projections.filter { (i, p) ->
                val along = cumulative[i] + p.fraction * (cumulative[i + 1] - cumulative[i])
                p.distanceM <= minDist + AMBIGUITY_M &&
                    along > prevAlong && (along <= prevAlong + maxOf(window, 750.0) ||
                        along - prevAlong < prevAlong - bestAlong)
            }.minByOrNull { (i, p) -> cumulative[i] + p.fraction * (cumulative[i + 1] - cumulative[i]) }
            if (ahead != null) return ahead
        }
        val candidates = projections.filter { (i, p) ->
            val along = cumulative[i] + p.fraction * (cumulative[i + 1] - cumulative[i])
            p.distanceM <= minDist + AMBIGUITY_M && abs(along - prevAlong) <= window
        }
        if (candidates.isEmpty()) return best
        return candidates.minBy { (i, p) ->
            val along = cumulative[i] + p.fraction * (cumulative[i + 1] - cumulative[i])
            p.distanceM * 3.0 + abs(along - prevAlong) * 0.1 + if (along < prevAlong - 5.0) 3.0 else 0.0
        }
    }

    companion object {
        private const val AMBIGUITY_M = 20.0
    }
}

/**
 * Hysteresis so a single bad GPS fix doesn't trigger an alarm: requires [confirmFixes]
 * consecutive fixes beyond [thresholdM] (after subtracting reported accuracy) to go off-route,
 * and a fix back inside 70% of the threshold to return.
 */
class OffRouteDetector(val thresholdM: Double = 50.0, private val confirmFixes: Int = 3) {
    enum class Event { NONE, LEFT_ROUTE, REJOINED_ROUTE }

    var isOffRoute: Boolean = false
        private set
    private var strikes = 0

    fun update(offRouteM: Double, accuracyM: Double = 0.0): Event {
        val effective = offRouteM - accuracyM.coerceIn(0.0, thresholdM)
        if (!isOffRoute) {
            strikes = if (effective > thresholdM) strikes + 1 else 0
            if (strikes >= confirmFixes) {
                isOffRoute = true
                strikes = 0
                return Event.LEFT_ROUTE
            }
        } else if (offRouteM < thresholdM * 0.7) {
            isOffRoute = false
            strikes = 0
            return Event.REJOINED_ROUTE
        }
        return Event.NONE
    }
}
