package com.trailmind.core.nav

import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.TrackPoint

/**
 * Decides which GPS fixes are recorded as breadcrumbs. Rejects poor-accuracy fixes, jitter while
 * standing still, and physically implausible jumps for someone on foot.
 */
class TrackFilter(
    private val maxAccuracyM: Float = 35f,
    private val minDistanceM: Double = 5.0,
    private val maxSpeedMps: Double = 12.0,
    private val keepAliveMs: Long = 60_000,
) {
    private var last: TrackPoint? = null

    fun reset(lastAccepted: TrackPoint? = null) {
        last = lastAccepted
    }

    fun accept(p: TrackPoint): Boolean {
        val acc = p.accuracyM
        if (acc != null && acc > maxAccuracyM) return false
        val prev = last
        if (prev == null) {
            last = p
            return true
        }
        val d = Geo.distanceM(prev.lat, prev.lon, p.lat, p.lon)
        val t0 = prev.timeMs
        val t1 = p.timeMs
        if (t0 != null && t1 != null) {
            val dt = (t1 - t0) / 1000.0
            if (dt <= 0) return false
            if (d / dt > maxSpeedMps && d > 50) return false
            if (d < minDistanceM && (t1 - t0) < keepAliveMs) return false
        } else if (d < minDistanceM) {
            return false
        }
        last = p
        return true
    }
}
