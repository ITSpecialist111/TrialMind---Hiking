package com.trailmind.core.map

import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

/** When to ask whether to renew 24-hour Premium detail: 2 hours before it expires, moved to 20:00 the evening before rather than overnight. */
object RenewalPrompt {
    const val LEAD_MS = 2L * 3_600_000
    private val QUIET_START: LocalTime = LocalTime.of(21, 0)
    private val QUIET_END: LocalTime = LocalTime.of(7, 0)
    private val EVENING: LocalTime = LocalTime.of(20, 0)

    fun at(expiresAtMs: Long, zone: ZoneId): Long {
        val candidate = Instant.ofEpochMilli(expiresAtMs - LEAD_MS).atZone(zone)
        val time = candidate.toLocalTime()
        if (time >= QUIET_END && time < QUIET_START) return candidate.toInstant().toEpochMilli()
        val day = if (time >= QUIET_START) candidate.toLocalDate() else candidate.toLocalDate().minusDays(1)
        return day.atTime(EVENING).atZone(zone).toInstant().toEpochMilli()
    }
}
