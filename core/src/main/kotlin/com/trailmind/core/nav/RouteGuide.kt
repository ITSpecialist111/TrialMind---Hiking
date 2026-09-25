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

    fun reset() {
        lastAlong = null
    }

    /**
     * Snaps [pos] to the route. For loops/out-and-back routes, among near-equal candidates the one
     * closest to the previous progress wins so the walker doesn't "teleport" to the return leg.
     */
    fun locate(pos: LatLon): RouteFix {
        val prev = lastAlong
        val best = nearestSegment(pos, prev)
        val (i, proj) = best
        val a = points[i]
        val b = points[i + 1]
        val along = cumulative[i] + proj.fraction * (cumulative[i + 1] - cumulative[i])
        lastAlong = along
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
            routeBearingDeg = Geo.bearingDeg(a.latLon(), b.latLon()),
            progress = if (totalM > 0) (along / totalM).coerceIn(0.0, 1.0) else 0.0,
            nextWaypoint = next,
            atEnd = totalM - along < 25.0,
        )
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

    private fun nearestSegment(pos: LatLon, prevAlong: Double?): Pair<Int, com.trailmind.core.geo.SegmentProjection> {
        val projections = ArrayList<Pair<Int, com.trailmind.core.geo.SegmentProjection>>(points.size)
        var minDist = Double.MAX_VALUE
        for (i in 0 until points.size - 1) {
            val proj = Geo.projectOntoSegment(pos, points[i].latLon(), points[i + 1].latLon())
            projections.add(i to proj)
            if (proj.distanceM < minDist) minDist = proj.distanceM
        }
        val best = projections.minBy { it.second.distanceM }
        if (prevAlong == null) return best
        // Only local minima are genuine alternative "legs" (e.g. the return half of an
        // out-and-back); neighbouring segments of the same leg are never better candidates.
        val candidates = projections.filterIndexed { idx, (_, p) ->
            p.distanceM <= minDist + AMBIGUITY_M &&
                (idx == 0 || p.distanceM <= projections[idx - 1].second.distanceM) &&
                (idx == projections.size - 1 || p.distanceM <= projections[idx + 1].second.distanceM)
        }
        if (candidates.size <= 1) return best
        return candidates.minBy { (i, p) ->
            val along = cumulative[i] + p.fraction * (cumulative[i + 1] - cumulative[i])
            abs(along - prevAlong)
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
