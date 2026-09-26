package com.trailmind.core.geo

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/**
 * Keeps a rotation-vector heading on magnetic north. Some sensor hubs (the Galaxy Watch4's, for one) fall back to
 * gyro-only fusion when their magnetometer is uncalibrated, and "north" is then wherever the device pointed when the
 * sensor started. Each magnetometer reading shows where magnetic north lies in the rotation vector's own frame; that
 * smoothed offset is taken off its heading. On a rotation vector that already follows the magnetometer it stays near 0.
 */
class NorthAnchor {
    private var sinA = 0.0
    private var cosA = 0.0
    private var has = false

    /** [r] is the rotation vector's 3x3 row-major matrix; [mx], [my], [mz] a magnetometer reading in device axes. */
    fun add(r: FloatArray, mx: Double, my: Double, mz: Double) {
        val east = r[0] * mx + r[1] * my + r[2] * mz
        val north = r[3] * mx + r[4] * my + r[5] * mz
        // The field's horizontal part gives the direction; skip readings where there is too little of it.
        if (east * east + north * north < MIN_HORIZONTAL_UT * MIN_HORIZONTAL_UT) return
        val a = atan2(east, north)
        if (!has) {
            sinA = sin(a)
            cosA = cos(a)
            has = true
        } else {
            sinA += SMOOTHING * (sin(a) - sinA)
            cosA += SMOOTHING * (cos(a) - cosA)
        }
    }

    /** Degrees to subtract from the rotation vector's azimuth to get a magnetic heading; 0 before any reading. */
    val offsetDeg: Double get() = if (has) Math.toDegrees(atan2(sinA, cosA)) else 0.0

    fun reset() {
        has = false
    }

    private companion object {
        const val SMOOTHING = 0.05
        const val MIN_HORIZONTAL_UT = 5.0
    }
}
