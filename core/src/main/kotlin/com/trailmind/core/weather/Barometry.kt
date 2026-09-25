package com.trailmind.core.weather

import kotlin.math.pow

/** International Standard Atmosphere conversions between pressure and height. */
object Barometry {
    const val STANDARD_SEA_LEVEL_HPA = 1013.25
    private const val SCALE_M = 44330.77
    private const val EXPONENT = 5.255877

    fun altitudeM(pressureHpa: Double, seaLevelHpa: Double = STANDARD_SEA_LEVEL_HPA): Double =
        SCALE_M * (1 - (pressureHpa / seaLevelHpa).pow(1 / EXPONENT))

    fun pressureHpa(altitudeM: Double, seaLevelHpa: Double = STANDARD_SEA_LEVEL_HPA): Double =
        seaLevelHpa * (1 - altitudeM / SCALE_M).pow(EXPONENT)

    /** The sea-level pressure (QNH) that puts [pressureHpa] at [altitudeM]. */
    fun seaLevelHpa(pressureHpa: Double, altitudeM: Double): Double =
        pressureHpa / (1 - altitudeM / SCALE_M).pow(EXPONENT)
}

/**
 * Barometric altitude anchored to GPS. GPS altitude has no drift but is noisy (±10–20 m); the barometer
 * resolves about a metre but drifts as the weather changes. Every good GPS fix nudges the sea-level
 * pressure estimate, so the result follows GPS over minutes and the barometer from moment to moment.
 */
class BaroAltimeter(private val gain: Double = 0.02, private val maxAccuracyM: Double = 25.0) {
    var seaLevelHpa: Double? = null
        private set
    private var samples = 0

    fun onGps(pressureHpa: Double, gpsAltitudeM: Double, accuracyM: Double) {
        if (accuracyM > maxAccuracyM || pressureHpa !in 300.0..1100.0 || gpsAltitudeM.isNaN()) return
        val sample = Barometry.seaLevelHpa(pressureHpa, gpsAltitudeM)
        samples++
        // A running mean at first, then a slow filter that averages out GPS noise.
        val k = maxOf(gain, 1.0 / samples)
        seaLevelHpa = seaLevelHpa?.let { it + k * (sample - it) } ?: sample
    }

    fun altitudeM(pressureHpa: Double): Double? = seaLevelHpa?.let { Barometry.altitudeM(pressureHpa, it) }
}

/**
 * Sea-level pressure over the last few hours. A fall of [stormDropHpa] or more within [windowMs] is the
 * classic mountain "storm alarm". Sea-level rather than station pressure is used, so climbing doesn't count.
 */
class PressureTrend(
    private val windowMs: Long = 3 * 3_600_000L,
    private val sampleEveryMs: Long = 5 * 60_000L,
    val stormDropHpa: Double = 4.0,
) {
    enum class Tendency { UNKNOWN, RISING, STEADY, FALLING, FALLING_FAST }

    private val times = ArrayDeque<Long>()
    private val values = ArrayDeque<Double>()

    fun add(timeMs: Long, seaLevelHpa: Double) {
        if (times.isNotEmpty() && timeMs - times.last() < sampleEveryMs) return
        times.addLast(timeMs)
        values.addLast(seaLevelHpa)
        while (timeMs - times.first() > windowMs) {
            times.removeFirst()
            values.removeFirst()
        }
    }

    /** Change over the window in hPa (negative = falling), or null until most of the window is covered. */
    fun change(): Double? {
        if (times.size < 2 || times.last() - times.first() < windowMs * 0.8) return null
        return values.last() - values.first()
    }

    fun tendency(): Tendency {
        val c = change() ?: return Tendency.UNKNOWN
        return when {
            c <= -stormDropHpa -> Tendency.FALLING_FAST
            c <= -1.5 -> Tendency.FALLING
            c >= 1.5 -> Tendency.RISING
            else -> Tendency.STEADY
        }
    }
}
