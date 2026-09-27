package com.trailmind.core.stats

import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.OsGrid
import java.util.Locale
import kotlin.math.ceil

object TripReadiness {
    fun followUpMs(dueMs: Long): Long = dueMs + 30 * 60_000L

    fun defaultReturnMs(nowMs: Long, planningMinutes: Double): Long {
        val quarter = 15 * 60_000L
        val end = nowMs + (ceil(planningMinutes.coerceAtLeast(0.0) * 1.5).toLong() * 60_000L)
        return ((end + quarter - 1) / quarter) * quarter
    }

    fun summary(ready: Int, total: Int): String = "$ready of $total ready"

    fun coverage(hits: Int, samples: Int): Int = if (samples == 0) 0 else (hits * 100 / samples).coerceIn(0, 100)

    fun sampleRoute(points: List<LatLon>, spacingM: Double = 100.0): List<LatLon> {
        if (points.size < 2) return points
        require(spacingM > 0)
        val lengths = points.zipWithNext { first, second -> Geo.distanceM(first.lat, first.lon, second.lat, second.lon) }
        val count = ceil(lengths.sum() / spacingM).toInt().coerceIn(1, 500)
        val step = lengths.sum() / count
        val result = ArrayList<LatLon>(count + 1)
        var leg = 0
        var passed = 0.0
        for (index in 0..count) {
            val target = index * step
            while (leg < lengths.lastIndex && passed + lengths[leg] < target) { passed += lengths[leg]; leg++ }
            val fraction = if (lengths[leg] == 0.0) 0.0 else ((target - passed) / lengths[leg]).coerceIn(0.0, 1.0)
            result += LatLon(points[leg].lat + (points[leg + 1].lat - points[leg].lat) * fraction,
                points[leg].lon + (points[leg + 1].lon - points[leg].lon) * fraction)
        }
        return result
    }

    fun sms(routeName: String, location: LatLon?, time: String, batteryPercent: Int): String = buildString {
        append("I'm running late on ").append(routeName.ifBlank { "my walk" }).append(". ")
        if (location != null) {
            append("Grid ").append(OsGrid.fromWgs84(location)?.format(8) ?: "unavailable").append(". ")
            append("Map https://www.openstreetmap.org/?mlat=")
            append(String.format(Locale.ROOT, "%.5f", location.lat)).append("&mlon=")
            append(String.format(Locale.ROOT, "%.5f", location.lon)).append(". ")
        } else append("No location fix. ")
        append("Time ").append(time).append(". Battery ")
        if (batteryPercent < 0) append("unavailable.") else append(batteryPercent).append("%.")
    }
}