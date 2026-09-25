package com.trailmind.core.format

import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

object Units {
    fun distance(m: Double, imperial: Boolean = false): String {
        if (imperial) {
            val miles = m / 1609.344
            return if (miles < 0.1) "${(m * 3.28084).roundToInt()} ft" else String.format(Locale.ROOT, "%.2f mi", miles)
        }
        return when {
            m < 1000 -> "${m.roundToInt()} m"
            m < 10_000 -> String.format(Locale.ROOT, "%.2f km", m / 1000)
            else -> String.format(Locale.ROOT, "%.1f km", m / 1000)
        }
    }

    fun elevation(m: Double, imperial: Boolean = false): String =
        if (imperial) "${(m * 3.28084).roundToInt()} ft" else "${m.roundToInt()} m"

    fun duration(ms: Long): String = minutes(ms / 60_000.0)

    fun minutes(min: Double): String {
        val total = min.roundToLong().coerceAtLeast(0)
        val h = total / 60
        val m = total % 60
        return if (h > 0) "${h}h ${m.toString().padStart(2, '0')}m" else "${m}m"
    }

    fun speedKmh(mps: Double, imperial: Boolean = false): String =
        if (imperial) String.format(Locale.ROOT, "%.1f mph", mps * 2.236936)
        else String.format(Locale.ROOT, "%.1f km/h", mps * 3.6)

    fun latLon(lat: Double, lon: Double): String {
        val ns = if (lat >= 0) "N" else "S"
        val ew = if (lon >= 0) "E" else "W"
        return String.format(Locale.ROOT, "%.5f°%s %.5f°%s", abs(lat), ns, abs(lon), ew)
    }

    fun bearing(deg: Double): String = "${deg.roundToInt().mod(360).toString().padStart(3, '0')}°"
}
