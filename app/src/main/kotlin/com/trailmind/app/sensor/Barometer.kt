package com.trailmind.app.sensor

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import com.trailmind.core.weather.BaroAltimeter
import com.trailmind.core.weather.PressureTrend
import java.util.Locale
import kotlin.math.roundToInt

/**
 * The pressure sensor, when the phone has one (the Galaxy Z Fold does). It gives a barometric altitude
 * anchored to GPS, which makes recorded ascent far less noisy, and a sea-level pressure trend for
 * weather warnings. It listens only while the UI or a recording holds it.
 */
class Barometer(context: Context) : SensorEventListener {
    private val sm = context.getSystemService(SensorManager::class.java)
    private val sensor: Sensor? = sm?.getDefaultSensor(Sensor.TYPE_PRESSURE)
    private val altimeter = BaroAltimeter()
    private val trend = PressureTrend()
    private var users = 0
    private var lastFixTimeMs = 0L

    val available: Boolean get() = sensor != null
    val stormDropHpa: Double get() = trend.stormDropHpa

    /** Smoothed station pressure in hPa; null when not listening or no reading yet. */
    @Volatile var pressureHpa: Double? = null
        private set

    @Synchronized fun acquire() {
        if (users++ == 0 && sensor != null) sm?.registerListener(this, sensor, 1_000_000)
    }

    @Synchronized fun release() {
        if (users == 0) return
        if (--users == 0) {
            sm?.unregisterListener(this)
            pressureHpa = null
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        val p = event.values[0].toDouble()
        pressureHpa = pressureHpa?.let { it + 0.3 * (p - it) } ?: p
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit

    /**
     * Calibrates against a GPS fix (once per fix, however many listeners report it) and returns the
     * barometric altitude, or null without a pressure reading or calibration.
     */
    @Synchronized fun altitudeFor(loc: Location, gpsAltitudeM: Double?): Double? {
        val p = pressureHpa ?: return null
        if (loc.time != lastFixTimeMs) {
            lastFixTimeMs = loc.time
            val accuracy = when {
                loc.hasVerticalAccuracy() -> loc.verticalAccuracyMeters.toDouble()
                loc.hasAccuracy() -> loc.accuracy * 1.5
                else -> Double.MAX_VALUE
            }
            if (gpsAltitudeM != null) altimeter.onGps(p, gpsAltitudeM, accuracy)
            altimeter.seaLevelHpa?.let { trend.add(System.currentTimeMillis(), it) }
        }
        return altimeter.altitudeM(p)
    }

    /** Change in sea-level pressure over the last 3 hours (negative = falling), once enough is recorded. */
    @Synchronized fun change3hHpa(): Double? = trend.change()

    /** For example "Pressure 1003 hPa · steady"; null without a reading. */
    fun summary(): String? {
        val p = pressureHpa ?: return null
        val c = change3hHpa()
        val t = synchronized(this) { trend.tendency() }
        val trendText = when (t) {
            PressureTrend.Tendency.UNKNOWN -> "trend after about 2½ hours of readings"
            PressureTrend.Tendency.STEADY -> "steady"
            PressureTrend.Tendency.RISING -> "rising ${hpa(c)} in 3 h"
            PressureTrend.Tendency.FALLING -> "falling ${hpa(c)} in 3 h"
            PressureTrend.Tendency.FALLING_FAST -> "falling fast, ${hpa(c)} in 3 h: the weather may be turning"
        }
        return "Pressure ${p.roundToInt()} hPa · $trendText"
    }

    private fun hpa(change: Double?) = String.format(Locale.ROOT, "%.1f hPa", kotlin.math.abs(change ?: 0.0))
}
