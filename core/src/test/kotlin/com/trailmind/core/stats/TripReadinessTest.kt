package com.trailmind.core.stats

import com.trailmind.core.geo.LatLon
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import java.time.Duration
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime

class TripReadinessTest {
    @Test fun returnTimeRoundsUp() {
        assertEquals(11 * 3_600_000L, TripReadiness.defaultReturnMs(10 * 3_600_000L, 40.0))
        assertEquals(10 * 3_600_000L + 15 * 60_000L, TripReadiness.defaultReturnMs(10 * 3_600_000L + 1, 0.0))
    }

    @Test fun followUpStaysThirtyRealMinutesAcrossUkClockChanges() {
        val london = ZoneId.of("Europe/London")
        val starts = listOf(
            ZonedDateTime.of(LocalDateTime.of(2026, 3, 29, 0, 45), london),
            ZonedDateTime.of(LocalDateTime.of(2026, 10, 25, 1, 45), london).withEarlierOffsetAtOverlap(),
        )
        val expected = listOf("02:15", "01:15")
        starts.forEachIndexed { index, start ->
            val due = start.toInstant().toEpochMilli()
            val next = TripReadiness.followUpMs(due)
            assertEquals(Duration.ofMinutes(30), Duration.ofMillis(next - due))
            assertEquals(expected[index], java.time.Instant.ofEpochMilli(next).atZone(london).toLocalTime().toString())
        }
    }

    @Test fun summaryAndCoverage() {
        assertEquals("5 of 7 ready", TripReadiness.summary(5, 7))
        assertEquals(0, TripReadiness.coverage(0, 0))
        assertEquals(75, TripReadiness.coverage(3, 4))
        val samples = TripReadiness.sampleRoute(listOf(LatLon(51.8, -2.5), LatLon(51.8, -2.49)), 100.0)
        assertTrue(samples.size > 2)
        assertEquals(-2.5, samples.first().lon)
        assertEquals(-2.49, samples.last().lon, 0.000001)
        assertTrue(TripReadiness.sampleRoute(listOf(LatLon(51.8, -2.5), LatLon(51.8, -2.5))).size >= 2)
    }

    @Test fun messageIncludesEvidenceAndHandlesNoFix() {
        val text = TripReadiness.sms("New Fancy", LatLon(51.8, -2.5), "17:30", 42)
        assertTrue(text.contains("New Fancy"))
        assertTrue(text.contains("Grid "))
        assertTrue(text.contains("mlat=51.80000&mlon=-2.50000"))
        assertTrue(text.contains("17:30"))
        assertTrue(text.contains("42%"))
        assertTrue(TripReadiness.sms("", null, "18:00", 5).contains("No location fix"))
        assertTrue(TripReadiness.sms("", null, "18:00", -1).contains("Battery unavailable"))
    }
}