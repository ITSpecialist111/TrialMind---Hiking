package com.trailmind.app.ui

import android.content.Context
import android.text.format.DateFormat
import com.trailmind.core.geo.Sun
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.stats.Daylight
import com.trailmind.core.stats.PaceSettings
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Date

internal fun clockTime(context: Context, ms: Long): String = DateFormat.getTimeFormat(context).format(Date(ms))

internal fun finishTime(context: Context, ms: Long): String {
    val zone = ZoneId.systemDefault()
    val date = Instant.ofEpochMilli(ms).atZone(zone).toLocalDate()
    val prefix = when (date) {
        LocalDate.now(zone) -> ""
        LocalDate.now(zone).plusDays(1) -> "tomorrow "
        else -> DateFormat.getDateFormat(context).format(Date(ms)) + " "
    }
    return prefix + clockTime(context, ms)
}

/** "at 18:00", "tomorrow at 08:59" or "on 28/09/2026 at 10:01". */
internal fun atTimeText(context: Context, ms: Long): String {
    val zone = ZoneId.systemDefault()
    val day = when (Instant.ofEpochMilli(ms).atZone(zone).toLocalDate()) {
        LocalDate.now(zone) -> ""
        LocalDate.now(zone).plusDays(1) -> "tomorrow "
        else -> "on " + DateFormat.getDateFormat(context).format(Date(ms)) + " "
    }
    return day + "at " + clockTime(context, ms)
}

internal fun startByText(context: Context, points: List<TrackPoint>, pace: PaceSettings,
    marginMinutes: Int, forMs: Long): String {
    if (points.size < 2) return "No route timing available."
    val date = Instant.ofEpochMilli(forMs).atZone(ZoneId.systemDefault()).toLocalDate()
    val sun = Sun.times(date, points.first().latLon())
    val estimate = Daylight.estimate(forMs, points, emptyList(), null, pace, sun, marginMinutes)
    if (estimate.darkNow == true) return "It's dark now. " +
        (estimate.nextSunriseMs?.let { "Sunrise ${finishTime(context, it)}." } ?: "No sunrise time available.")
    val sunset = sun.sunsetMs ?: return if (sun.polarDay) "No sunset today at this location." else "Daylight times unavailable here."
    val startBy = estimate.startByMs ?: return "No start time today: route is too long to finish before sunset."
    return "Start by ${clockTime(context, startBy)} to finish before sunset (${clockTime(context, sunset)}) with $marginMinutes min to spare" +
        if (startBy < forMs) " (start-by time has passed)." else "."
}