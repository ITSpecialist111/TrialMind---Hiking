package com.trailmind.core.geo

import com.trailmind.core.stats.HikeEstimator
import com.trailmind.core.stats.PaceSettings

data class PlanPart(val points: List<TrackPoint>, val snapped: Boolean)
data class PlanLeg(val start: LatLon, val end: LatLon, val points: List<TrackPoint>, val snapped: Boolean,
    val parts: List<PlanPart> = listOf(PlanPart(points, snapped)))

class RoutePlan {
    private val controls = ArrayList<LatLon>()
    private val segments = ArrayList<PlanLeg>()
    val controlPoints: List<LatLon> get() = controls.toList()
    val legs: List<PlanLeg> get() = segments.toList()
    val isLoop: Boolean get() = segments.isNotEmpty() && controls.last() == controls.first()

    fun add(point: LatLon): Boolean {
        if (!point.isValid || isLoop || controls.lastOrNull() == point) return false
        controls.lastOrNull()?.let { start ->
            segments += PlanLeg(start, point, listOf(TrackPoint(start.lat, start.lon), TrackPoint(point.lat, point.lon)), false)
        }
        controls += point
        return true
    }

    fun backToStart(): Boolean = if (controls.size >= 2 && !isLoop) add(controls.first()) else false

    fun replaceLeg(index: Int, points: List<TrackPoint>, expected: PlanLeg? = null): Boolean {
        val leg = segments.getOrNull(index) ?: return false
        if (expected != null && leg !== expected) return false
        if (points.size < 2 || points.any { !it.latLon().isValid || it.ele?.isFinite() == false }) return false
        val first = points.first().latLon()
        val last = points.last().latLon()
        if (points.zipWithNext().none { (a, b) -> a.lat != b.lat || a.lon != b.lon }) return false
        if (Geo.distanceM(first, leg.start) > 250 || Geo.distanceM(last, leg.end) > 250) return false
        val line = ArrayList<TrackPoint>()
        line += TrackPoint(leg.start.lat, leg.start.lon, points.first().ele)
        if (first != leg.start) line += points.first()
        line += points.drop(1)
        if (last != leg.end) line += TrackPoint(leg.end.lat, leg.end.lon, points.last().ele)
        val parts = ArrayList<PlanPart>()
        val startConnector = Geo.distanceM(first, leg.start) > 5
        val endConnector = Geo.distanceM(last, leg.end) > 5
        if (startConnector) parts += PlanPart(line.take(2), false)
        parts += PlanPart(line.subList(if (startConnector) 1 else 0, line.size - if (endConnector) 1 else 0), true)
        if (endConnector) parts += PlanPart(line.takeLast(2), false)
        segments[index] = leg.copy(points = line, snapped = true, parts = parts)
        return true
    }

    fun undo(): Boolean {
        if (controls.isEmpty()) return false
        controls.removeAt(controls.lastIndex)
        if (segments.isNotEmpty()) segments.removeAt(segments.lastIndex)
        return true
    }

    fun clear() { controls.clear(); segments.clear() }

    val line: List<TrackPoint> get() {
        if (segments.isEmpty()) return controls.firstOrNull()?.let { listOf(TrackPoint(it.lat, it.lon)) } ?: emptyList()
        val joined = ArrayList<TrackPoint>()
        segments.forEach { leg ->
            if (joined.isEmpty()) joined += leg.points.first()
            else if (joined.last().ele == null && leg.points.first().ele != null) joined[joined.lastIndex] = leg.points.first()
            joined += leg.points.drop(1)
        }
        return joined
    }

    fun estimate(pace: PaceSettings) = HikeEstimator.estimate(line, pace)
}