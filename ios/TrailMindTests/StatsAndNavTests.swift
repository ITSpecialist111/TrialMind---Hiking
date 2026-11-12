import XCTest
@testable import TrailMind

// StatsAndNavTest.kt also holds premiumExpiryIncludesBoundaryClockRollbackAndIdleBatch and tilePolicy, which test
// TilePolicy (map), and checks the watch daylight alert's WatchProtocol frame; those belong with the TilePolicy and
// WatchProtocol ports.
final class StatsAndNavTests: XCTestCase {
    /// Straight line heading east, one point every 10 m, climbing `climbPerPoint` metres each.
    private func line(_ n: Int, climbPerPoint: Double = 0.0, start: LatLon = LatLon(54.0, -3.0), stepM: Double = 10.0) -> [TrackPoint] {
        (0..<n).map { i in
            let p = Geo.destination(start, bearingDeg: 90.0, distanceM: Double(i) * stepM)
            return TrackPoint(lat: p.lat, lon: p.lon, ele: 100.0 + Double(i) * climbPerPoint, timeMs: 1_000_000 + Int64(i) * 7_000)
        }
    }

    private func point(_ p: LatLon) -> TrackPoint { TrackPoint(lat: p.lat, lon: p.lon) }

    private func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    func testSummaryDistanceAscentAndMovingTime() {
        let pts = line(101, climbPerPoint: 1.0) // 1 km, +100 m
        let s = TrackStats.summarize(pts)
        XCTAssertEqual(s.distanceM, 1000.0, accuracy: 1.0)
        XCTAssertEqual(s.ascentM, 100.0, accuracy: 4.1)
        XCTAssertEqual(s.descentM, 0.0)
        XCTAssertEqual(s.durationMs, 700_000)
        XCTAssertEqual(s.movingMs, 700_000)
        XCTAssertEqual(s.minEleM, 100.0)
    }

    func testAscentIgnoresNoise() {
        let noisy = [100.0, 101.5, 99.0, 102.0, 100.5, 101.0, 99.5]
        let (up, down) = TrackStats.ascentDescent(noisy)
        XCTAssertEqual(up, 0.0)
        XCTAssertEqual(down, 0.0)
        let (up2, down2) = TrackStats.ascentDescent([100.0, 110.0, 105.0, 120.0])
        XCTAssertEqual(up2, 25.0)
        XCTAssertEqual(down2, 5.0)
    }

    func testNaismithOnFlatAndClimb() throws {
        let flat = HikeEstimator.estimate(line(1001, climbPerPoint: 0.0)) // 10 km flat
        XCTAssertEqual(flat.naismithMinutes, 120.0, accuracy: 1.0)
        XCTAssertTrue((115.0...125.0).contains(flat.toblerMinutes), "tobler=\(flat.toblerMinutes)")
        let climb = HikeEstimator.estimate(line(1001, climbPerPoint: 0.06)) // 10 km, +60 m
        XCTAssertEqual(climb.naismithMinutes, 126.0, accuracy: 1.5)
        let slow = HikeEstimator.estimate(line(1001, climbPerPoint: 0.0), pace: try PaceSettings(flatSpeedKmh: 4.0, conditionsFactor: 1.25))
        XCTAssertEqual(slow.naismithMinutes, 187.5, accuracy: 1.5)
    }

    func testDaylightFinishTurnBackAndPace() throws {
        let route = line(1001).map { p -> TrackPoint in
            var q = p
            q.ele = nil
            return q
        }
        let now: Int64 = 1_000_000_000
        let pace = try PaceSettings(flatSpeedKmh: 5.0)
        let sun = SunTimes(sunriseMs: now - 6 * 3_600_000, sunsetMs: now + 3 * 3_600_000, polarDay: false, polarNight: false,
                           civilDuskMs: now + 4 * 3_600_000)
        let walked = Array(route.prefix(501))
        let remaining = Array(route.dropFirst(500))
        let normal = Daylight.estimate(nowMs: now, remaining: remaining, walked: walked, movingMinutes: nil, pace: pace, sun: sun, marginMinutes: 30)
        XCTAssertEqual(normal.remainingMinutes, 60.0, accuracy: 1.0)
        XCTAssertEqual(try XCTUnwrap(normal.walkBackMinutes), 60.0, accuracy: 1.0)
        let turnBack = try XCTUnwrap(normal.turnBackByMs)
        XCTAssertTrue(abs(turnBack - (now + 90 * 60_000)) < 60_000)
        let startBy = try XCTUnwrap(normal.startByMs)
        XCTAssertTrue(abs(startBy - (now + 90 * 60_000)) < 60_000)
        XCTAssertFalse(try XCTUnwrap(normal.afterSafeSunset))
        let slow = Daylight.estimate(nowMs: now, remaining: remaining, walked: walked, movingMinutes: 120.0, pace: pace, sun: sun, marginMinutes: 30)
        XCTAssertEqual(slow.remainingMinutes, 120.0, accuracy: 2.0)
        let slowTurnBack = try XCTUnwrap(slow.turnBackByMs)
        XCTAssertTrue(abs(slowTurnBack - (now + 30 * 60_000)) < 60_000)
        XCTAssertTrue(abs(slow.finishMs - (now + 120 * 60_000)) <= 120_000)
        var lateSun = sun
        lateSun.sunsetMs = now + 90 * 60_000
        lateSun.civilDuskMs = now + 110 * 60_000
        let late = Daylight.estimate(nowMs: now, remaining: route, walked: [], movingMinutes: nil, pace: pace, sun: lateSun, marginMinutes: 30)
        XCTAssertNil(late.walkBackMinutes)
        XCTAssertNil(late.turnBackByMs)
        XCTAssertTrue(try XCTUnwrap(late.afterSafeSunset))
        XCTAssertTrue(try XCTUnwrap(late.afterCivilDusk))
        XCTAssertTrue(try XCTUnwrap(late.startByMs) < now)
        var earlySun = sun
        earlySun.sunriseMs = now - 30 * 60_000
        earlySun.sunsetMs = now + 90 * 60_000
        XCTAssertNil(Daylight.estimate(nowMs: now, remaining: route, walked: [], movingMinutes: nil, pace: pace, sun: earlySun, marginMinutes: 30).startByMs)
        let polar = Daylight.estimate(nowMs: now, remaining: route, walked: [], movingMinutes: nil, pace: pace,
                                      sun: SunTimes(sunriseMs: nil, sunsetMs: nil, polarDay: true, polarNight: false), marginMinutes: 30)
        XCTAssertNil(polar.daylightLeftMs)
        XCTAssertNil(polar.afterSafeSunset)
        XCTAssertNil(polar.turnBackByMs)
        XCTAssertNil(polar.startByMs)
    }

    func testDaylightBeforeSunriseAndAcrossTheAutumnClockChange() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = DateComponents(year: 2026, month: 10, day: 25)
        let nextDate = DateComponents(year: 2026, month: 10, day: 26)
        let route = line(1001).map { p -> TrackPoint in
            var q = p
            q.ele = nil
            return q
        }
        let at = LatLon(51.73, -2.53)
        let sun = Sun.times(date, at)
        let before = try XCTUnwrap(sun.sunriseMs) - 2 * 3_600_000
        let predawn = Daylight.estimate(nowMs: before, remaining: route, walked: [], movingMinutes: nil, pace: PaceSettings(), sun: sun,
                                        marginMinutes: 30, zone: zone)
        XCTAssertEqual(predawn.darkNow, true)
        XCTAssertEqual(predawn.nextSunriseMs, sun.sunriseMs)
        XCTAssertEqual(predawn.afterSafeSunset, true)
        XCTAssertEqual(predawn.afterCivilDusk, true)
        XCTAssertNil(predawn.daylightLeftMs)
        let lateNow = ms(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 30))))
        let late = Daylight.estimate(nowMs: lateNow, remaining: route, walked: [], movingMinutes: nil, pace: PaceSettings(), sun: sun,
                                     marginMinutes: 30, zone: zone)
        XCTAssertEqual(late.darkNow, true)
        XCTAssertEqual(late.nextSunriseMs, Sun.times(nextDate, route[0].latLon()).sunriseMs)
        XCTAssertEqual(late.afterCivilDusk, true)
        let finishDay = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(late.finishMs) / 1000.0))
        XCTAssertEqual([finishDay.year, finishDay.month, finishDay.day], [2026, 10, 26])
        let noSunset = Daylight.estimate(nowMs: before, remaining: route, walked: [], movingMinutes: nil, pace: PaceSettings(),
                                         sun: SunTimes(sunriseMs: before - 60_000, sunsetMs: nil, polarDay: false, polarNight: false),
                                         marginMinutes: 30, zone: zone)
        XCTAssertNil(noSunset.darkNow)
        XCTAssertNil(noSunset.afterSafeSunset)
        let polarNight = Daylight.estimate(nowMs: before, remaining: route, walked: [], movingMinutes: nil, pace: PaceSettings(),
                                           sun: SunTimes(sunriseMs: nil, sunsetMs: nil, polarDay: false, polarNight: true),
                                           marginMinutes: 30, zone: zone)
        XCTAssertEqual(polarNight.darkNow, true)
        XCTAssertEqual(polarNight.afterCivilDusk, true)
    }

    func testRouteGuideTracksProgressAndWaypoints() throws {
        let route = line(101, climbPerPoint: 1.0) // 1 km east, climbing 100 m
        let last = route[route.count - 1]
        let wpEnd = Waypoint(lat: last.lat, lon: last.lon, name: "Top")
        let guide = try RouteGuide(route, waypoints: [wpEnd])
        XCTAssertEqual(guide.totalM, 1000.0, accuracy: 1.0)
        let here = Geo.destination(Geo.destination(route[0].latLon(), bearingDeg: 90.0, distanceM: 400.0), bearingDeg: 0.0, distanceM: 20.0)
        let fix = guide.locate(here)
        XCTAssertEqual(fix.alongM, 400.0, accuracy: 2.0)
        XCTAssertEqual(fix.remainingM, 600.0, accuracy: 2.0)
        XCTAssertEqual(fix.offRouteM, 20.0, accuracy: 1.0)
        XCTAssertEqual(fix.remainingAscentM, 60.0, accuracy: 1.5)
        XCTAssertEqual(fix.progress, 0.4, accuracy: 0.01)
        XCTAssertEqual(fix.routeBearingDeg, 90.0, accuracy: 1.0)
        let next = try XCTUnwrap(fix.nextWaypoint)
        XCTAssertEqual(next.waypoint.name, "Top")
        XCTAssertEqual(next.alongRouteM, 600.0, accuracy: 2.0)
        XCTAssertFalse(fix.atEnd)
        XCTAssertTrue(guide.locate(last.latLon()).atEnd)
        XCTAssertEqual(Geo.distanceM(guide.pointAt(-5.0), route[0].latLon()), 0.0, accuracy: 0.01)
        XCTAssertEqual(Geo.distanceM(guide.pointAt(455.0), Geo.destination(route[0].latLon(), bearingDeg: 90.0, distanceM: 455.0)), 0.0, accuracy: 0.5)
        XCTAssertEqual(Geo.distanceM(guide.pointAt(5_000.0), last.latLon()), 0.0, accuracy: 0.01)
    }

    func testRouteGuidePrefersContinuityOnOutAndBack() throws {
        let out = line(51) // 500 m east
        let back = out.reversed().dropFirst().map { p -> TrackPoint in // ~5 m north, heading west
            var q = p
            q.lat = p.lat + 0.00005
            return q
        }
        let guide = try RouteGuide(out + back)
        guide.locate(out[5].latLon())
        let first = guide.locate(out[20].latLon())
        XCTAssertTrue(first.alongM < 500, "should stay on outbound leg, was \(first.alongM)")
        guide.locate(out[50].latLon())
        guide.reset()
        guide.locate(out[49].latLon())
        let onReturn = guide.locate(out[45].latLon())
        XCTAssertTrue(onReturn.offRouteM < 1.0, "snapped \(onReturn.offRouteM) m away")
        XCTAssertTrue(onReturn.alongM < 500, "should snap to the outbound leg nearest the walker")
    }

    func testLoopEndDoesNotSnapToItsStart() throws {
        let start = LatLon(51.73, -2.53)
        let route = [start, Geo.destination(start, bearingDeg: 90.0, distanceM: 1000.0),
                     Geo.destination(start, bearingDeg: 0.0, distanceM: 800.0), Geo.destination(start, bearingDeg: 270.0, distanceM: 1000.0), start]
            .map(point)
        let guide = try RouteGuide(route)
        let end = guide.totalM
        guide.locate(guide.pointAt(end - 180.0), timeMs: 0)
        let nearEnd = guide.locate(guide.pointAt(end - 118.0), timeMs: 10_000)
        XCTAssertEqual(nearEnd.remainingM, 118.0, accuracy: 3.0)
        let jump = guide.locate(start, timeMs: 11_000)
        XCTAssertTrue(jump.remainingM < 120.0, "jump picked opening leg: \(jump.remainingM)")
        let endNearStart = Geo.destination(start, bearingDeg: 0.0, distanceM: 55.0)
        let offset = try RouteGuide(Array(route.dropLast()) + [point(endNearStart)])
        offset.locate(offset.pointAt(offset.totalM - 350.0), timeMs: 0)
        offset.locate(offset.pointAt(offset.totalM - 118.0), timeMs: 10_000)
        for step in 0..<3 {
            let remaining = offset.locate(start, timeMs: 11_000 + 1000 * Int64(step)).remainingM
            XCTAssertTrue(remaining < 120.0, "car-park fix picked opening leg: \(remaining)")
        }
    }

    func testLoopStartDoesNotSnapToItsFinishFromMidRoute() throws {
        let origin = LatLon(51.73, -2.53)
        let route = [origin, Geo.destination(origin, bearingDeg: 90.0, distanceM: 1000.0),
                     Geo.destination(origin, bearingDeg: 0.0, distanceM: 800.0), Geo.destination(origin, bearingDeg: 270.0, distanceM: 1000.0), origin]
            .map(point)
        let guide = try RouteGuide(route)
        guide.locate(guide.pointAt(guide.totalM * 0.37), timeMs: 0)
        guide.locate(origin, timeMs: 1_000)
        let atStart = guide.locate(origin, timeMs: 2_000)
        XCTAssertTrue(atStart.remainingM > guide.totalM - 10.0, "start snapped to finish: \(atStart.remainingM)")
    }

    func testJumpNearFinishPrefersCloserProgressOnOverlappingLeg() throws {
        let origin = LatLon(51.73, -2.53)
        let east = Geo.destination(origin, bearingDeg: 90.0, distanceM: 1000.0)
        let north = Geo.destination(origin, bearingDeg: 0.0, distanceM: 500.0)
        let northEast = Geo.destination(north, bearingDeg: 90.0, distanceM: 1000.0)
        let end = Geo.destination(origin, bearingDeg: 90.0, distanceM: 200.0)
        let route = [origin, east, northEast, north, origin, end].map(point)
        let guide = try RouteGuide(route)
        guide.locate(guide.pointAt(2100.0), timeMs: 0)
        guide.locate(guide.pointAt(3100.0), timeMs: 1_000)
        let nearFinish = guide.locate(guide.pointAt(3100.0), timeMs: 2_000)
        XCTAssertEqual(nearFinish.remainingM, 100.0, accuracy: 5.0)
    }

    func testShortcutToEarlierParallelLegDoesNotStayOnDistantLeg() throws {
        let origin = LatLon(51.73, -2.53)
        let outward = line(101, start: origin)
        let returnStart = Geo.destination(outward[outward.count - 1].latLon(), bearingDeg: 0.0, distanceM: 90.0)
        let returning = (1...100).map { step in point(Geo.destination(returnStart, bearingDeg: 270.0, distanceM: Double(step) * 10.0)) }
        let guide = try RouteGuide(outward + [point(returnStart)] + returning)
        guide.locate(guide.pointAt(1590.0), timeMs: 0)
        let shortcut = outward[50].latLon()
        guide.locate(shortcut, timeMs: 1_000)
        let recovered = guide.locate(shortcut, timeMs: 2_000)
        XCTAssertTrue(recovered.offRouteM < 5.0, "on-route shortcut reported \(recovered.offRouteM) m away")
        XCTAssertTrue(recovered.alongM < 600.0, "shortcut stayed on the return leg: \(recovered.alongM)")
    }

    func testOverlappingReturnAndFigureEightCrossingRetainDirection() throws {
        let out = line(51)
        let guide = try RouteGuide(out + Array(out.reversed().dropFirst()))
        guide.locate(out[40].latLon(), timeMs: 0)
        guide.locate(out[45].latLon(), timeMs: 10_000)
        guide.locate(out[out.count - 1].latLon(), timeMs: 20_000)
        guide.locate(out[45].latLon(), timeMs: 30_000)
        XCTAssertEqual(guide.locate(out[10].latLon(), timeMs: 100_000).remainingM, 100.0, accuracy: 2.0)
        let origin = LatLon(51.73, -2.53)
        let corners = [Geo.destination(origin, bearingDeg: 315.0, distanceM: 150.0), origin,
                       Geo.destination(origin, bearingDeg: 45.0, distanceM: 150.0), origin,
                       Geo.destination(origin, bearingDeg: 225.0, distanceM: 150.0), origin, Geo.destination(origin, bearingDeg: 135.0, distanceM: 150.0)]
        let crossing = try RouteGuide(corners.map(point))
        crossing.locate(crossing.pointAt(crossing.cumulative[1] + 30.0), timeMs: 0)
        crossing.locate(crossing.pointAt(crossing.cumulative[2] - 10.0), timeMs: 10_000)
        let approach = crossing.locate(crossing.pointAt(crossing.cumulative[2] + 30.0), timeMs: 20_000)
        let near = crossing.locate(crossing.pointAt(crossing.cumulative[3] - 20.0), timeMs: 30_000)
        let center = crossing.locate(origin, timeMs: 40_000)
        XCTAssertTrue(center.alongM > crossing.cumulative[1], "approach \(approach.alongM), near \(near.alongM), center \(center.alongM)")
    }

    func testRejectsOneJumpButAcceptsRestartOrLongGap() throws {
        let guide = try RouteGuide(line(301))
        guide.locate(guide.pointAt(2800.0), timeMs: 0)
        XCTAssertTrue(guide.locate(guide.pointAt(50.0), timeMs: 1000).remainingM < 500.0)
        XCTAssertTrue(guide.locate(guide.pointAt(50.0), timeMs: 2000).alongM < 100.0)
        guide.reset()
        guide.locate(guide.pointAt(2800.0), timeMs: 0)
        XCTAssertTrue(guide.locate(guide.pointAt(50.0), timeMs: 600_000).alongM < 100.0)
        guide.reset()
        guide.locate(guide.pointAt(2800.0), timeMs: 0)
        XCTAssertTrue(guide.locate(guide.pointAt(50.0), timeMs: 3_600_000).alongM < 100.0)
        guide.reset()
        guide.locate(guide.pointAt(1000.0), timeMs: 0)
        guide.locate(guide.pointAt(2000.0), timeMs: 1_000)
        XCTAssertEqual(guide.locate(guide.pointAt(2000.0), timeMs: 2_000).alongM, 2000.0, accuracy: 5.0)
        guide.locate(guide.pointAt(1900.0), timeMs: 3_000)
        guide.locate(guide.pointAt(1550.0), timeMs: 4_000)
        XCTAssertEqual(guide.locate(guide.pointAt(1550.0), timeMs: 5_000).alongM, 1550.0, accuracy: 5.0)
    }

    func testRouteStartRequiresTravelOrRecordingOnCorridor() throws {
        let guide = try RouteGuide(line(1001))
        let start = RouteStart()
        XCTAssertFalse(start.update(guide.locate(guide.pointAt(150.0), timeMs: 0), recording: false))
        XCTAssertFalse(start.update(guide.locate(guide.pointAt(151.0), timeMs: 10_000), recording: false))
        XCTAssertTrue(start.update(guide.locate(guide.pointAt(200.0), timeMs: 20_000), recording: false))
        let recording = RouteStart()
        XCTAssertFalse(recording.update(guide.locate(Geo.destination(guide.pointAt(300.0), bearingDeg: 0.0, distanceM: 100.0)), recording: true))
        XCTAssertTrue(recording.update(guide.locate(guide.pointAt(300.0)), recording: true))
    }

    func testWatchDaylightAlertFitsRoundScreenAndUsesExistingInfoFrame() {
        // The WatchProtocol alert frame round trip of the Kotlin test belongs with the WatchProtocol port.
        for dark in [false, true] {
            let text = Daylight.watchAlert(darkNow: dark)
            XCTAssertTrue(text.utf16.count <= 44)
        }
    }

    func testDaylightAlertsDoNotDoubleFireWhenBothThresholdsAreAlreadyPast() {
        XCTAssertEqual(Daylight.alertDue(sunsetDue: true, duskDue: true, sunsetAlerted: false, duskAlerted: false), 1)
        XCTAssertEqual(Daylight.alertDue(sunsetDue: true, duskDue: true, sunsetAlerted: true, duskAlerted: true), 0)
        XCTAssertEqual(Daylight.alertDue(sunsetDue: true, duskDue: true, sunsetAlerted: true, duskAlerted: false), 2)
        XCTAssertEqual(Daylight.alertDue(sunsetDue: false, duskDue: false, sunsetAlerted: false, duskAlerted: false), 0)
    }

    func testOffRouteHysteresis() {
        let d = OffRouteDetector(thresholdM: 50.0, confirmFixes: 3)
        XCTAssertEqual(d.update(80.0), OffRouteDetector.Event.none)
        XCTAssertEqual(d.update(80.0), OffRouteDetector.Event.none)
        XCTAssertEqual(d.update(80.0), OffRouteDetector.Event.leftRoute)
        XCTAssertTrue(d.isOffRoute)
        XCTAssertEqual(d.update(45.0), OffRouteDetector.Event.none)
        XCTAssertEqual(d.update(20.0), OffRouteDetector.Event.rejoinedRoute)
        // Poor accuracy fixes don't trigger alarms.
        for _ in 0..<5 { XCTAssertEqual(d.update(70.0, accuracyM: 30.0), OffRouteDetector.Event.none) }
    }

    func testTrackFilterRejectsJitterAndJumps() {
        let f = TrackFilter(maxAccuracyM: 30, minDistanceM: 5.0)
        let base = LatLon(54.0, -3.0)
        XCTAssertTrue(f.accept(TrackPoint(lat: base.lat, lon: base.lon, timeMs: 0, accuracyM: 5)))
        let jitter = Geo.destination(base, bearingDeg: 10.0, distanceM: 2.0)
        XCTAssertFalse(f.accept(TrackPoint(lat: jitter.lat, lon: jitter.lon, timeMs: 5_000, accuracyM: 5)))
        XCTAssertFalse(f.accept(TrackPoint(lat: base.lat, lon: base.lon, timeMs: 6_000, accuracyM: 80)))
        let jump = Geo.destination(base, bearingDeg: 10.0, distanceM: 2_000.0)
        XCTAssertFalse(f.accept(TrackPoint(lat: jump.lat, lon: jump.lon, timeMs: 10_000, accuracyM: 5)))
        let step = Geo.destination(base, bearingDeg: 10.0, distanceM: 12.0)
        XCTAssertTrue(f.accept(TrackPoint(lat: step.lat, lon: step.lon, timeMs: 12_000, accuracyM: 5)))
        // Keep-alive point after a minute stationary so pauses show up in the track.
        XCTAssertTrue(f.accept(TrackPoint(lat: step.lat, lon: step.lon, timeMs: 80_000, accuracyM: 5)))
    }

    func testUnitsFormatting() {
        XCTAssertEqual(Units.distance(850.0), "850 m")
        XCTAssertEqual(Units.distance(5250.0), "5.25 km")
        XCTAssertEqual(Units.distance(12_345.0), "12.3 km")
        XCTAssertEqual(Units.distance(5000.0, imperial: true), "3.11 mi")
        XCTAssertEqual(Units.minutes(125.0), "2h 05m")
        XCTAssertEqual(Units.minutes(45.2), "45m")
        XCTAssertEqual(Units.bearing(367.0), "007°")
    }

    func testBriefingWarnsAboutDarkness() throws {
        let est = HikeEstimator.estimate(line(1001, climbPerPoint: 0.5))
        let start: Int64 = 1_750_000_000_000
        let input = BriefingInput(
            routeName: "Test", estimate: est, start: LatLon(54.5, -3.0), end: LatLon(54.6, -3.0),
            maxEleM: 700.0, waypointNames: ["Tarn"],
            sun: SunTimes(sunriseMs: start - 3_600_000, sunsetMs: start + 60 * 60_000, polarDay: false, polarNight: false),
            plannedStartMs: start, zone: try XCTUnwrap(TimeZone(identifier: "UTC"))
        )
        let lines = Briefing.ruleBased(input)
        XCTAssertTrue(lines.contains { $0.contains("AFTER sunset") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("999") })
        let prompt = Briefing.gemmaPrompt(input)
        XCTAssertTrue(prompt.contains("Route: Test"))
        XCTAssertTrue(prompt.contains("Tarn"))
    }

    func testDistanceMarksEveryKilometreOrMile() throws {
        let guide = try RouteGuide(line(351)) // 3.5 km
        let km = DistanceMarks.along(guide, stepM: DistanceMarks.stepM(imperial: false))
        XCTAssertEqual(km.count, 3)
        for (i, m) in km.enumerated() {
            XCTAssertEqual(Geo.distanceM(guide.points[0].latLon(), m), Double(i + 1) * 1000.0, accuracy: 1.0)
        }
        XCTAssertEqual(DistanceMarks.along(guide, stepM: DistanceMarks.stepM(imperial: true)).count, 2)
        XCTAssertEqual(DistanceMarks.every(stepPx: 80.0, minPx: 56.0), 1)
        XCTAssertEqual(DistanceMarks.every(stepPx: 20.0, minPx: 56.0), 5)
        XCTAssertEqual(DistanceMarks.every(stepPx: 0.01, minPx: 56.0), 500)
    }

    func testHighPointAndTheTimeToReachIt() throws {
        // 4 km, climbing to 500 m halfway, then back down.
        let pts = line(401).enumerated().map { i, p -> TrackPoint in
            var q = p
            q.ele = 100.0 + 2.0 * Double(min(i, 400 - i))
            return q
        }
        let hp = try XCTUnwrap(HikeEstimator.highPoint(pts))
        XCTAssertEqual(hp.eleM, 500.0)
        XCTAssertEqual(Geo.distanceM(pts[0].latLon(), hp.position), 2000.0, accuracy: 1.0)
        let all = HikeEstimator.estimate(pts).planningMinutes
        XCTAssertTrue(hp.minutesFromStart > all / 2 && hp.minutesFromStart < all, "\(hp.minutesFromStart) of \(all)")
        XCTAssertNil(HikeEstimator.highPoint(line(10).map { p -> TrackPoint in
            var q = p
            q.ele = nil
            return q
        }))
    }

    private func hour(
        timeMs: Int64 = 0, t: Double = 7.0, feels: Double = 2.7, wind: Double = 23.0, gust: Double = 49.3, from: Double = 238.0,
        rain: Double = 8.0, mm: Double = 0.0, low: Double = 87.0, vis: Double = 11_680.0, frz: Double = 2020.0
    ) -> ForecastHour {
        ForecastHour(timeMs: timeMs, temperatureC: t, feelsLikeC: feels, windKmh: wind, gustKmh: gust, windFromDeg: from,
                     rainChancePct: rain, rainMm: mm, lowCloudPct: low, visibilityM: vis, freezingLevelM: frz)
    }

    func testMountainWeatherInWalkersTerms() {
        // Helvellyn's summit (950 m) as Open-Meteo forecast it on 26 September 2026.
        let h = hour()
        XCTAssertEqual(
            MountainWeather.summary(h, imperial: false),
            "7°C, feels like 3°C, wind WSW 23 km/h gusting 49 km/h, 8% chance of rain, low cloud 87% (the tops may be in cloud), freezing level 2020 m"
        )
        XCTAssertTrue(MountainWeather.summary(h, imperial: true).contains("gusting 31 mph"))
        XCTAssertTrue(MountainWeather.warnings(h, eleM: 950.0, imperial: false).isEmpty)
        let wild = MountainWeather.warnings(hour(feels: -4.0, gust: 85.0, vis: 300.0, frz: 800.0), eleM: 950.0, imperial: false)
        XCTAssertEqual(wild.count, 4, wild.joined(separator: "\n"))
        XCTAssertTrue(wild[0].hasPrefix("Gusts of 85 km/h: dangerous"))
        // Values the source doesn't give are left out and never warned about.
        let sparse = hour(feels: .nan, from: .nan, vis: .nan, frz: .nan)
        XCTAssertEqual(MountainWeather.summary(sparse, imperial: false),
                       "7°C, wind 23 km/h gusting 49 km/h, 8% chance of rain, low cloud 87% (the tops may be in cloud)")
        XCTAssertTrue(MountainWeather.warnings(sparse, eleM: 950.0, imperial: false).isEmpty)
    }

    func testForecastHourNearestTheTime() {
        let t0: Int64 = 1_790_380_800_000
        let f = PointForecast(fetchedMs: t0, hours: (0..<3).map { hour(timeMs: t0 + Int64($0) * 3_600_000, t: Double($0)) })
        XCTAssertEqual(f.at(t0 + 40 * 60_000)?.temperatureC, 1.0)
        XCTAssertEqual(f.at(t0 + 3 * 3_600_000)?.temperatureC, 2.0)
        XCTAssertNil(f.at(t0 + 4 * 3_600_000))
    }

    func testBriefingUsesTheSavedForecastForTheHighPoint() throws {
        let start: Int64 = 1_790_380_800_000 // 00:00 UTC
        let base = BriefingInput(
            routeName: "Helvellyn", estimate: HikeEstimator.estimate(line(401)), start: LatLon(54.54, -2.95), end: LatLon(54.54, -2.95),
            maxEleM: 950.0, waypointNames: [], sun: nil, plannedStartMs: start, zone: try XCTUnwrap(TimeZone(identifier: "UTC"))
        )
        XCTAssertTrue(Briefing.ruleBased(base).contains { $0.hasPrefix("High point 950 m") })
        // 2 h 30 of walking to the top is 3 h with breaks.
        let hp = HighPoint(position: LatLon(54.527, -3.016), eleM: 950.0, minutesFromStart: 150.0)
        let forecast = PointForecast(fetchedMs: start - 3_600_000,
                                     hours: (0..<6).map { hour(timeMs: start + Int64($0) * 3_600_000, gust: $0 == 3 ? 70.0 : 30.0) })
        var withForecast = base
        withForecast.highPoint = hp
        withForecast.forecast = forecast
        let lines = Briefing.ruleBased(withForecast)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Forecast for the high point (950 m) at about 03:00: 7°C") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("⚠ Gusts of 70 km/h") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("High point") })
        var nextDay = withForecast
        nextDay.plannedStartMs = start + 86_400_000
        let tomorrow = Briefing.ruleBased(nextDay)
        XCTAssertTrue(tomorrow.contains { $0.hasPrefix("The saved forecast doesn't reach") }, tomorrow.joined(separator: "\n"))
    }
}
