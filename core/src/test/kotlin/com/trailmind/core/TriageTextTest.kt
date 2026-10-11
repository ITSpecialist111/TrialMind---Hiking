package com.trailmind.core

import com.trailmind.core.frontier.Bleeding
import com.trailmind.core.frontier.InjuryType
import com.trailmind.core.frontier.Mobility
import com.trailmind.core.frontier.TriageCode
import com.trailmind.core.frontier.TriageText
import com.trailmind.core.frontier.SosText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TriageTextTest {
    @Test
    fun sentenceReadsInTheOrderACallHandlerWants() {
        assertEquals("Leg injury, cannot move, bleeding controlled", TriageText.situation(InjuryType.LEG, Mobility.STATIONARY, Bleeding.CONTROLLED))
        assertEquals("No injury, can walk, no bleeding", TriageText.situation(InjuryType.NONE, Mobility.MOBILE, Bleeding.NONE))
    }

    @Test
    fun everyCombinationHasATextAndFitsAnSms() {
        for (i in InjuryType.entries) for (m in Mobility.entries) for (b in Bleeding.entries) {
            val s = TriageText.situation(i, m, b)
            assertTrue(s.isNotBlank())
            assertTrue(SosText.isGsm7(s), s)
            val sms = SosText.contact(s, com.trailmind.core.geo.LatLon(54.52, -3.01), 938, "11:40", 80)
            assertTrue(sms.length <= SosText.MAX_CHARS, sms)
        }
    }

    @Test
    fun urgencyAndHex() {
        assertTrue(TriageText.isUrgent(InjuryType.LEG, Mobility.STATIONARY, Bleeding.UNCONTROLLED))
        assertTrue(TriageText.isUrgent(InjuryType.HEAD, Mobility.LIMITED, Bleeding.NONE))
        assertTrue(TriageText.isUrgent(InjuryType.ARM, Mobility.UNCONSCIOUS, Bleeding.NONE))
        assertFalse(TriageText.isUrgent(InjuryType.ARM, Mobility.LIMITED, Bleeding.CONTROLLED))
        assertEquals("0x0A", TriageText.hex(10))
        val leg = TriageCode.encode(InjuryType.LEG, Mobility.STATIONARY, Bleeding.CONTROLLED)
    }
}
