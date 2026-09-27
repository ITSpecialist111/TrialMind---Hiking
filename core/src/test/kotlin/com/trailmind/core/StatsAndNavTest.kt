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
import com.trailmind.core.nav.DistanceMarks
import com.trailmind.core.nav.OffRouteDetector
import com.trailmind.core.nav.RouteGuide
import com.trailmind.core.nav.TrackFilter
import com.trailmind.core.stats.HighPoint
import com.trailmind.core.stats.Daylight
import com.trailmind.core.stats.HikeEstimator
import com.trailmind.core.stats.PaceSettings
import com.trailmind.core.stats.TrackStats
import com.trailmind.core.weather.ForecastHour
import com.trailmind.core.weather.MountainWeather
import com.trailmind.core.weather.PointForecast
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StatsAndNavTest {
    @Test
    fun premiumExpiryIncludesBoundaryClockRollbackAndIdleBatch() {
        val stored = 1_000_000L
        val expiry = stored + TilePolicy.PREMIUM_CACHE_MS
        assertFalse(TilePolicy.premiumPurgeDue(stored, expiry - 1))
        assertTrue(TilePolicy.premiumPurgeDue(stored, expiry))
        assertTrue(TilePolicy.premiumPurgeDue(stored, expiry + 1))
        assertTrue(TilePolicy.premiumPurgeDue(stored, stored - 1))
        assertTrue(TilePolicy.premiumPurgeDue(stored, expiry - 15 * 60_000, 15 * 60_000))
        assertFalse(TilePolicy.premiumPurgeDue(stored, expiry - 15 * 60_000 - 1, 15 * 60_000))
        assertFalse(TilePolicy.premiumPurgeDue(stored, stored, 15 * 60_000))
    }

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
    fun daylightFinishTurnBackAndPace() {
        val route = line(1001).map { it.copy(ele = null) }
        val now = 1_000_000_000L
        val pace = PaceSettings(5.0)
        val sun = SunTimes(now - 6 * 3_600_000, now + 3 * 3_600_000, false, false, now + 4 * 3_600_000)
        val walked = route.take(501)
        val remaining = route.drop(500)
        val normal = Daylight.estimate(now, remaining, walked, null, pace, sun, 30)
        assertEquals(60.0, normal.remainingMinutes, 1.0)
        assertEquals(60.0, normal.walkBackMinutes!!, 1.0)
        assertTrue(kotlin.math.abs(normal.turnBackByMs!! - (now + 90 * 60_000)) < 60_000)
        assertTrue(kotlin.math.abs(normal.startByMs!! - (now + 90 * 60_000)) < 60_000)
        assertFalse(normal.afterSafeSunset!!)
        val slow = Daylight.estimate(now, remaining, walked, 120.0, pace, sun, 30)
        assertEquals(120.0, slow.remainingMinutes, 2.0)
        assertTrue(kotlin.math.abs(slow.turnBackByMs!! - (now + 30 * 60_000)) < 60_000)
        assertTrue(kotlin.math.abs(slow.finishMs - (now + 120 * 60_000)) <= 120_000L)
        val late = Daylight.estimate(now, route, emptyList(), null, pace,
            sun.copy(sunsetMs = now + 90 * 60_000, civilDuskMs = now + 110 * 60_000), 30)
        assertNull(late.walkBackMinutes)
        assertNull(late.turnBackByMs)
        assertTrue(late.afterSafeSunset!!)
        assertTrue(late.afterCivilDusk!!)
        assertTrue(late.startByMs!! < now)
        assertNull(Daylight.estimate(now, route, emptyList(), null, pace,
            sun.copy(sunriseMs = now - 30 * 60_000, sunsetMs = now + 90 * 60_000), 30).startByMs)
        val polar = Daylight.estimate(now, route, emptyList(), null, pace, SunTimes(null, null, true, false), 30)
        assertNull(polar.daylightLeftMs)
        assertNull(polar.afterSafeSunset)
        assertNull(polar.turnBackByMs)
        assertNull(polar.startByMs)
    }

    @Test
    fun daylightBeforeSunriseAndAcrossTheAutumnClockChange() {
        val zone = java.time.ZoneId.of("Europe/London")
        val date = java.time.LocalDate.of(2026, 10, 25)
        val route = line(1001).map { it.copy(ele = null) }
        val at = com.trailmind.core.geo.LatLon(51.73, -2.53)
        val sun = com.trailmind.core.geo.Sun.times(date, at)
        val before = sun.sunriseMs!! - 2 * 3_600_000L
        val predawn = Daylight.estimate(before, route, emptyList(), null, PaceSettings(), sun, 30, zone)
        assertEquals(true, predawn.darkNow)
        assertEquals(sun.sunriseMs, predawn.nextSunriseMs)
        assertEquals(true, predawn.afterSafeSunset)
        assertEquals(true, predawn.afterCivilDusk)
        assertNull(predawn.daylightLeftMs)
        val lateNow = date.atTime(23, 30).atZone(zone).toInstant().toEpochMilli()
        val late = Daylight.estimate(lateNow, route, emptyList(), null, PaceSettings(), sun, 30, zone)
        assertEquals(true, late.darkNow)
        assertEquals(com.trailmind.core.geo.Sun.times(date.plusDays(1), route.first().latLon()).sunriseMs, late.nextSunriseMs)
        assertEquals(true, late.afterCivilDusk)
        assertEquals(date.plusDays(1), java.time.Instant.ofEpochMilli(late.finishMs).atZone(zone).toLocalDate())
        val noSunset = Daylight.estimate(before, route, emptyList(), null, PaceSettings(),
            SunTimes(before - 60_000, null, false, false), 30, zone)
        assertNull(noSunset.darkNow)
        assertNull(noSunset.afterSafeSunset)
        val polarNight = Daylight.estimate(before, route, emptyList(), null, PaceSettings(),
            SunTimes(null, null, false, true), 30, zone)
        assertEquals(true, polarNight.darkNow)
        assertEquals(true, polarNight.afterCivilDusk)
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
    fun loopEndDoesNotSnapToItsStart() {
        val start = com.trailmind.core.geo.LatLon(51.73, -2.53)
        val route = listOf(start, Geo.destination(start, 90.0, 1000.0),
            Geo.destination(start, 0.0, 800.0), Geo.destination(start, 270.0, 1000.0), start)
            .map { com.trailmind.core.geo.TrackPoint(it.lat, it.lon) }
        val guide = RouteGuide(route)
        val end = guide.totalM
        guide.locate(guide.pointAt(end - 180.0), 0)
        val nearEnd = guide.locate(guide.pointAt(end - 118.0), 10_000)
        assertEquals(118.0, nearEnd.remainingM, 3.0)
        val jump = guide.locate(start, 11_000)
        assertTrue(jump.remainingM < 120.0, "jump picked opening leg: ${jump.remainingM}")
        val endNearStart = Geo.destination(start, 0.0, 55.0)
        val offset = RouteGuide(route.dropLast(1) + com.trailmind.core.geo.TrackPoint(endNearStart.lat, endNearStart.lon))
        offset.locate(offset.pointAt(offset.totalM - 350.0), 0)
        offset.locate(offset.pointAt(offset.totalM - 118.0), 10_000)
        repeat(3) { step ->
            val remaining = offset.locate(start, 11_000L + 1000L * step).remainingM
            assertTrue(remaining < 120.0, "car-park fix picked opening leg: $remaining")
        }
    }

    @Test
    fun loopStartDoesNotSnapToItsFinishFromMidRoute() {
        val origin = com.trailmind.core.geo.LatLon(51.73, -2.53)
        val route = listOf(origin, Geo.destination(origin, 90.0, 1000.0),
            Geo.destination(origin, 0.0, 800.0), Geo.destination(origin, 270.0, 1000.0), origin)
            .map { com.trailmind.core.geo.TrackPoint(it.lat, it.lon) }
        val guide = RouteGuide(route)
        guide.locate(guide.pointAt(guide.totalM * 0.37), 0)
        guide.locate(origin, 1_000)
        val atStart = guide.locate(origin, 2_000)
        assertTrue(atStart.remainingM > guide.totalM - 10.0, "start snapped to finish: ${atStart.remainingM}")
    }

    @Test
    fun jumpNearFinishPrefersCloserProgressOnOverlappingLeg() {
        val origin = LatLon(51.73, -2.53)
        val east = Geo.destination(origin, 90.0, 1000.0)
        val north = Geo.destination(origin, 0.0, 500.0)
        val northEast = Geo.destination(north, 90.0, 1000.0)
        val end = Geo.destination(origin, 90.0, 200.0)
        val route = listOf(origin, east, northEast, north, origin, end)
            .map { TrackPoint(it.lat, it.lon) }
        val guide = RouteGuide(route)
        guide.locate(guide.pointAt(2100.0), 0)
        guide.locate(guide.pointAt(3100.0), 1_000)
        val nearFinish = guide.locate(guide.pointAt(3100.0), 2_000)
        assertEquals(100.0, nearFinish.remainingM, 5.0)
    }

    @Test
    fun shortcutToEarlierParallelLegDoesNotStayOnDistantLeg() {
        val origin = LatLon(51.73, -2.53)
        val outward = line(101, start = origin)
        val returnStart = Geo.destination(outward.last().latLon(), 0.0, 90.0)
        val returning = (1..100).map { step ->
            Geo.destination(returnStart, 270.0, step * 10.0).let { TrackPoint(it.lat, it.lon) }
        }
        val guide = RouteGuide(outward + TrackPoint(returnStart.lat, returnStart.lon) + returning)
        guide.locate(guide.pointAt(1590.0), 0)
        val shortcut = outward[50].latLon()
        guide.locate(shortcut, 1_000)
        val recovered = guide.locate(shortcut, 2_000)
        assertTrue(recovered.offRouteM < 5.0, "on-route shortcut reported ${recovered.offRouteM} m away")
        assertTrue(recovered.alongM < 600.0, "shortcut stayed on the return leg: ${recovered.alongM}")
    }

    @Test
    fun overlappingReturnAndFigureEightCrossingRetainDirection() {
        val out = line(51)
        val guide = RouteGuide(out + out.reversed().drop(1))
        guide.locate(out[40].latLon(), 0)
        guide.locate(out[45].latLon(), 10_000)
        guide.locate(out.last().latLon(), 20_000)
        guide.locate(out[45].latLon(), 30_000)
        assertEquals(100.0, guide.locate(out[10].latLon(), 100_000).remainingM, 2.0)
        val origin = com.trailmind.core.geo.LatLon(51.73, -2.53)
        val corners = listOf(Geo.destination(origin, 315.0, 150.0), origin,
            Geo.destination(origin, 45.0, 150.0), origin,
            Geo.destination(origin, 225.0, 150.0), origin, Geo.destination(origin, 135.0, 150.0))
        val crossing = RouteGuide(corners.map { com.trailmind.core.geo.TrackPoint(it.lat, it.lon) })
        crossing.locate(crossing.pointAt(crossing.cumulative[1] + 30.0), 0)
        crossing.locate(crossing.pointAt(crossing.cumulative[2] - 10.0), 10_000)
        val approach = crossing.locate(crossing.pointAt(crossing.cumulative[2] + 30.0), 20_000)
        val near = crossing.locate(crossing.pointAt(crossing.cumulative[3] - 20.0), 30_000)
        val center = crossing.locate(origin, 40_000)
        assertTrue(center.alongM > crossing.cumulative[1], "approach ${approach.alongM}, near ${near.alongM}, center ${center.alongM}")
    }

    @Test
    fun rejectsOneJumpButAcceptsRestartOrLongGap() {
        val guide = RouteGuide(line(301))
        guide.locate(guide.pointAt(2800.0), 0)
        assertTrue(guide.locate(guide.pointAt(50.0), 1000).remainingM < 500.0)
        assertTrue(guide.locate(guide.pointAt(50.0), 2000).alongM < 100.0)
        guide.reset()
        guide.locate(guide.pointAt(2800.0), 0)
        assertTrue(guide.locate(guide.pointAt(50.0), 600_000).alongM < 100.0)
        guide.reset()
        guide.locate(guide.pointAt(2800.0), 0)
        assertTrue(guide.locate(guide.pointAt(50.0), 3_600_000).alongM < 100.0)
        guide.reset()
        guide.locate(guide.pointAt(1000.0), 0)
        guide.locate(guide.pointAt(2000.0), 1_000)
        assertEquals(2000.0, guide.locate(guide.pointAt(2000.0), 2_000).alongM, 5.0)
        guide.locate(guide.pointAt(1900.0), 3_000)
        guide.locate(guide.pointAt(1550.0), 4_000)
        assertEquals(1550.0, guide.locate(guide.pointAt(1550.0), 5_000).alongM, 5.0)
    }

    @Test
    fun routeStartRequiresTravelOrRecordingOnCorridor() {
        val guide = RouteGuide(line(1001))
        val start = com.trailmind.core.nav.RouteStart()
        assertFalse(start.update(guide.locate(guide.pointAt(150.0), 0), false))
        assertFalse(start.update(guide.locate(guide.pointAt(151.0), 10_000), false))
        assertTrue(start.update(guide.locate(guide.pointAt(200.0), 20_000), false))
        val recording = com.trailmind.core.nav.RouteStart()
        assertFalse(recording.update(guide.locate(Geo.destination(guide.pointAt(300.0), 0.0, 100.0)), true))
        assertTrue(recording.update(guide.locate(guide.pointAt(300.0)), true))
    }

    @Test
    fun watchDaylightAlertFitsRoundScreenAndUsesExistingInfoFrame() {
        for (dark in listOf(false, true)) {
            val text = Daylight.watchAlert(dark)
            assertTrue(text.length <= 44)
            val payload = com.trailmind.core.watch.WatchProtocol.alert(
                com.trailmind.core.watch.WatchProtocol.ALERT_INFO, text)
            com.trailmind.core.watch.WatchProtocol.reader(payload).use { reader ->
                assertEquals(com.trailmind.core.watch.WatchProtocol.ALERT_INFO, reader.readUnsignedByte())
                assertEquals(text, reader.readUTF())
            }
        }
    }

    @Test
    fun daylightAlertsDoNotDoubleFireWhenBothThresholdsAreAlreadyPast() {
        assertEquals(1, Daylight.alertDue(true, true, false, false))
        assertEquals(0, Daylight.alertDue(true, true, true, true))
        assertEquals(2, Daylight.alertDue(true, true, true, false))
        assertEquals(0, Daylight.alertDue(false, false, false, false))
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
        val now = 100L * 3_600_000
        assertTrue(TilePolicy.premiumCacheFresh(now - 24L * 3_600_000 + 1, now))
        assertFalse(TilePolicy.premiumCacheFresh(now - 24L * 3_600_000, now))
        assertFalse(TilePolicy.premiumCacheFresh(now - 25L * 3_600_000, now))
        assertFalse(TilePolicy.premiumCacheFresh(now + 60_000, now))
        assertTrue(TilePolicy.isBulkDownloadForbidden("https://tile.openstreetmap.org/{z}/{x}/{y}.png"))
        assertTrue(TilePolicy.isBulkDownloadForbidden("https://a.tile.opentopomap.org/{z}/{x}/{y}.png"))
        assertTrue(TilePolicy.isBulkDownloadForbidden("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"))
        assertFalse(TilePolicy.isBulkDownloadForbidden("https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/{z}/{x}/{y}.png?key={key}"))
        assertEquals("api.os.uk", TilePolicy.hostOf("https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/{z}/{x}/{y}.png?key={key}"))
        assertFalse(TilePolicy.isBulkDownloadForbidden("https://tiles.example.com/{z}/{x}/{-y}.png"))
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

    @Test
    fun distanceMarksEveryKilometreOrMile() {
        val guide = RouteGuide(line(351)) // 3.5 km
        val km = DistanceMarks.along(guide, DistanceMarks.stepM(imperial = false))
        assertEquals(3, km.size)
        km.forEachIndexed { i, m -> assertEquals((i + 1) * 1000.0, Geo.distanceM(guide.points.first().latLon(), m), 1.0) }
        assertEquals(2, DistanceMarks.along(guide, DistanceMarks.stepM(imperial = true)).size)
        assertEquals(1, DistanceMarks.every(stepPx = 80.0, minPx = 56.0))
        assertEquals(5, DistanceMarks.every(stepPx = 20.0, minPx = 56.0))
        assertEquals(500, DistanceMarks.every(stepPx = 0.01, minPx = 56.0))
    }

    @Test
    fun highPointAndTheTimeToReachIt() {
        // 4 km, climbing to 500 m halfway, then back down.
        val pts = line(401).mapIndexed { i, p -> p.copy(ele = 100.0 + 2.0 * minOf(i, 400 - i)) }
        val hp = assertNotNull(HikeEstimator.highPoint(pts))
        assertEquals(500.0, hp.eleM)
        assertEquals(2000.0, Geo.distanceM(pts.first().latLon(), hp.position), 1.0)
        val all = HikeEstimator.estimate(pts).planningMinutes
        assertTrue(hp.minutesFromStart > all / 2 && hp.minutesFromStart < all, "${hp.minutesFromStart} of $all")
        assertNull(HikeEstimator.highPoint(line(10).map { it.copy(ele = null) }))
    }

    private fun hour(
        timeMs: Long = 0L, t: Double = 7.0, feels: Double = 2.7, wind: Double = 23.0, gust: Double = 49.3, from: Double = 238.0,
        rain: Double = 8.0, mm: Double = 0.0, low: Double = 87.0, vis: Double = 11_680.0, frz: Double = 2020.0,
    ) = ForecastHour(timeMs, t, feels, wind, gust, from, rain, mm, low, vis, frz)

    @Test
    fun mountainWeatherInWalkersTerms() {
        // Helvellyn's summit (950 m) as Open-Meteo forecast it on 26 September 2026.
        val h = hour()
        assertEquals(
            "7°C, feels like 3°C, wind WSW 23 km/h gusting 49 km/h, 8% chance of rain, low cloud 87% (the tops may be in cloud), freezing level 2020 m",
            MountainWeather.summary(h, imperial = false),
        )
        assertTrue(MountainWeather.summary(h, imperial = true).contains("gusting 31 mph"))
        assertTrue(MountainWeather.warnings(h, 950.0, imperial = false).isEmpty())
        val wild = MountainWeather.warnings(hour(feels = -4.0, gust = 85.0, frz = 800.0, vis = 300.0), 950.0, imperial = false)
        assertEquals(4, wild.size, wild.joinToString("\n"))
        assertTrue(wild[0].startsWith("Gusts of 85 km/h: dangerous"))
        // Values the source doesn't give are left out and never warned about.
        val sparse = hour(feels = Double.NaN, from = Double.NaN, frz = Double.NaN, vis = Double.NaN)
        assertEquals("7°C, wind 23 km/h gusting 49 km/h, 8% chance of rain, low cloud 87% (the tops may be in cloud)", MountainWeather.summary(sparse, false))
        assertTrue(MountainWeather.warnings(sparse, 950.0, false).isEmpty())
    }

    @Test
    fun forecastHourNearestTheTime() {
        val t0 = 1_790_380_800_000L
        val f = PointForecast(t0, (0 until 3).map { hour(timeMs = t0 + it * 3_600_000L, t = it.toDouble()) })
        assertEquals(1.0, f.at(t0 + 40 * 60_000L)?.temperatureC)
        assertEquals(2.0, f.at(t0 + 3 * 3_600_000L)?.temperatureC)
        assertNull(f.at(t0 + 4 * 3_600_000L))
    }

    @Test
    fun briefingUsesTheSavedForecastForTheHighPoint() {
        val start = 1_790_380_800_000L // 00:00 UTC
        val base = BriefingInput(
            routeName = "Helvellyn", estimate = HikeEstimator.estimate(line(401)), start = LatLon(54.54, -2.95), end = LatLon(54.54, -2.95),
            maxEleM = 950.0, waypointNames = emptyList(), sun = null, plannedStartMs = start, zone = ZoneOffset.UTC,
        )
        assertTrue(Briefing.ruleBased(base).any { it.startsWith("High point 950 m") })
        // 2 h 30 of walking to the top is 3 h with breaks.
        val hp = HighPoint(LatLon(54.527, -3.016), 950.0, minutesFromStart = 150.0)
        val forecast = PointForecast(start - 3_600_000L, (0 until 6).map { hour(timeMs = start + it * 3_600_000L, gust = if (it == 3) 70.0 else 30.0) })
        val lines = Briefing.ruleBased(base.copy(highPoint = hp, forecast = forecast))
        assertTrue(lines.any { it.startsWith("Forecast for the high point (950 m) at about 03:00: 7°C") }, lines.joinToString("\n"))
        assertTrue(lines.any { it.startsWith("⚠ Gusts of 70 km/h") })
        assertFalse(lines.any { it.startsWith("High point") })
        val tomorrow = Briefing.ruleBased(base.copy(plannedStartMs = start + 86_400_000L, highPoint = hp, forecast = forecast))
        assertTrue(tomorrow.any { it.startsWith("The saved forecast doesn't reach") }, tomorrow.joinToString("\n"))
    }
}
