package com.trailmind.core

import com.trailmind.core.map.RenewalPrompt
import com.trailmind.core.map.TilePolicy
import java.time.Instant
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RenewalPromptTest {
    private val london = ZoneId.of("Europe/London")
    private fun ms(text: String) = LocalDateTime.parse(text).atZone(london).toInstant().toEpochMilli()

    @Test
    fun asksTwoHoursAheadInTheDaytime() {
        assertEquals(ms("2026-09-28T16:00"), RenewalPrompt.at(ms("2026-09-28T18:00"), london))
        assertEquals(ms("2026-09-28T07:00"), RenewalPrompt.at(ms("2026-09-28T09:00"), london))
        assertEquals(ms("2026-09-28T20:59"), RenewalPrompt.at(ms("2026-09-28T22:59"), london))
    }

    @Test
    fun movesOvernightQuestionsToTheEveningBefore() {
        assertEquals(ms("2026-09-27T20:00"), RenewalPrompt.at(ms("2026-09-28T08:30"), london))
        assertEquals(ms("2026-09-28T20:00"), RenewalPrompt.at(ms("2026-09-28T23:30"), london))
        assertEquals(ms("2026-09-27T20:00"), RenewalPrompt.at(ms("2026-09-28T01:00"), london))
        assertEquals(ms("2026-09-27T20:00"), RenewalPrompt.at(ms("2026-09-28T02:00"), london))
    }

    @Test
    fun neverAsksOvernightOrLateAcrossAClockChange() {
        var expiry = ms("2026-10-23T00:00")
        val end = ms("2026-10-27T00:00")
        while (expiry < end) {
            val at = RenewalPrompt.at(expiry, london)
            val time = Instant.ofEpochMilli(at).atZone(london).toLocalTime()
            assertTrue(at <= expiry - RenewalPrompt.LEAD_MS, "prompt after lead for ${Instant.ofEpochMilli(expiry)}")
            assertTrue(expiry - at <= 14 * 3_600_000L, "prompt too early for ${Instant.ofEpochMilli(expiry)}")
            assertTrue(time >= LocalTime.of(7, 0) && time < LocalTime.of(21, 0), "overnight prompt $time")
            expiry += 7 * 60_000L
        }
    }

    @Test
    fun downloadsReusePremiumOnlyWithTwentyHoursLeft() {
        val now = 10_000_000_000L
        val hour = 3_600_000L
        assertTrue(TilePolicy.premiumReusable(now, now))
        assertTrue(TilePolicy.premiumReusable(now - 4 * hour, now))
        assertFalse(TilePolicy.premiumReusable(now - 4 * hour - 1, now))
        assertFalse(TilePolicy.premiumReusable(now - 23 * hour, now))
        assertFalse(TilePolicy.premiumReusable(now + 1, now))
        assertFalse(TilePolicy.premiumReusable(0L, now))
    }
}
