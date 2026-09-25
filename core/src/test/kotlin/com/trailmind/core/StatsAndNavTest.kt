package com.trailmind.core

import com.trailmind.core.ai.Briefing
import com.trailmind.core.ai.BriefingInput
import com.trailmind.core.format.Units
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.SunTimes
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Waypoint
import com.trailmind.core.map.TilePolicy
import com.trailmind.core.nav.OffRouteDetector
import com.trailmind.core.nav.RouteGuide
import com.trailmind.core.nav.TrackFilter
import com.trailmind.core.stats.HikeEstimator
import com.trailmind.core.stats.PaceSettings
import com.trailmind.core.stats.TrackStats
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StatsAndNavTest {
    /** Straight line heading east, one point every 10 m, climbing [climbPerPoint] metres each. */
    private fun line(n: Int, climbPerPoint: Double = 0.0, start: LatLon = LatLon(54.0, -3.0), stepM: Double = 10.0): List<TrackPoint> =
        (0 until n).map { i ->
            val p = Geo.destination(start, 90.0, i * stepM)
            TrackPoint(p.lat, p.lon, 100.0 + i * climbPerPoint, 1_000_000L + i * 7_000L)
        }

    @Test
    fun summaryDistanceAscentAndMovingTime() {
        val pts = line(101, climbPerPoint = 1.0) // 1 km, +100 m
        val s = TrackStats.summarize(pts)
        assertEquals(1000.0, s.distanceM, 1.0)
        assertEquals(100.0, s.ascentM, 4.1)
        assertEquals(0.0, s.descentM)
        assertEquals(700_000L, s.durationMs)
        assertEquals(700_000L, s.movingMs)
        assertEquals(100.0, s.minEleM)
    }

    @Test
    fun ascentIgnoresNoise() {
        val noisy = listOf(100.0, 101.5, 99.0, 102.0, 100.5, 101.0, 99.5)
        val (up, down) = TrackStats.ascentDescent(noisy)
        assertEquals(0.0, up)
        assertEquals(0.0, down)
        val (up2, down2) = TrackStats.ascentDescent(listOf(100.0, 110.0, 105.0, 120.0))
        assertEquals(25.0, up2)
        assertEquals(5.0, down2)
    }

    @Test
    fun naismithOnFlatAndClimb() {
        val flat = HikeEstimator.estimate(line(1001, 0.0)) // 10 km flat
        assertEquals(120.0, flat.naismithMinutes, 1.0)
        assertTrue(flat.toblerMinutes in 115.0..125.0, "tobler=${flat.toblerMinutes}")
        val climb = HikeEstimator.estimate(line(1001, 0.06)) // 10 km, +60 m
        assertEquals(126.0, climb.naismithMinutes, 1.5)
        val slow = HikeEstimator.estimate(line(1001, 0.0), PaceSettings(flatSpeedKmh = 4.0, conditionsFactor = 1.25))
        assertEquals(187.5, slow.naismithMinutes, 1.5)
    }

    @Test
    fun routeGuideTracksProgressAndWaypoints() {
        val route = line(101, 1.0) // 1 km east, climbing 100 m
        val wpEnd = Waypoint(route.last().lat, route.last().lon, "Top")
        val guide = RouteGuide(route, listOf(wpEnd))
        assertEquals(1000.0, guide.totalM, 1.0)
        val here = Geo.destination(Geo.destination(route.first().latLon(), 90.0, 400.0), 0.0, 20.0)
        val fix = guide.locate(here)
        assertEquals(400.0, fix.alongM, 2.0)
        assertEquals(600.0, fix.remainingM, 2.0)
        assertEquals(20.0, fix.offRouteM, 1.0)
        assertEquals(60.0, fix.remainingAscentM, 1.5)
        assertEquals(0.4, fix.progress, 0.01)
        assertEquals(90.0, fix.routeBearingDeg, 1.0)
        val next = assertNotNull(fix.nextWaypoint)
        assertEquals("Top", next.waypoint.name)
        assertEquals(600.0, next.alongRouteM, 2.0)
        assertFalse(fix.atEnd)
        assertTrue(guide.locate(route.last().latLon()).atEnd)
        assertEquals(0.0, Geo.distanceM(guide.pointAt(-5.0), route.first().latLon()), 0.01)
        assertEquals(0.0, Geo.distanceM(guide.pointAt(455.0), Geo.destination(route.first().latLon(), 90.0, 455.0)), 0.5)
        assertEquals(0.0, Geo.distanceM(guide.pointAt(5_000.0), route.last().latLon()), 0.01)
    }

    @Test
    fun routeGuidePrefersContinuityOnOutAndBack() {
        val out = line(51) // 500 m east
        val back = out.reversed().drop(1).map { it.copy(lat = it.lat + 0.00005) } // ~5 m north, heading west
        val guide = RouteGuide(out + back)
        guide.locate(out[5].latLon())
        val first = guide.locate(out[20].latLon())
        assertTrue(first.alongM < 500, "should stay on outbound leg, was ${first.alongM}")
        guide.locate(out[50].latLon())
        guide.reset()
        guide.locate(out[49].latLon())
        val onReturn = guide.locate(out[45].latLon())
        assertTrue(onReturn.offRouteM < 1.0, "snapped ${onReturn.offRouteM} m away")
        assertTrue(onReturn.alongM < 500, "should snap to the outbound leg nearest the walker")
    }

    @Test
    fun offRouteHysteresis() {
        val d = OffRouteDetector(thresholdM = 50.0, confirmFixes = 3)
        assertEquals(OffRouteDetector.Event.NONE, d.update(80.0))
        assertEquals(OffRouteDetector.Event.NONE, d.update(80.0))
        assertEquals(OffRouteDetector.Event.LEFT_ROUTE, d.update(80.0))
        assertTrue(d.isOffRoute)
        assertEquals(OffRouteDetector.Event.NONE, d.update(45.0))
        assertEquals(OffRouteDetector.Event.REJOINED_ROUTE, d.update(20.0))
        // Poor accuracy fixes don't trigger alarms.
        repeat(5) { assertEquals(OffRouteDetector.Event.NONE, d.update(70.0, accuracyM = 30.0)) }
    }

    @Test
    fun trackFilterRejectsJitterAndJumps() {
        val f = TrackFilter(maxAccuracyM = 30f, minDistanceM = 5.0)
        val base = LatLon(54.0, -3.0)
        assertTrue(f.accept(TrackPoint(base.lat, base.lon, timeMs = 0, accuracyM = 5f)))
        val jitter = Geo.destination(base, 10.0, 2.0)
        assertFalse(f.accept(TrackPoint(jitter.lat, jitter.lon, timeMs = 5_000, accuracyM = 5f)))
        assertFalse(f.accept(TrackPoint(base.lat, base.lon, timeMs = 6_000, accuracyM = 80f)))
        val jump = Geo.destination(base, 10.0, 2_000.0)
        assertFalse(f.accept(TrackPoint(jump.lat, jump.lon, timeMs = 10_000, accuracyM = 5f)))
        val step = Geo.destination(base, 10.0, 12.0)
        assertTrue(f.accept(TrackPoint(step.lat, step.lon, timeMs = 12_000, accuracyM = 5f)))
        // Keep-alive point after a minute stationary so pauses show up in the track.
        assertTrue(f.accept(TrackPoint(step.lat, step.lon, timeMs = 80_000, accuracyM = 5f)))
    }

    @Test
    fun tilePolicy() {
        assertTrue(TilePolicy.isBulkDownloadForbidden("https://tile.openstreetmap.org/{z}/{x}/{y}.png"))
        assertTrue(TilePolicy.isBulkDownloadForbidden("https://a.tile.opentopomap.org/{z}/{x}/{y}.png"))
        assertTrue(TilePolicy.isBulkDownloadForbidden("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"))
        assertFalse(TilePolicy.isBulkDownloadForbidden("https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/{z}/{x}/{y}.png?key={key}"))
        assertEquals(
            "https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/12/2010/1300.png?key=K",
            TilePolicy.fillTemplate("https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/{z}/{x}/{y}.png?key={key}", TileKey(12, 2010, 1300), "K"),
        )
        assertEquals("https://h/3/1/2.png", TilePolicy.fillTemplate("https://h/{z}/{x}/{-y}.png", TileKey(3, 1, 5)))
        assertNull(TilePolicy.validateTemplate("https://example.com/{z}/{x}/{y}.png"))
        assertNotNull(TilePolicy.validateTemplate("ftp://example.com/{z}/{x}/{y}.png"))
        assertNotNull(TilePolicy.validateTemplate("https://example.com/tiles.png"))
    }

    @Test
    fun unitsFormatting() {
        assertEquals("850 m", Units.distance(850.0))
        assertEquals("5.25 km", Units.distance(5250.0))
        assertEquals("12.3 km", Units.distance(12_345.0))
        assertEquals("3.11 mi", Units.distance(5000.0, imperial = true))
        assertEquals("2h 05m", Units.minutes(125.0))
        assertEquals("45m", Units.minutes(45.2))
        assertEquals("007°", Units.bearing(367.0))
    }

    @Test
    fun briefingWarnsAboutDarkness() {
        val est = HikeEstimator.estimate(line(1001, 0.5))
        val start = 1_750_000_000_000L
        val input = BriefingInput(
            routeName = "Test", estimate = est, start = LatLon(54.5, -3.0), end = LatLon(54.6, -3.0),
            maxEleM = 700.0, waypointNames = listOf("Tarn"),
            sun = SunTimes(start - 3_600_000, start + 60 * 60_000, polarDay = false, polarNight = false),
            plannedStartMs = start, zone = ZoneOffset.UTC,
        )
        val lines = Briefing.ruleBased(input)
        assertTrue(lines.any { it.contains("AFTER sunset") }, lines.joinToString("\n"))
        assertTrue(lines.any { it.contains("999") })
        val prompt = Briefing.gemmaPrompt(input)
        assertTrue(prompt.contains("Route: Test"))
        assertTrue(prompt.contains("Tarn"))
    }
}
