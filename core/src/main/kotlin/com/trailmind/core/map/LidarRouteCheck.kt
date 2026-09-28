package com.trailmind.core.map

import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.ceil
import kotlin.math.sqrt

/** A stretch of a route from [startM] to [endM] along it; [value] is its steepest angle or nearest crag, worst at [at]. */
data class LidarSection(val startM: Double, val endM: Double, val value: Double, val at: LatLon)

data class LidarRouteReport(
    val lengthM: Double,
    /** How much of the route LiDAR covers, in metres along it. */
    val coveredM: Double,
    /** Where the line climbs or drops at [LidarRouteCheck.STEEP_DEG] or more over [LidarRouteCheck.WINDOW_M]; value in degrees. */
    val steep: List<LidarSection>,
    /** Where a crag is within [LidarRouteCheck.CRAG_NEAR_M] of the line; value is the nearest distance in metres. */
    val crags: List<LidarSection>,
)

/** Checks a route line against 1 m LiDAR for ground steep enough to need hands, and crags beside it. */
object LidarRouteCheck {
    const val STEEP_DEG = 35.0
    const val WINDOW_M = 10.0
    const val CRAG_NEAR_M = 10
    /** Crags are looked for around points at most this far apart along the line. */
    private const val CRAG_STEP_M = 2.0
    private const val MAX_SECTIONS = 60

    interface Ground {
        /** Height at a grid position, or null where LiDAR has no data. */
        fun height(easting: Double, northing: Double): Double?
        /** Whether the 1 m cell at a grid position is crag. */
        fun crag(easting: Double, northing: Double): Boolean
    }

    fun check(points: List<LatLon>, ground: Ground): LidarRouteReport {
        if (points.size < 2) return LidarRouteReport(0.0, 0.0, emptyList(), emptyList())
        val grid = points.map { OsGrid.project(it) }
        // Samples at most a metre apart along the line.
        val along = ArrayList<Double>()
        val east = ArrayList<Double>()
        val north = ArrayList<Double>()
        val positions = ArrayList<LatLon>()
        var start = 0.0
        for (i in 1 until grid.size) {
            val a = grid[i - 1]
            val b = grid[i]
            val length = sqrt((b.easting - a.easting).let { it * it } + (b.northing - a.northing).let { it * it })
            val steps = ceil(length).toInt().coerceAtLeast(1)
            for (s in 0 until steps) {
                val f = s.toDouble() / steps
                along += start + length * f
                east += a.easting + (b.easting - a.easting) * f
                north += a.northing + (b.northing - a.northing) * f
                positions += LatLon(points[i - 1].lat + (points[i].lat - points[i - 1].lat) * f,
                    points[i - 1].lon + (points[i].lon - points[i - 1].lon) * f)
            }
            start += length
        }
        along += start
        east += grid.last().easting
        north += grid.last().northing
        positions += points.last()
        val n = along.size
        val heights = DoubleArray(n) { ground.height(east[it], north[it]) ?: Double.NaN }
        var covered = 0.0
        for (i in 1 until n) if (!heights[i].isNaN() && !heights[i - 1].isNaN()) covered += along[i] - along[i - 1]

        val steep = Sections(gapM = 2.0, worse = { a, b -> a > b })
        var j = 0
        for (i in 0 until n) {
            if (j < i) j = i
            while (j < n - 1 && along[j] - along[i] < WINDOW_M) j++
            val run = along[j] - along[i]
            if (run < WINDOW_M || heights[i].isNaN() || heights[j].isNaN()) continue
            val degrees = Math.toDegrees(atan(abs(heights[j] - heights[i]) / run))
            if (degrees >= STEEP_DEG) steep.add(along[i], along[j], degrees, positions[if (heights[j] > heights[i]) j else i])
        }

        val crags = Sections(gapM = 4.0, worse = { a, b -> a < b })
        val r2 = CRAG_NEAR_M * CRAG_NEAR_M
        // Probes no more than CRAG_STEP_M apart however the samples are spaced, and also where the line itself has no
        // height: a crag beside a gap in the survey (water, say) is still a crag.
        var probedAt = 0.0
        for (i in 0 until n) {
            if (i != 0 && i != n - 1 && along[i + 1] - probedAt <= CRAG_STEP_M) continue
            probedAt = along[i]
            var nearest = Int.MAX_VALUE
            for (dy in -CRAG_NEAR_M..CRAG_NEAR_M) for (dx in -CRAG_NEAR_M..CRAG_NEAR_M) {
                val d2 = dx * dx + dy * dy
                if (d2 > r2 || d2 >= nearest) continue
                if (ground.crag(east[i] + dx, north[i] + dy)) nearest = d2
            }
            if (nearest != Int.MAX_VALUE) crags.add(along[i], along[i], sqrt(nearest.toDouble()), positions[i])
        }
        return LidarRouteReport(start, covered, steep.list(), crags.list())
    }

    /** Joins overlapping or nearby stretches, keeping the worst value in each. */
    private class Sections(private val gapM: Double, private val worse: (Double, Double) -> Boolean) {
        private val out = ArrayList<LidarSection>()
        fun add(from: Double, to: Double, value: Double, at: LatLon) {
            val last = out.lastOrNull()
            if (last != null && from <= last.endM + gapM) {
                out[out.size - 1] = last.copy(endM = maxOf(last.endM, to),
                    value = if (worse(value, last.value)) value else last.value, at = if (worse(value, last.value)) at else last.at)
            } else out += LidarSection(from, to, value, at)
        }
        fun list(): List<LidarSection> = out.take(MAX_SECTIONS)
    }
}
