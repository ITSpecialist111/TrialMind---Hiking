package com.trailmind.core

import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.nav.TracBack
import com.trailmind.core.weather.BaroAltimeter
import com.trailmind.core.weather.Barometry
import com.trailmind.core.weather.PressureTrend
import kotlin.math.abs
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BarometryTest {
    @Test
    fun standardAtmosphereRoundTrips() {
        assertEquals(0.0, Barometry.altitudeM(Barometry.STANDARD_SEA_LEVEL_HPA), 1e-6)
        assertEquals(898.7, Barometry.pressureHpa(1000.0), 0.1)
        assertEquals(950.0, Barometry.altitudeM(Barometry.pressureHpa(950.0, 1001.3), 1001.3), 1e-6)
        assertEquals(1001.3, Barometry.seaLevelHpa(Barometry.pressureHpa(950.0, 1001.3), 950.0), 1e-9)
    }

    @Test
    fun altimeterFollowsTheClimbWithoutGpsNoiseOrWeatherDrift() {
        val alt = BaroAltimeter()
        var gpsAscent = 0.0
        var baroAscent = 0.0
        var gpsRef: Double? = null
        var baroRef: Double? = null
        var worst = 0.0
        // 800 m climb over an hour of 2 s fixes, while the weather drops sea-level pressure by 3 hPa.
        for (i in 0..1800) {
            val truth = 150.0 + 800.0 * i / 1800
            val qnh = 1015.0 - 3.0 * i / 1800
            val gps = truth + 15.0 * sin(i * 1.7) // deterministic ±15 m GPS noise
            val p = Barometry.pressureHpa(truth, qnh)
            alt.onGps(p, gps, 8.0)
            val baro = alt.altitudeM(p)!!
            if (i > 300) worst = maxOf(worst, abs(baro - truth))
            gpsRef = hysteresis(gps, gpsRef) { gpsAscent += it }
            baroRef = hysteresis(baro, baroRef) { baroAscent += it }
        }
        assertTrue(worst < 5.0, "barometric altitude within 5 m of truth (worst ${"%.1f".format(worst)} m)")
        assertEquals(800.0, baroAscent, 20.0)
        assertTrue(gpsAscent > 1200.0, "GPS noise inflates ascent (${gpsAscent.toInt()} m)")
    }

    private fun hysteresis(e: Double, ref: Double?, up: (Double) -> Unit): Double {
        if (ref == null) return e
        if (e - ref >= 4.0) { up(e - ref); return e }
        if (ref - e >= 4.0) return e
        return ref
    }

    @Test
    fun poorFixesDoNotCalibrate() {
        val alt = BaroAltimeter()
        alt.onGps(1000.0, 100.0, 60.0)
        assertNull(alt.altitudeM(1000.0))
    }

    @Test
    fun trendNeedsHistoryThenReportsAFallingStorm() {
        val trend = PressureTrend()
        val minute = 60_000L
        for (m in 0..120 step 5) trend.add(m * minute, 1012.0 - 1.5 * m / 60.0)
        assertEquals(PressureTrend.Tendency.UNKNOWN, trend.tendency())
        for (m in 125..180 step 5) trend.add(m * minute, 1012.0 - 1.5 * m / 60.0)
        assertEquals(-4.5, trend.change()!!, 0.01)
        assertEquals(PressureTrend.Tendency.FALLING_FAST, trend.tendency())

        val steady = PressureTrend()
        for (m in 0..240 step 5) steady.add(m * minute, 1012.0 + 0.2 * sin(m.toDouble()))
        assertEquals(PressureTrend.Tendency.STEADY, steady.tendency())
    }

    @Test
    fun tracBackReversesAndThinsTheTrack() {
        val recorded = (0 until 10_000).map { TrackPoint(54.0 + it * 1e-5, -3.0, 100.0 + it) }
        val back = TracBack.line(recorded, maxPoints = 1000)!!
        assertTrue(back.size <= 1001)
        assertEquals(recorded.last().lat, back.first().lat)
        assertEquals(recorded.first().lat, back.last().lat)
        assertNull(TracBack.line(recorded.take(1)))
    }
}
