package com.trailmind.core

import com.trailmind.core.frontier.SosText
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.SatelliteSky
import com.trailmind.core.geo.ThreeWordAddress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LocationToolsTest {
    @Test fun threeWordsExpireAndAreNeverSharedAfterMovingSquare() {
        assertTrue(ThreeWordAddress.canShare(1_000, 61_000, 61_000, true))
        assertFalse(ThreeWordAddress.canShare(1_000, 61_001, 61_001, true))
        assertFalse(ThreeWordAddress.canShare(60_000, 60_000, 61_000, false))
        assertFalse(ThreeWordAddress.canShare(62_000, 61_000, 61_000, true))
        assertFalse(ThreeWordAddress.canShare(60_000, 62_000, 61_000, true))
    }
    @Test fun threeWordsAreNotCoordinatesOrUrls() {
        assertEquals("filled.count.soap", ThreeWordAddress.normalize(" ///Filled.Count.Soap "))
        for (bad in listOf("51.50,-2.0", "one.two", "one.two.three.four", "https://w3w.co/filled.count.soap", "one.2.three", "one..three")) {
            assertNull(ThreeWordAddress.normalize(bad))
        }
    }
    @Test fun skyCardinalsAndZenith() {
        val north = SatelliteSky.project(0.0, 0.0)!!
        assertEquals(0.0, north.x, 1e-9); assertEquals(-1.0, north.y, 1e-9)
        val east = SatelliteSky.project(90.0, 0.0)!!
        assertEquals(1.0, east.x, 1e-9); assertEquals(0.0, east.y, 1e-9)
        assertEquals(0.0, SatelliteSky.project(225.0, 90.0)!!.x, 1e-9)
        assertNull(SatelliteSky.project(Double.NaN, 0.0))
        assertNull(SatelliteSky.project(0.0, -1.0))
    }
    @Test fun emergencyWordsNeverReplaceCoordinatesOrBreakSingleSms() {
        val here = LatLon(51.521251, -0.203586)
        val text = SosText.contact("I need help", here, 24, "12:34", 67, "filled.count.soap")
        assertTrue(text.contains("///filled.count.soap"))
        assertTrue(text.contains("51.52125,-0.20359"))
        assertTrue(text.length <= SosText.MAX_CHARS)
        assertTrue(SosText.isGsm7(text))
        val emergency = SosText.emergency("I need help", here, "12:34", "filled.count.soap")
        assertTrue(emergency.contains("Grid ") && emergency.contains("lat ") && emergency.contains("///filled.count.soap"))
        assertTrue(!SosText.contact("Help", null, null, "12:34", 50, "filled.count.soap").contains("///"))
    }
}
