package com.trailmind.core.stats

import com.trailmind.core.geo.SunTimes
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Sun
import java.time.Instant
import java.time.ZoneId

data class DaylightEstimate(
    val finishMs: Long,
    val remainingMinutes: Double,
    val daylightLeftMs: Long?,
    val afterSafeSunset: Boolean?,
    val walkBackMinutes: Double?,
    val turnBackByMs: Long?,
    val startByMs: Long?,
    val afterCivilDusk: Boolean?,
    val darkNow: Boolean?,
    val nextSunriseMs: Long?,
)

object Daylight {
    fun alertDue(sunsetDue: Boolean, duskDue: Boolean, sunsetAlerted: Boolean, duskAlerted: Boolean): Int = when {
        sunsetDue && !sunsetAlerted -> 1
        duskDue && !duskAlerted -> 2
        else -> 0
    }

    fun watchAlert(darkNow: Boolean): String = if (darkNow) "It's dark now. Plan a safe way down."
        else "Finish after sunset. Plan a safe way down."

    fun estimate(nowMs: Long, remaining: List<TrackPoint>, walked: List<TrackPoint>,
        movingMinutes: Double?, pace: PaceSettings, sun: SunTimes, marginMinutes: Int,
        zone: ZoneId = ZoneId.systemDefault()): DaylightEstimate {
        require(marginMinutes >= 0)
        val walkedPlan = HikeEstimator.estimate(walked, pace).planningMinutes
        val scale = if (walkedPlan >= 15.0 && movingMinutes != null && movingMinutes >= 10.0)
            (movingMinutes / walkedPlan).coerceIn(0.5, 3.0) else 1.0
        val remainingMinutes = HikeEstimator.estimate(remaining, pace).planningMinutes * scale
        val backMinutes = if (walked.size >= 2) HikeEstimator.estimate(walked.reversed(), pace).planningMinutes * scale else null
        val meaningfulBack = backMinutes?.takeIf { it >= 1.0 }
        val cutoff = sun.sunsetMs?.minus(marginMinutes * 60_000L)
        val finish = nowMs + (remainingMinutes * 60_000).toLong()
        val fullPlan = HikeEstimator.estimate(remaining, pace).planningMinutes
        val startBy = cutoff?.minus((fullPlan * 60_000).toLong())?.takeIf { sun.sunriseMs == null || it >= sun.sunriseMs }
        val beforeSunrise = sun.sunriseMs?.let { nowMs < it } == true
        val afterDusk = sun.civilDuskMs?.let { nowMs >= it } == true
        val dark = when {
            sun.polarNight -> true
            sun.polarDay -> false
            sun.sunriseMs == null || sun.civilDuskMs == null -> null
            else -> beforeSunrise || afterDusk
        }
        val tomorrow = if (afterDusk && remaining.isNotEmpty()) {
            val date = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate().plusDays(1)
            Sun.times(date, remaining.first().latLon()).sunriseMs
        } else null
        val sunrise = if (beforeSunrise) sun.sunriseMs else tomorrow
        return DaylightEstimate(finish, remainingMinutes, sun.sunsetMs?.minus(nowMs)?.takeIf { !beforeSunrise && !afterDusk },
            if (dark == null) null else if (dark) true else cutoff?.let { finish > it },
            meaningfulBack, meaningfulBack?.let { cutoff?.minus((it * 60_000).toLong()) },
            startBy, if (dark == null) null else if (dark) true else sun.civilDuskMs?.let { finish > it },
            dark, sunrise)
    }
}