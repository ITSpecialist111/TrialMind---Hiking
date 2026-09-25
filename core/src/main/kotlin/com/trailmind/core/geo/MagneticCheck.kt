package com.trailmind.core.geo

import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Whether a magnetometer sees only the Earth's field, judged by comparing the strength and dip of what it
 * measures with the geomagnetic model at your position. Nearby steel, a magnet, electronics or an offset the
 * sensor has not calibrated out all show up here, even while the sensor reports itself as calibrated.
 */
class MagneticCheck(private val strengthTolerance: Double = 0.15, private val dipToleranceDeg: Double = 10.0) {
    private var expectedUt = Double.NaN
    private var expectedDipDeg = Double.NaN

    /** Smoothed measured strength, microtesla. */
    var strengthUt = Double.NaN; private set
    /** Smoothed measured dip below the horizontal, degrees. */
    var dipDeg = Double.NaN; private set
    var disturbed = false; private set

    /** The model's field where you are: strength in microtesla and dip (inclination) in degrees below horizontal. */
    fun expect(strengthUt: Double, dipDeg: Double) {
        expectedUt = strengthUt
        expectedDipDeg = dipDeg
    }

    /** A reading [mx], [my], [mz] in microtesla and the unit vector [ux], [uy], [uz] pointing up, both in device axes. */
    fun add(mx: Double, my: Double, mz: Double, ux: Double, uy: Double, uz: Double) {
        val s = sqrt(mx * mx + my * my + mz * mz)
        if (s == 0.0 || s.isNaN()) return
        val d = Math.toDegrees(asin((-(mx * ux + my * uy + mz * uz) / s).coerceIn(-1.0, 1.0)))
        if (strengthUt.isNaN()) {
            strengthUt = s
            dipDeg = d
        } else {
            strengthUt += SMOOTHING * (s - strengthUt)
            dipDeg += SMOOTHING * (d - dipDeg)
        }
        if (expectedUt.isNaN()) return
        val excess = max(abs(strengthUt / expectedUt - 1) / strengthTolerance, abs(dipDeg - expectedDipDeg) / dipToleranceDeg)
        // Hysteresis, so a reading near the limit does not flicker the warning.
        disturbed = excess > (if (disturbed) 0.75 else 1.0)
    }

    fun reset() {
        strengthUt = Double.NaN
        dipDeg = Double.NaN
        disturbed = false
    }

    private companion object {
        const val SMOOTHING = 0.25
    }
}
