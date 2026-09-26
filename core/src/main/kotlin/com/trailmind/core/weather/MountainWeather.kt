package com.trailmind.core.weather

import com.trailmind.core.format.Units
import com.trailmind.core.geo.Geo
import kotlin.math.abs
import kotlin.math.roundToInt

/** One hour of a point forecast. Values the source doesn't give are NaN. */
data class ForecastHour(
    val timeMs: Long,
    val temperatureC: Double,
    val feelsLikeC: Double,
    val windKmh: Double,
    val gustKmh: Double,
    val windFromDeg: Double,
    val rainChancePct: Double,
    val rainMm: Double,
    val lowCloudPct: Double,
    val visibilityM: Double,
    val freezingLevelM: Double,
)

/** An hourly forecast for one place, kept as fetched so it can be read offline. */
class PointForecast(val fetchedMs: Long, val hours: List<ForecastHour>) {
    /** The hour nearest [timeMs], or null when the forecast doesn't reach it. */
    fun at(timeMs: Long): ForecastHour? =
        hours.minByOrNull { abs(it.timeMs - timeMs) }?.takeIf { abs(it.timeMs - timeMs) <= MAX_GAP_MS }

    private companion object {
        const val MAX_GAP_MS = 90 * 60_000L
    }
}

/** Mountain weather in the terms a hill walker plans with. */
object MountainWeather {
    // Gusts of 40 mph make walking hard; 50 mph is dangerous on exposed ground.
    private const val GUST_HARD_KMH = 64.0
    private const val GUST_SEVERE_KMH = 80.0

    fun summary(h: ForecastHour, imperial: Boolean): String = buildList {
        if (!h.temperatureC.isNaN()) add(temp(h.temperatureC) + if (h.feelsLikeC.isNaN()) "" else ", feels like ${temp(h.feelsLikeC)}")
        if (!h.windKmh.isNaN()) {
            val from = if (h.windFromDeg.isNaN()) "" else Geo.cardinal(h.windFromDeg) + " "
            add("wind $from${speed(h.windKmh, imperial)}" + if (h.gustKmh.isNaN()) "" else " gusting ${speed(h.gustKmh, imperial)}")
        }
        if (!h.rainChancePct.isNaN()) add("${h.rainChancePct.roundToInt()}% chance of rain")
        if (!h.lowCloudPct.isNaN()) add("low cloud ${h.lowCloudPct.roundToInt()}%" + if (h.lowCloudPct >= 80) " (the tops may be in cloud)" else "")
        if (!h.freezingLevelM.isNaN()) add("freezing level ${Units.elevation(h.freezingLevelM, imperial)}")
    }.joinToString(", ")

    /** Hazards at a point [eleM] high. NaN values never trigger one. */
    fun warnings(h: ForecastHour, eleM: Double, imperial: Boolean): List<String> = buildList {
        when {
            h.gustKmh >= GUST_SEVERE_KMH -> add("Gusts of ${speed(h.gustKmh, imperial)}: dangerous on exposed ground. Consider a lower route.")
            h.gustKmh >= GUST_HARD_KMH -> add("Gusts of ${speed(h.gustKmh, imperial)}: walking will be hard work, and exposed ridges hazardous.")
        }
        if (h.feelsLikeC <= 0) add("Feels like ${temp(h.feelsLikeC)} up there: take a hat, gloves and a warm layer.")
        if (h.freezingLevelM < eleM) add("Freezing level ${Units.elevation(h.freezingLevelM, imperial)}, below the high point: expect ice or snow on the tops.")
        if (h.visibilityM < 1000) add("Visibility under ${Units.distance(1000.0, imperial)}: navigate by map and compass.")
        if (h.rainMm >= 4) add("Heavy rain (${h.rainMm.roundToInt()} mm in the hour): streams may be hard to cross.")
    }

    private fun temp(c: Double) = "${c.roundToInt()}°C"

    private fun speed(kmh: Double, imperial: Boolean) =
        if (imperial) "${(kmh / 1.609344).roundToInt()} mph" else "${kmh.roundToInt()} km/h"
}
