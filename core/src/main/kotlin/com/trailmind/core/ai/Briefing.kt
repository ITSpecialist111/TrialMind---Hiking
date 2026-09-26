package com.trailmind.core.ai

import com.trailmind.core.format.Units
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.Facility
import com.trailmind.core.geo.FacilityCategory
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.SunTimes
import com.trailmind.core.stats.HighPoint
import com.trailmind.core.stats.HikeEstimate
import com.trailmind.core.weather.MountainWeather
import com.trailmind.core.weather.PointForecast
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

data class BriefingInput(
    val routeName: String,
    val estimate: HikeEstimate,
    val start: LatLon,
    val end: LatLon,
    val maxEleM: Double?,
    val waypointNames: List<String>,
    val sun: SunTimes?,
    val plannedStartMs: Long,
    val zone: ZoneId = ZoneId.systemDefault(),
    val imperial: Boolean = false,
    val highPoint: HighPoint? = null,
    /** Forecast for [highPoint], fetched earlier and kept offline. */
    val forecast: PointForecast? = null,
    val facilities: List<Facility> = emptyList(),
    val facilitiesPartial: Boolean = false,
)

/**
 * Builds (1) a deterministic, rule-based trip briefing that works fully offline and (2) a
 * self-contained prompt the user can paste into an on-device LLM (e.g. Gemma in Google AI Edge
 * Gallery). Nothing here calls a model.
 */
object Briefing {
    private val clock = DateTimeFormatter.ofPattern("HH:mm")
    private val dayClock = DateTimeFormatter.ofPattern("EEE HH:mm")
    /** Moving time plus breaks. */
    private const val WITH_BREAKS = 1.2

    fun ruleBased(input: BriefingInput): List<String> {
        val e = input.estimate
        val lines = ArrayList<String>()
        lines += "${Units.distance(e.distanceM, input.imperial)} with ${Units.elevation(e.ascentM, input.imperial)} of ascent " +
            "and ${Units.elevation(e.descentM, input.imperial)} of descent."
        lines += "Estimated moving time ${Units.minutes(e.naismithMinutes)} (Naismith/Langmuir) – " +
            "${Units.minutes(e.toblerMinutes)} (Tobler). Add breaks: plan for ${Units.minutes(e.planningMinutes * WITH_BREAKS)}."
        val finish = input.plannedStartMs + (e.planningMinutes * WITH_BREAKS * 60_000).toLong()
        val sunset = input.sun?.sunsetMs
        if (sunset != null) {
            val margin = (sunset - finish) / 60_000
            lines += when {
                margin < 0 -> "⚠ Likely finish ${fmt(finish, input.zone)} is AFTER sunset (${fmt(sunset, input.zone)}). Start earlier, shorten, or carry a head torch."
                margin < 60 -> "⚠ Only ${margin} min of daylight margin (sunset ${fmt(sunset, input.zone)}). Carry a head torch."
                else -> "Sunset ${fmt(sunset, input.zone)}; expected finish ~${fmt(finish, input.zone)}."
            }
        } else if (input.sun?.polarNight == true) {
            lines += "⚠ No sunrise at this location today."
        }
        val hp = input.highPoint
        val forecast = input.forecast
        if (hp != null && forecast != null) {
            val eta = input.plannedStartMs + (hp.minutesFromStart * WITH_BREAKS * 60_000).toLong()
            val where = "the high point (${Units.elevation(hp.eleM, input.imperial)})"
            val hour = forecast.at(eta)
            if (hour == null) {
                lines += "The saved forecast doesn't reach ${fmt(eta, input.zone, dayClock)}, when you'd be at $where: update it nearer the time."
            } else {
                lines += "Forecast for $where at about ${fmt(eta, input.zone)}: ${MountainWeather.summary(hour, input.imperial)} " +
                    "(Open-Meteo, fetched ${fmt(forecast.fetchedMs, input.zone, dayClock)})."
                MountainWeather.warnings(hour, hp.eleM, input.imperial).forEach { lines += "⚠ $it" }
            }
        } else input.maxEleM?.let {
            if (it >= 600) lines += "High point ${Units.elevation(it, input.imperial)}: expect it to be colder and windier than the valley (≈1°C per 150 m) and check the mountain forecast."
        }
        if (e.ascentM / (e.distanceM / 1000.0).coerceAtLeast(0.1) > 80) {
            lines += "Steep overall (${(e.ascentM / (e.distanceM / 1000.0).coerceAtLeast(0.1)).toInt()} m climb per km): allow extra time and take care on descents."
        }
        val grid = OsGrid.fromWgs84(input.start)?.format(6)
        lines += "Start ${grid ?: Units.latLon(input.start.lat, input.start.lon)}" +
            if (input.start == input.end) " (circular)." else "; finish ${OsGrid.fromWgs84(input.end)?.format(6) ?: Units.latLon(input.end.lat, input.end.lon)}."
        if (input.waypointNames.isNotEmpty()) lines += "Waypoints: ${input.waypointNames.take(12).joinToString(", ")}."
        if (input.facilities.isNotEmpty()) {
            val priority = listOf(FacilityCategory.PARKING, FacilityCategory.TOILETS, FacilityCategory.WATER,
                FacilityCategory.CAFE, FacilityCategory.PUB, FacilityCategory.BUS, FacilityCategory.RAIL)
            val stops = input.facilities.distinctBy { it.category }
                .sortedWith(compareBy { priority.indexOf(it.category).let { index -> if (index < 0) priority.size else index } })
                .take(4).sortedBy { it.alongM }.map { item ->
                val where = if (item.alongM < 150) "at the start" else "at ${Units.distance(item.alongM, input.imperial)}"
                val title = if (item.name.isBlank()) item.category.label else "${item.name.take(30)} ${item.category.label.lowercase()}"
                "$title $where"
            }
            lines += "Facilities${if (input.facilitiesPartial) " (limited results)" else ""}: ${stops.joinToString("; ")}."
        }
        lines += "Tell someone your route and return time. In the UK call 999 or 112, ask for Police, then Mountain Rescue."
        return lines
    }

    fun gemmaPrompt(input: BriefingInput): String = buildString {
        appendLine("You are an experienced, safety-focused UK hill-walking leader. Using ONLY the facts below, write a short pre-hike briefing:")
        appendLine("1) a realistic timing plan with breaks, 2) kit checklist for the conditions, 3) key hazards and turn-back points, 4) a 3-line emergency plan.")
        appendLine("If information is missing (e.g. weather), say what I should check rather than inventing it.")
        appendLine()
        appendLine("Route: ${input.routeName}")
        appendLine("Facts:")
        ruleBased(input).forEach { appendLine("- $it") }
        appendLine("- Planned start: ${fmt(input.plannedStartMs, input.zone)} local time")
    }

    private fun fmt(ms: Long, zone: ZoneId, format: DateTimeFormatter = clock): String = format.format(Instant.ofEpochMilli(ms).atZone(zone))
}
