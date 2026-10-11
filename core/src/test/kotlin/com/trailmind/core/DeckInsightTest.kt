package com.trailmind.core

import com.trailmind.core.frontier.DeckInsight
import com.trailmind.core.frontier.DeckInsight.Tone
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DeckInsightTest {
    private val min = 60_000L
    private val now = 1_000_000L * min
    private fun clock(ms: Long) = "T" + (ms - now) / min
    private fun dur(ms: Long) = (ms / min).toString() + " min"

    private fun input(
        finish: Long? = now + 120 * min, sunset: Long? = now + 600 * min, turnBack: Long? = now + 30 * min,
        off: Boolean = false, weather: String? = null, battery: Int? = 80, lost: Int = 0, remainingKm: Double? = 5.0,
    ) = DeckInsight.Input(now, finish, sunset, 30, turnBack, off, 75.0, remainingKm, weather, battery, lost)

    @Test
    fun plentyOfDaylightIsReassuring() {
        val r = DeckInsight.compute(input(), ::clock, ::dur)
        assertEquals(Tone.OK, r.tone)
        assertEquals("On pace to finish at T120, 480 min of daylight to spare.", r.headline)
        assertTrue(r.reasons.any { "Sunset" in it })
    }

    @Test
    fun finishingAfterSunsetIsAnAlertWithTurnBackTime() {
        val r = DeckInsight.compute(input(finish = now + 650 * min), ::clock, ::dur)
        assertEquals(Tone.ALERT, r.tone)
        assertEquals("At this pace you finish 50 min after sunset. Turn back by T30.", r.headline)
    }

    @Test
    fun insideTheMarginIsACaution() {
        val r = DeckInsight.compute(input(finish = now + 585 * min), ::clock, ::dur)
        assertEquals(Tone.CAUTION, r.tone)
        assertTrue("inside your 30 min margin" in r.headline, r.headline)
    }

    @Test
    fun offRouteComesFirst() {
        val r = DeckInsight.compute(input(off = true, finish = now + 650 * min), ::clock, ::dur)
        assertEquals(Tone.ALERT, r.tone)
        assertTrue(r.headline.startsWith("You are 75 m off the route"), r.headline)
    }

    @Test
    fun weatherThenBatteryThenGroup() {
        assertEquals("Gusts to 70 km/h on the top.", DeckInsight.compute(input(weather = "Gusts to 70 km/h on the top."), ::clock, ::dur).headline)
        assertTrue("Battery is 15%" in DeckInsight.compute(input(battery = 15), ::clock, ::dur).headline)
        assertEquals("2 of your group are out of Bluetooth range. Wait for them at the next junction.", DeckInsight.compute(input(lost = 2), ::clock, ::dur).headline)
        assertTrue(DeckInsight.compute(input(lost = 1), ::clock, ::dur).headline.startsWith("1 of your group is out"))
    }

    @Test
    fun withoutSunsetOrFinishItStillSaysSomethingTrue() {
        assertEquals("On pace to finish at T120.", DeckInsight.compute(input(sunset = null), ::clock, ::dur).headline)
        assertEquals("Waiting for a GPS fix on the route.", DeckInsight.compute(input(finish = null, sunset = null), ::clock, ::dur).headline)
    }
}
