package com.trailmind.core

import com.trailmind.core.geo.MapHeading
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MapHeadingTest {
    private val compass = MapHeading.Reading(10.0, 10_000)
    private fun course(speed: Double = 1.0, accuracy: Double = 5.0, bearingAccuracy: Double? = 10.0, at: Long = 10_000) =
        MapHeading.Course(MapHeading.Reading(90.0, at), speed, accuracy, bearingAccuracy, 0.1)

    @Test fun walkingUsesCourseEvenWhenCompassClaimsAccuracy() {
        assertEquals(MapHeading.Result(90.0, MapHeading.Source.COURSE), MapHeading.choose(10_000, compass, true, course()))
    }
    @Test fun stoppedOrInaccurateGpsUsesCompass() {
        for (gps in listOf(course(speed = 0.79), course(accuracy = 25.01), course(bearingAccuracy = 25.01), course(speed = 1.19, bearingAccuracy = null))) {
            assertEquals(MapHeading.Source.COMPASS, MapHeading.choose(10_000, compass, true, gps).source)
        }
    }
    @Test fun staleOrDisturbedSensorsNeverLookLive() {
        assertNull(MapHeading.choose(12_001, compass, true, null).degrees)
        assertNull(MapHeading.choose(10_000, compass, false, course(speed = 0.0)).degrees)
        assertNull(MapHeading.choose(15_001, compass, true, course()).degrees)
        assertNull(MapHeading.choose(9_999, compass, true, course()).degrees)
    }
    @Test fun exactThresholdsAndRecovery() {
        assertEquals(MapHeading.Source.COURSE, MapHeading.choose(15_000, null, false, course(speed = 0.8, accuracy = 25.0, bearingAccuracy = 25.0)).source)
        assertEquals(MapHeading.Source.COMPASS, MapHeading.choose(12_000, compass, true, null).source)
        assertEquals(MapHeading.Source.COURSE, MapHeading.choose(10_000, null, false, course(speed = 1.2, bearingAccuracy = null)).source)
    }
    @Test fun nonFiniteDataRejected() {
        assertNull(MapHeading.choose(10_000, MapHeading.Reading(Double.NaN, 10_000), true, course(accuracy = Double.NaN)).degrees)
    }
}
