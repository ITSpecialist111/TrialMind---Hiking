package com.trailmind.core

import com.trailmind.core.frontier.SosText
import com.trailmind.core.geo.LatLon
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SosTextTest {
    private val parkend = LatLon(51.7785, -2.5360)

    @Test
    fun contactTextFitsOneSmsWithGridLinkHeightAndBattery() {
        val text = SosText.contact("Possible fall, no response", parkend, 170, "14:32", 62)
        assertTrue(text.length <= SosText.MAX_CHARS, text)
        assertTrue(SosText.isGsm7(text), text)
        assertTrue(text.startsWith("SOS from TrailMind: Possible fall, no response at 14:32."), text)
        assertTrue("Grid SO " in text, text)
        assertTrue("openstreetmap.org/?mlat=51.77850&mlon=-2.53600" in text, text)
        assertTrue(text.endsWith(" 170 m. Battery 62%."), text)
    }

    @Test
    fun longOrForeignTextStillFitsOneGsmSms() {
        val text = SosText.contact("Fell on the scree – ankle hurts, 3°C and windy ".repeat(4), parkend, 850, "2:32\u202FPM", 7)
        assertTrue(text.length <= SosText.MAX_CHARS, text)
        assertTrue(SosText.isGsm7(text), text)
        assertTrue("51.77850,-2.53600" in text || "mlat=51.77850" in text, text)
    }

    @Test
    fun noFixSaysSoAndSkipsUnknownBattery() {
        val text = SosText.contact("I need help", null, null, "09:05", -1)
        assertEquals("SOS from TrailMind: I need help at 09:05. No GPS fix.", text)
    }

    @Test
    fun emergencyTextNamesServiceThenWhatAndWhere() {
        val text = SosText.emergency("Hiker fallen, injured", parkend, "14:32")
        assertTrue(text.startsWith("Police, mountain rescue. Hiker fallen, injured. Grid SO "), text)
        assertTrue("lat 51.77850 lon -2.53600" in text, text)
        assertTrue(SosText.isGsm7(text), text)
    }

    @Test
    fun emergencyServiceNumbersAreRecognisedButContactsAreNot() {
        listOf("999", " 9 9 9 ", "112", "+44 999", "0999", "911", "\uFF19\uFF19\uFF19", "\u0669\u0669\u0669").forEach { assertTrue(SosText.isEmergencyNumber(it), it) }
        listOf("07700 900999", "+44 7700 900112", "5554", "01594 999111", "").forEach { assertFalse(SosText.isEmergencyNumber(it), it) }
    }
}
