package com.trailmind.core.stats

import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.TrackPoint
import kotlin.math.abs
import kotlin.math.exp

data class HikeEstimate(
    /** Naismith (flat pace + 10 min per 100 m ascent) with Langmuir descent corrections. */
    val naismithMinutes: Double,
    /** Tobler's hiking function integrated per segment, scaled to the user's flat pace. */
    val toblerMinutes: Double,
    val distanceM: Double,
    val ascentM: Double,
    val descentM: Double,
) {
    /** Conservative planning figure: the slower of the two methods. */
    val planningMinutes: Double get() = maxOf(naismithMinutes, toblerMinutes)
}

data class PaceSettings(
    val flatSpeedKmh: Double = 5.0,
    /** Additional multiplier for load, group, conditions (1.0 = none, 1.2 = 20% slower). */
    val conditionsFactor: Double = 1.0,
) {
    init {
        require(flatSpeedKmh in 1.0..10.0) { "flat speed must be 1-10 km/h" }
        require(conditionsFactor in 0.5..3.0) { "conditions factor must be 0.5-3" }
    }
}

/** A route's highest point and the planning time, before breaks, to walk there from the start. */
data class HighPoint(val position: LatLon, val eleM: Double, val minutesFromStart: Double)

/**
 * Walking-time estimates. These are rules of thumb for fit adults on paths: always allow extra for
 * rough ground, navigation, weather and breaks.
 */
object HikeEstimator {
    private const val SEGMENT_M = 50.0

    fun estimate(points: List<TrackPoint>, pace: PaceSettings = PaceSettings()): HikeEstimate {
        val segs = resample(points)
        var distance = 0.0
        var ascent = 0.0
        var descent = 0.0
        var naismithH = 0.0
        var toblerH = 0.0
        var gentleDescent = 0.0
        var steepDescent = 0.0
        val toblerScale = pace.flatSpeedKmh / TOBLER_FLAT_KMH
        for (s in segs) {
            distance += s.lengthM
            if (s.dEle > 0) ascent += s.dEle else descent += -s.dEle
            val slope = if (s.lengthM > 0) s.dEle / s.lengthM else 0.0
            if (s.dEle < 0) {
                val deg = Math.toDegrees(kotlin.math.atan(abs(slope)))
                when {
                    deg in 5.0..12.0 -> gentleDescent += -s.dEle
                    deg > 12.0 -> steepDescent += -s.dEle
                }
            }
            val speedKmh = TOBLER_A * exp(-3.5 * abs(slope + 0.05)) * toblerScale
            toblerH += (s.lengthM / 1000.0) / speedKmh.coerceAtLeast(0.5)
        }
        naismithH = distance / 1000.0 / pace.flatSpeedKmh + ascent / 600.0
        // Langmuir: -10 min per 300 m of gentle descent, +10 min per 300 m of steep descent.
        naismithH += (-gentleDescent + steepDescent) / 300.0 * (10.0 / 60.0)
        naismithH = naismithH.coerceAtLeast(distance / 1000.0 / pace.flatSpeedKmh)
        return HikeEstimate(
            naismithMinutes = naismithH * 60.0 * pace.conditionsFactor,
            toblerMinutes = toblerH * 60.0 * pace.conditionsFactor,
            distanceM = distance,
            ascentM = ascent,
            descentM = descent,
        )
    }

    /** The first of the highest points of [points], or null when they have no heights. */
    fun highPoint(points: List<TrackPoint>, pace: PaceSettings = PaceSettings()): HighPoint? {
        var best = -1
        var bestEle = Double.NEGATIVE_INFINITY
        points.forEachIndexed { i, p -> val e = p.ele; if (e != null && e > bestEle) { best = i; bestEle = e } }
        if (best < 0) return null
        val minutes = if (best == 0) 0.0 else estimate(points.subList(0, best + 1), pace).planningMinutes
        return HighPoint(points[best].latLon(), bestEle, minutes)
    }

    private const val TOBLER_A = 6.0
    private val TOBLER_FLAT_KMH = TOBLER_A * exp(-3.5 * 0.05)

    internal data class Seg(val lengthM: Double, val dEle: Double)

    /**
     * Groups points into ~50 m chunks so GPS jitter doesn't create fake slopes. Elevation deltas
     * are only used if both chunk ends have elevation.
     */
    internal fun resample(points: List<TrackPoint>): List<Seg> {
        if (points.size < 2) return emptyList()
        val out = ArrayList<Seg>()
        var startEle = points.first().ele
        var acc = 0.0
        var lastEle = startEle
        for (i in 1 until points.size) {
            val a = points[i - 1]
            val b = points[i]
            acc += Geo.distanceM(a.lat, a.lon, b.lat, b.lon)
            if (b.ele != null) lastEle = b.ele
            if (acc >= SEGMENT_M || i == points.size - 1) {
                val d = if (startEle != null && lastEle != null) lastEle - startEle else 0.0
                if (acc > 0) out.add(Seg(acc, d))
                acc = 0.0
                startEle = lastEle
            }
        }
        return out
    }
}
