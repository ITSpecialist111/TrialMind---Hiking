package com.trailmind.core.stats

import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.TrackPoint

data class TrackSummary(
    val distanceM: Double,
    val ascentM: Double,
    val descentM: Double,
    val minEleM: Double?,
    val maxEleM: Double?,
    val durationMs: Long,
    val movingMs: Long,
    val pointCount: Int,
) {
    val avgMovingSpeedMps: Double get() = if (movingMs > 0) distanceM / (movingMs / 1000.0) else 0.0

    companion object {
        val EMPTY = TrackSummary(0.0, 0.0, 0.0, null, null, 0, 0, 0)
    }
}

object TrackStats {
    /** Elevation changes smaller than this are treated as GPS/barometer noise. */
    const val DEFAULT_ELEVATION_THRESHOLD_M = 4.0
    const val MOVING_SPEED_MPS = 0.3

    fun summarize(
        points: List<TrackPoint>,
        elevationThresholdM: Double = DEFAULT_ELEVATION_THRESHOLD_M,
    ): TrackSummary {
        if (points.isEmpty()) return TrackSummary.EMPTY
        var distance = 0.0
        var moving = 0L
        for (i in 1 until points.size) {
            val a = points[i - 1]
            val b = points[i]
            val d = Geo.distanceM(a.lat, a.lon, b.lat, b.lon)
            distance += d
            val ta = a.timeMs
            val tb = b.timeMs
            if (ta != null && tb != null && tb > ta) {
                val dt = tb - ta
                // Gaps over 10 minutes are pauses (e.g. app paused) rather than slow walking.
                if (dt < 10 * 60_000 && d / (dt / 1000.0) >= MOVING_SPEED_MPS) moving += dt
            }
        }
        val (ascent, descent) = ascentDescent(points.mapNotNull { it.ele }, elevationThresholdM)
        val eles = points.mapNotNull { it.ele }
        val times = points.mapNotNull { it.timeMs }
        val duration = if (times.size >= 2) times.last() - times.first() else 0L
        return TrackSummary(distance, ascent, descent, eles.minOrNull(), eles.maxOrNull(), duration, moving, points.size)
    }

    /** Hysteresis-based ascent/descent: only counts a change once it exceeds [threshold]. */
    fun ascentDescent(elevations: List<Double>, threshold: Double = DEFAULT_ELEVATION_THRESHOLD_M): Pair<Double, Double> {
        if (elevations.isEmpty()) return 0.0 to 0.0
        var ref = elevations.first()
        var up = 0.0
        var down = 0.0
        for (e in elevations) {
            val d = e - ref
            if (d >= threshold) { up += d; ref = e } else if (-d >= threshold) { down += -d; ref = e }
        }
        return up to down
    }
}
