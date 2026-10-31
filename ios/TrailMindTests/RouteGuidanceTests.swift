import XCTest
@testable import TrailMind

/// Route guidance (NavigationController's logic, ported as RouteGuidance) and the guidance wording (MapScreen.updateNav,
/// updateTarget, the alerts and DaylightText). The Android app has no unit tests for these; these pin down the
/// behaviour the port keeps.
final class RouteGuidanceTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let origin = LatLon(54.0, -3.0)

    /// A straight route heading east, a point every 10 m, flat at 100 m.
    private func route(id: Int64 = 7, lengthM: Double = 2_000, waypoints: [Waypoint] = [], pace: PaceSettings = PaceSettings()) -> GuidedRoute {
        let n = Int(lengthM / 10) + 1
        let points = (0..<n).map { i -> TrackPoint in
            let p = Geo.destination(origin, bearingDeg: 90.0, distanceM: Double(i) * 10.0)
            return TrackPoint(lat: p.lat, lon: p.lon, ele: 100.0)
        }
        return GuidedRoute.build(id: id, name: "Ridge walk", points: points, waypoints: waypoints, pace: pace)!
    }

    /// A position `alongM` metres along the test route and `northM` metres to its north (negative: south).
    private func at(_ alongM: Double, north northM: Double = 0) -> LatLon {
        let on = Geo.destination(origin, bearingDeg: 90.0, distanceM: alongM)
        return northM == 0 ? on : Geo.destination(on, bearingDeg: northM > 0 ? 0.0 : 180.0, distanceM: abs(northM))
    }

    /// 21 June 2026 at 12:00 UTC: midday, so no daylight alert interferes.
    private let midday = CivilDate.epochDay(2026, 6, 21) * 86_400_000 + 12 * 3_600_000

    private func fix(_ p: LatLon, _ timeMs: Int64, accuracy: Float = 5) -> GuidanceFix {
        GuidanceFix(position: p, timeMs: timeMs, accuracyM: accuracy)
    }

    private func leftRoute(_ events: [GuidanceEvent]) -> (offRouteM: Double, back: Double)? {
        for e in events { if case .leftRoute(let m, let b) = e { return (m, b) } }
        return nil
    }

    private func daylightWarnings(_ events: [GuidanceEvent]) -> [GuidanceEvent] {
        events.filter { if case .daylightWarning = $0 { return true } else { return false } }
    }

    func testLeavingTheRouteNeedsThreeFixesBeyondTheThresholdAndRejoiningIsInside70Percent() throws {
        let g = RouteGuidance(track: HikeTrack())
        g.follow(route(), nowMs: midday, zone: utc)
        var now = midday
        XCTAssertTrue(g.onFix(fix(at(100), now), nowMs: now, zone: utc).isEmpty)
        XCTAssertFalse(g.offRoute)
        var events: [[GuidanceEvent]] = []
        for along in [150.0, 160.0, 170.0] {
            now += 10_000
            events.append(g.onFix(fix(at(along, north: 100), now), nowMs: now, zone: utc))
        }
        XCTAssertNil(leftRoute(events[0]))
        XCTAssertNil(leftRoute(events[1]))
        let left = try XCTUnwrap(leftRoute(events[2]))
        XCTAssertEqual(left.offRouteM, 100.0, accuracy: 0.5)
        XCTAssertEqual(left.back, 180.0, accuracy: 0.5)
        XCTAssertTrue(g.offRoute)
        // Off route, the daylight forecast is withdrawn rather than shown for a place you aren't.
        XCTAssertNil(g.daylight)
        // Still 50 m out: beyond 70% of the threshold, so still off route.
        now += 10_000
        XCTAssertFalse(g.onFix(fix(at(180, north: 50), now), nowMs: now, zone: utc).contains(.rejoinedRoute))
        now += 10_000
        XCTAssertTrue(g.onFix(fix(at(190, north: 20), now), nowMs: now, zone: utc).contains(.rejoinedRoute))
        XCTAssertFalse(g.offRoute)
    }

    func testReportedAccuracyIsGivenTheBenefitOfTheDoubt() {
        let g = RouteGuidance(track: HikeTrack())
        g.follow(route(), nowMs: midday, zone: utc)
        var now = midday
        for along in stride(from: 100.0, through: 200.0, by: 10.0) {
            now += 5_000
            // 80 m out with a 30 m error circle counts as 50 m, inside the 60 m threshold.
            XCTAssertNil(leftRoute(g.onFix(fix(at(along, north: 80), now, accuracy: 30), nowMs: now, zone: utc)))
        }
        XCTAssertFalse(g.offRoute)
    }

    func testTheThresholdComesFromTheSettings() {
        let g = RouteGuidance(track: HikeTrack(), settings: GuidanceSettings(offRouteThresholdM: 150))
        g.follow(route(), nowMs: midday, zone: utc)
        var now = midday
        for along in stride(from: 100.0, through: 200.0, by: 10.0) {
            now += 5_000
            XCTAssertNil(leftRoute(g.onFix(fix(at(along, north: 100), now), nowMs: now, zone: utc)))
        }
        g.settingsChanged(GuidanceSettings(offRouteThresholdM: 60))
        var events: [GuidanceEvent] = []
        for along in [210.0, 220.0, 230.0] {
            now += 5_000
            events += g.onFix(fix(at(along, north: 100), now), nowMs: now, zone: utc)
        }
        XCTAssertNotNil(leftRoute(events))
    }

    func testProgressAndTimeLeftAreMeasuredFromTheSnappedPoint() throws {
        let g = RouteGuidance(track: HikeTrack())
        let r = route()
        g.follow(r, nowMs: midday, zone: utc)
        g.onFix(fix(at(500, north: 8), midday), nowMs: midday, zone: utc)
        let f = try XCTUnwrap(g.fix)
        XCTAssertEqual(f.alongM, 500, accuracy: 0.5)
        XCTAssertEqual(f.remainingM, 1_500, accuracy: 0.5)
        XCTAssertEqual(f.offRouteM, 8, accuracy: 0.1)
        // 1.5 km on the flat at 5 km/h.
        XCTAssertEqual(try XCTUnwrap(g.remainingMinutes), 18.0, accuracy: 0.5)
        XCTAssertEqual(r.estimate.planningMinutes, 24.0, accuracy: 0.5)
    }

    func testRetracingFollowsTheRecordedTrackBackToTheStart() throws {
        let track = HikeTrack()
        let g = RouteGuidance(track: track)
        XCTAssertNil(g.traceBack(nowMs: midday, zone: utc))
        track.begin(id: 5, name: "Walk", start: midday, restored: [], restoredActiveMs: 0, nowMs: midday)
        track.add(TrackPoint(lat: origin.lat, lon: origin.lon, ele: 90, timeMs: midday))
        XCTAssertNil(g.traceBack(nowMs: midday, zone: utc), "one point is not a track")
        for i in 1...40 {
            let p = at(Double(i) * 25)
            track.add(TrackPoint(lat: p.lat, lon: p.lon, ele: 90 + Double(i), timeMs: midday + Int64(i) * 20_000))
        }
        XCTAssertNotNil(g.traceBack(nowMs: midday, zone: utc))
        let active = try XCTUnwrap(g.active)
        XCTAssertTrue(active.isTracBack)
        XCTAssertEqual(active.name, "Retrace steps")
        XCTAssertEqual(active.points.first?.latLon(), track.points.last?.latLon())
        XCTAssertEqual(active.points.last?.latLon(), origin)
        XCTAssertEqual(active.waypoints.map(\.name), ["Start of hike"])
        XCTAssertNil(active.points.first?.timeMs)
        // Stopping a retrace goes back to the stored route being followed; stopping that clears it.
        XCTAssertEqual(g.stop(followedRouteId: 7), 7)
        XCTAssertNil(g.active)
        g.follow(route(id: 7), nowMs: midday, zone: utc)
        XCTAssertNil(g.stop(followedRouteId: 7))
        XCTAssertNotNil(g.traceBack(nowMs: midday, zone: utc))
        XCTAssertNil(g.stop(followedRouteId: -1), "no stored route to go back to")
    }

    func testFollowingReplaysTheLastFix() throws {
        let g = RouteGuidance(track: HikeTrack())
        g.onFix(fix(at(300), midday), nowMs: midday, zone: utc)
        XCTAssertNil(g.fix)
        g.follow(route(), nowMs: midday, zone: utc)
        XCTAssertEqual(try XCTUnwrap(g.fix).alongM, 300, accuracy: 0.5)
        XCTAssertNotNil(g.daylight)
        XCTAssertNotNil(g.daylightSun)
    }

    func testSettingsChangesReestimateTheRoute() throws {
        let g = RouteGuidance(track: HikeTrack())
        g.follow(route(), nowMs: midday, zone: utc)
        let before = try XCTUnwrap(g.active).estimate.planningMinutes
        g.settingsChanged(GuidanceSettings(offRouteThresholdM: 60, pace: try PaceSettings(flatSpeedKmh: 2.5), daylightMarginMinutes: 30))
        XCTAssertEqual(try XCTUnwrap(g.active).estimate.planningMinutes, before * 2, accuracy: 1.0)
        XCTAssertNil(g.daylight)
    }

    // MARK: Daylight alerts

    private let lateDay = CivilDate.epochDay(2026, 10, 31)

    /// An hour before sunset on 31 October 2026 at the route's start.
    private var hourBeforeSunset: Int64 {
        Sun.times(epochDay: lateDay, origin).sunsetMs! - 60 * 60_000
    }

    func testTheDaylightWarningIsGivenOnceAndRemembered() throws {
        let track = HikeTrack()
        let now = hourBeforeSunset
        track.begin(id: 5, name: "Walk", start: now, restored: [], restoredActiveMs: 0, nowMs: now)
        let g = RouteGuidance(track: track)
        // 10 km on the flat takes two hours: the finish is after sunset, and after civil dusk too.
        g.follow(route(lengthM: 10_000), nowMs: now, zone: utc)
        let events = g.onFix(fix(at(20), now), nowMs: now, zone: utc)
        XCTAssertTrue(g.routeStarted, "recording starts the route at once")
        let warnings = daylightWarnings(events)
        XCTAssertEqual(warnings.count, 1)
        guard case .daylightWarning(let forecast, let dayOffset, let margin) = warnings[0] else { return XCTFail() }
        XCTAssertEqual(dayOffset, 0)
        XCTAssertEqual(margin, 30)
        XCTAssertEqual(forecast.afterSafeSunset, true)
        XCTAssertFalse(events.contains(.darkByFinish), "the dusk alert is folded into the daylight warning")
        XCTAssertEqual(g.daylightAlertState, "5:3")
        // Later fixes, even a re-forecast, don't repeat it.
        let later = g.onFix(fix(at(60), now + 31_000), nowMs: now + 31_000, zone: utc)
        XCTAssertTrue(daylightWarnings(later).isEmpty)
        XCTAssertFalse(later.contains(.darkByFinish))
        // Nor does the app starting again for the same walk.
        let again = RouteGuidance(track: track, daylightAlertState: "5:3")
        again.follow(route(lengthM: 10_000), nowMs: now, zone: utc)
        XCTAssertTrue(daylightWarnings(again.onFix(fix(at(20), now), nowMs: now, zone: utc)).isEmpty)
        // Another walk's flags don't count.
        let other = RouteGuidance(track: track, daylightAlertState: "4:3")
        other.follow(route(lengthM: 10_000), nowMs: now, zone: utc)
        XCTAssertEqual(daylightWarnings(other.onFix(fix(at(20), now), nowMs: now, zone: utc)).count, 1)
    }

    func testNoDaylightAlertBeforeTheWalkHasStarted() {
        let g = RouteGuidance(track: HikeTrack())
        let now = hourBeforeSunset
        g.follow(route(lengthM: 10_000), nowMs: now, zone: utc)
        let events = g.onFix(fix(at(20), now), nowMs: now, zone: utc)
        XCTAssertFalse(g.routeStarted)
        XCTAssertTrue(daylightWarnings(events).isEmpty)
        XCTAssertEqual(g.daylight?.afterSafeSunset, true)
        // Walking 40 m along the route starts it; the forecast is redone at once and the warning given.
        let moved = g.onFix(fix(at(70), now + 5_000), nowMs: now + 5_000, zone: utc)
        XCTAssertTrue(g.routeStarted)
        XCTAssertEqual(daylightWarnings(moved).count, 1)
        XCTAssertEqual(g.daylightAlertState, "-7:3")
    }

    func testStoppingForgetsTheDaylightAlertsOnlyWhenNotRecording() {
        let idle = RouteGuidance(track: HikeTrack(), daylightAlertState: "-7:1")
        idle.follow(route(), nowMs: midday, zone: utc)
        XCTAssertNil(idle.stop(followedRouteId: 7))
        XCTAssertEqual(idle.daylightAlertState, "")

        let track = HikeTrack()
        track.begin(id: 9, name: "Walk", start: midday, restored: [], restoredActiveMs: 0, nowMs: midday)
        let recording = RouteGuidance(track: track, daylightAlertState: "9:1")
        recording.follow(route(), nowMs: midday, zone: utc)
        _ = recording.stop(followedRouteId: 7)
        XCTAssertEqual(recording.daylightAlertState, "9:1")
    }
}

/// The guidance and recording wording, with fixed clock formats.
final class HikeTextTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let day = CivilDate.epochDay(2026, 10, 31)

    /// "HH:mm" and "dd/MM/yyyy" in UTC.
    private var clock: HikeClock {
        HikeClock(zone: utc, time: { ms in
            let minutes = CivilDate.floorDiv(ms, 60_000)
            return String(kMod(Int(minutes / 60), 24)).padStart(2, "0") + ":" + String(kMod(Int(minutes), 60)).padStart(2, "0")
        }, date: { ms in
            let d = CivilDate.fromEpochDay(CivilDate.floorDiv(ms, 86_400_000))
            return String(d.day).padStart(2, "0") + "/" + String(d.month).padStart(2, "0") + "/" + String(d.year)
        })
    }

    private func ms(_ epochDay: Int64, _ hour: Int64, _ minute: Int64) -> Int64 { epochDay * 86_400_000 + (hour * 60 + minute) * 60_000 }

    private func routeFix(remainingM: Double = 1_500, ascent: Double = 120, progress: Double = 0.256, offRouteM: Double = 0,
                          atEnd: Bool = false, next: WaypointAhead? = nil) -> RouteFix {
        RouteFix(segmentIndex: 0, snapped: LatLon(54.0, -3.0), offRouteM: offRouteM, alongM: 500, remainingM: remainingM,
                 remainingAscentM: ascent, routeBearingDeg: 90, progress: progress, nextWaypoint: next, atEnd: atEnd)
    }

    func testFinishTimesSayWhichDay() {
        let now = ms(day, 9, 18)
        XCTAssertEqual(HikeText.finishTime(ms(day, 17, 30), nowMs: now, clock: clock), "17:30")
        XCTAssertEqual(HikeText.finishTime(ms(day + 1, 8, 59), nowMs: now, clock: clock), "tomorrow 08:59")
        XCTAssertEqual(HikeText.finishTime(ms(day + 2, 10, 1), nowMs: now, clock: clock), "02/11/2026 10:01")
    }

    func testGuidanceCardWording() {
        XCTAssertEqual(HikeText.waiting(totalM: 2_000, planningMinutes: 24.4, imperial: false), "2.00 km · planning time 24m · waiting for GPS")
        XCTAssertEqual(HikeText.guidanceStats(routeFix(), remainingMinutes: 18.4, imperial: false), ["1.50 km", "18m", "↑120 m", "25%"])
        XCTAssertEqual(HikeText.guidanceStats(routeFix(), remainingMinutes: nil, imperial: true), ["0.93 mi", "—", "↑394 ft", "25%"])
        XCTAssertEqual(HikeText.guidanceStatLabels, ["To go", "Time", "Climb", "Done"])
        let off = routeFix(offRouteM: 100)
        let north = Geo.destination(off.snapped, bearingDeg: 0, distanceM: 100)
        XCTAssertEqual(HikeText.guidanceStatus(off, offRoute: true, here: north, imperial: false), "Off route by 100 m – route is 180° S")
        XCTAssertEqual(HikeText.guidanceStatus(off, offRoute: true, here: nil, imperial: false), "Off route by 100 m")
        XCTAssertEqual(HikeText.guidanceStatus(routeFix(atEnd: true), offRoute: false, here: nil, imperial: false),
                       "You have reached the end of the route.")
        XCTAssertNil(HikeText.guidanceStatus(routeFix(), offRoute: false, here: nil, imperial: false))
        let stile = WaypointAhead(waypoint: Waypoint(lat: 54.0, lon: -2.99, name: "Stile"), alongRouteM: 250, directM: 240, bearingDeg: 45)
        XCTAssertEqual(HikeText.nextWaypoint(routeFix(next: stile), imperial: false), "Next: Stile in 250 m (045°)")
        XCTAssertNil(HikeText.nextWaypoint(routeFix(), imperial: false))
    }

    func testDaylightLineWording() {
        let now = ms(day, 15, 0)
        let sun = SunTimes(sunriseMs: ms(day, 7, 10), sunsetMs: ms(day, 16, 40), polarDay: false, polarNight: false,
                           civilDuskMs: ms(day, 17, 20))
        func estimate(finish: Int64, afterSafeSunset: Bool?, darkNow: Bool? = false, sunrise: Int64? = nil) -> DaylightEstimate {
            DaylightEstimate(finishMs: finish, remainingMinutes: 60, daylightLeftMs: ms(day, 16, 40) - now, afterSafeSunset: afterSafeSunset,
                             walkBackMinutes: 75, turnBackByMs: ms(day, 14, 55), startByMs: nil, afterCivilDusk: false,
                             darkNow: darkNow, nextSunriseMs: sunrise)
        }
        XCTAssertEqual(HikeText.daylightLine(estimate(finish: ms(day, 16, 0), afterSafeSunset: false), sun: sun, marginMinutes: 30, nowMs: now, clock: clock),
                       "Finish ≈ 16:00 · sunset 16:40")
        XCTAssertEqual(HikeText.daylightLine(estimate(finish: ms(day, 16, 20), afterSafeSunset: true), sun: sun, marginMinutes: 30, nowMs: now, clock: clock),
                       "Finish ≈ 16:20, inside 30 min sunset margin (16:40)")
        XCTAssertEqual(HikeText.daylightLine(estimate(finish: ms(day, 17, 5), afterSafeSunset: true), sun: sun, marginMinutes: 30, nowMs: now, clock: clock),
                       "Finish ≈ 17:05, after sunset (16:40)")
        XCTAssertEqual(HikeText.daylightLine(estimate(finish: ms(day, 18, 0), afterSafeSunset: true, darkNow: true, sunrise: ms(day + 1, 7, 12)),
                                             sun: sun, marginMinutes: 30, nowMs: now, clock: clock),
                       "It's dark now. Sunrise tomorrow 07:12")
        XCTAssertEqual(HikeText.daylightLine(estimate(finish: ms(day, 18, 0), afterSafeSunset: false), sun: nil, marginMinutes: 30, nowMs: now, clock: clock),
                       "No sunset today at this location.")
        XCTAssertEqual(HikeText.daylightLine(estimate(finish: ms(day, 18, 0), afterSafeSunset: nil, darkNow: nil), sun: nil, marginMinutes: 30, nowMs: now, clock: clock),
                       "Daylight times unavailable here.")
        XCTAssertNil(HikeText.daylightLine(nil, sun: sun, marginMinutes: 30, nowMs: now, clock: clock))

        let check = HikeText.daylightCheck(estimate(finish: ms(day, 16, 20), afterSafeSunset: true), sunsetMs: ms(day, 16, 40),
                                           civilDuskMs: ms(day, 17, 20), marginMinutes: 30, nowMs: now, clock: clock)
        XCTAssertEqual(check, "Estimated finish 16:20. Sunset 16:40; 1h 40m of daylight left.\n" +
            "Going back to the start now takes about 1h 15m.\n" +
            "Turn back by 14:55 to be down before sunset with 30 min to spare.\n" +
            "Civil dusk (dark by) 17:20.\n" +
            "Estimate uses route climb, your pace and conditions; allow extra for breaks and poor weather.")
    }

    func testStartByWording() {
        let origin = LatLon(54.0, -3.0)
        func line(_ km: Double) -> [TrackPoint] {
            (0...Int(km * 100)).map { i in
                let p = Geo.destination(origin, bearingDeg: 90, distanceM: Double(i) * 10)
                return TrackPoint(lat: p.lat, lon: p.lon, ele: 100)
            }
        }
        let sun = Sun.times(epochDay: day, origin)
        let morning = ms(day, 9, 0)
        let text = HikeText.startBy(line(10), pace: PaceSettings(), marginMinutes: 30, forMs: morning, clock: clock)
        let startBy = sun.sunsetMs! - 30 * 60_000 - kTruncateL(HikeEstimator.estimate(line(10)).planningMinutes * 60_000)
        XCTAssertEqual(text, "Start by \(clock.time(startBy)) to finish before sunset (\(clock.time(sun.sunsetMs!))) with 30 min to spare.")
        let afternoon = ms(day, 15, 30)
        XCTAssertTrue(HikeText.startBy(line(10), pace: PaceSettings(), marginMinutes: 30, forMs: afternoon, clock: clock)
            .hasSuffix("with 30 min to spare (start-by time has passed)."))
        XCTAssertEqual(HikeText.startBy(line(60), pace: PaceSettings(), marginMinutes: 30, forMs: morning, clock: clock),
                       "No start time today: route is too long to finish before sunset.")
        XCTAssertEqual(HikeText.startBy(Array(line(1).prefix(1)), pace: PaceSettings(), marginMinutes: 30, forMs: morning, clock: clock),
                       "No route timing available.")
        let night = ms(day, 22, 0)
        XCTAssertTrue(HikeText.startBy(line(10), pace: PaceSettings(), marginMinutes: 30, forMs: night, clock: clock)
            .hasPrefix("It's dark now. Sunrise tomorrow "))
    }

    func testAlertWording() {
        XCTAssertEqual(HikeText.offRouteAlert(offRouteM: 85, backBearingDeg: 200, imperial: false),
                       "85 m from the route. Nearest route point is 200° (SSW).")
        let forecast = DaylightEstimate(finishMs: ms(day, 18, 5), remainingMinutes: 120, daylightLeftMs: nil, afterSafeSunset: true,
                                        walkBackMinutes: nil, turnBackByMs: nil, startByMs: nil, afterCivilDusk: true, darkNow: false,
                                        nextSunriseMs: nil)
        XCTAssertEqual(HikeText.daylightWarning(forecast, finishDayOffset: 0, marginMinutes: 30, clock: clock),
                       "Estimated finish 18:05 is after the sunset safety margin (30 min).")
        XCTAssertEqual(HikeText.daylightWarning(forecast, finishDayOffset: 1, marginMinutes: 60, clock: clock),
                       "Estimated finish tomorrow 18:05 is after the sunset safety margin (60 min).")
        XCTAssertEqual(HikeText.daylightWarning(forecast, finishDayOffset: 2, marginMinutes: 0, clock: clock),
                       "Estimated finish 31/10/2026 18:05 is after the sunset safety margin (0 min).")
        var dark = forecast
        dark.darkNow = true
        dark.nextSunriseMs = ms(day + 1, 7, 12)
        XCTAssertEqual(HikeText.daylightWarning(dark, finishDayOffset: 0, marginMinutes: 30, clock: clock), "It's dark now. Sunrise 07:12.")
        dark.nextSunriseMs = nil
        XCTAssertEqual(HikeText.daylightWarning(dark, finishDayOffset: 0, marginMinutes: 30, clock: clock),
                       "It's dark now. No sunrise time available.")
    }

    func testGoToWording() {
        let here = LatLon(54.0, -3.0)
        let target = Geo.destination(here, bearingDeg: 0, distanceM: 1_000)
        XCTAssertEqual(HikeText.goToDetail(here: here, target: target, imperial: false), "1.00 km · 000° N (straight line, not a path)")
        XCTAssertEqual(HikeText.goToDetail(here: nil, target: target, imperial: false), "Waiting for GPS to give bearing and distance")
        XCTAssertEqual(HikeText.place(LatLon(54.4541, -3.2117)), OsGrid.fromWgs84(LatLon(54.4541, -3.2117))!.format(8))
        XCTAssertEqual(HikeText.place(LatLon(45.0, 7.0)), Units.latLon(45.0, 7.0))
    }
}
