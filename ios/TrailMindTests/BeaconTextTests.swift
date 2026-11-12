import XCTest
@testable import TrailMind

final class BeaconTextTests: XCTestCase {
    func testWarningLinesAreTheOnesAndroidShowsInRed() {
        XCTAssertTrue(BeaconText.warns("⚠ Likely finish 18:40 is AFTER sunset (17:52). Start earlier, shorten, or carry a head torch."))
        XCTAssertTrue(BeaconText.warns("⚠ Only 25 min of daylight margin (sunset 17:52). Carry a head torch."))
        XCTAssertTrue(BeaconText.warns("⚠️ Gusts of 85 km/h: dangerous on exposed ground. Consider a lower route."))
        XCTAssertTrue(BeaconText.warns("You'd finish after Sunset if you start late."))
        XCTAssertTrue(BeaconText.warns("It's DARK now. Sunrise tomorrow 07:01."))
        // Android matches "dark" anywhere, place names included.
        XCTAssertTrue(BeaconText.warns("Waypoints: Darkwater Bridge, Scafell Pike."))
        XCTAssertFalse(BeaconText.warns("Sunset 17:52; expected finish ~15:10."))
        XCTAssertFalse(BeaconText.warns("Start NY 21571 07155; finish NY 21000 08000."))
        XCTAssertFalse(BeaconText.warns("Tell someone your route and return time. In the UK call 999 or 112, ask for Police, then Mountain Rescue."))
        XCTAssertFalse(BeaconText.warns(" ⚠ indented"))
        XCTAssertFalse(BeaconText.warns(""))
    }

    func testTheRealBriefingMarksItsOwnWarnings() throws {
        let points = (0..<40).map { i in
            TrackPoint(lat: 54.45 + Double(i) * 0.002, lon: -3.21, ele: 100 + Double(i) * 22)
        }
        let estimate = HikeEstimator.estimate(points)
        let start = points[0].latLon()
        // A late start in November: the finish comes after sunset.
        let startMs: Int64 = 1_794_931_200_000 // 2026-11-17 16:00 UTC
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let input = BriefingInput(routeName: "Late walk", estimate: estimate, start: start, end: points[39].latLon(),
                                  maxEleM: 958, waypointNames: [],
                                  sun: Sun.times(epochDay: CivilDate.localEpochDay(startMs, zone), start),
                                  plannedStartMs: startMs, zone: zone)
        let lines = Briefing.ruleBased(input)
        let warnings = lines.filter(BeaconText.warns)
        XCTAssertTrue(warnings.contains { $0.hasPrefix("⚠ Likely finish") }, "\(lines)")
        XCTAssertFalse(warnings.contains { $0.hasPrefix("Tell someone") })
        XCTAssertEqual("•  " + lines[0], BeaconText.bullet(lines[0]))
    }

    func testTheWriteUpLosesHeadingsAndRulesButKeepsItsWords() {
        let raw = """

            ## Your briefing


            **Timing:** set off by 09:00 and allow 6h 10m.
            ---
            - Head torch
            * Map and compass
            ___
            # Emergency
            Call 999 or 112.

            """
        XCTAssertEqual("""
            Your briefing

            **Timing:** set off by 09:00 and allow 6h 10m.

            - Head torch
            * Map and compass

            Emergency
            Call 999 or 112.
            """, BeaconText.tidyWriteUp(raw))
        XCTAssertEqual("Plain text.", BeaconText.tidyWriteUp("  Plain text.\r\n\r\n"))
        XCTAssertEqual("", BeaconText.tidyWriteUp("---\n\n###"))
    }

    func testTheModelIsToldToKeepToTheFacts() {
        XCTAssertTrue(BeaconText.writeUpInstructions.contains("Use only the facts you are given."))
        XCTAssertTrue(BeaconText.writeUpInstructions.contains("keep every number and time exactly as written"))
    }

    // MARK: Start by

    private let utc = TimeZone(identifier: "UTC")!
    private let pace = PaceSettings()

    /// About 8.7 km north with 860 m of climb, from Seathwaite towards Scafell Pike.
    private var climb: [TrackPoint] {
        (0..<40).map { i in TrackPoint(lat: 54.45 + Double(i) * 0.002, lon: -3.21, ele: 100 + Double(i) * 22) }
    }

    private func startBy(_ points: [TrackPoint], _ forMs: Int64, margin: Int = 30) -> String {
        BeaconText.startBy(points, pace: pace, marginMinutes: margin, forMs: forMs, zone: utc,
                           clock: { "c\($0)" }, finish: { "f\($0)" })
    }

    private func ms(_ year: Int64, _ month: Int, _ day: Int, _ hour: Int64, _ minute: Int64 = 0) -> Int64 {
        CivilDate.epochDay(year, month, day) * CivilDate.msPerDay + (hour * 60 + minute) * 60_000
    }

    func testTheStartByTimeLeavesTheMarginBeforeSunset() throws {
        let points = climb
        let forMs = ms(2026, 6, 21, 8)
        let sun = Sun.times(epochDay: CivilDate.epochDay(2026, 6, 21), points[0].latLon())
        let sunset = try XCTUnwrap(sun.sunsetMs)
        let plan = HikeEstimator.estimate(points, pace: pace).planningMinutes
        let expected = sunset - 30 * 60_000 - kTruncateL(plan * 60_000)
        XCTAssertEqual("Start by c\(expected) to finish before sunset (c\(sunset)) with 30 min to spare.", startBy(points, forMs))
        XCTAssertEqual("Start by c\(expected + 30 * 60_000) to finish before sunset (c\(sunset)) with 0 min to spare.",
                       startBy(points, forMs, margin: 0))
    }

    func testALateStartIsToldTheTimeHasPassed() {
        let text = startBy(climb, ms(2026, 6, 21, 20))
        XCTAssertTrue(text.hasPrefix("Start by c"), text)
        XCTAssertTrue(text.hasSuffix("with 30 min to spare (start-by time has passed)."), text)
    }

    func testInTheDarkItGivesTomorrowsSunrise() throws {
        let points = climb
        let sunrise = try XCTUnwrap(Sun.times(epochDay: CivilDate.epochDay(2026, 6, 22), points[0].latLon()).sunriseMs)
        XCTAssertEqual("It's dark now. Sunrise f\(sunrise).", startBy(points, ms(2026, 6, 21, 23, 30)))
        // Before dawn it's today's sunrise that comes next.
        let today = try XCTUnwrap(Sun.times(epochDay: CivilDate.epochDay(2026, 12, 21), points[0].latLon()).sunriseMs)
        XCTAssertEqual("It's dark now. Sunrise f\(today).", startBy(points, ms(2026, 12, 21, 5)))
    }

    func testARouteTooLongForTheDayHasNoStartTime() {
        let long = (0..<400).map { i in TrackPoint(lat: 50.0 + Double(i) * 0.01, lon: -3.21, ele: 100) }
        XCTAssertEqual("No start time today: route is too long to finish before sunset.", startBy(long, ms(2026, 12, 21, 10)))
    }

    func testThePolesAndShortRoutesSayWhyThereIsNoTime() {
        let arctic = [TrackPoint(lat: 78.2, lon: 15.6, ele: 10), TrackPoint(lat: 78.21, lon: 15.6, ele: 40)]
        XCTAssertEqual("No sunset today at this location.", startBy(arctic, ms(2026, 6, 21, 12)))
        XCTAssertEqual("It's dark now. No sunrise time available.", startBy(arctic, ms(2026, 12, 21, 12)))
        XCTAssertEqual("No route timing available.", startBy([TrackPoint(lat: 54.45, lon: -3.21)], ms(2026, 6, 21, 8)))
        XCTAssertEqual("No route timing available.", startBy([], ms(2026, 6, 21, 8)))
    }

    func testThePlannedStartOpensAtTheNextQuarterHour() {
        XCTAssertEqual(1_800_000, BeaconText.nextQuarterHour(1_000_000))
        XCTAssertEqual(1_800_000, BeaconText.nextQuarterHour(900_000))
        XCTAssertEqual(ms(2026, 10, 31, 11, 30), BeaconText.nextQuarterHour(ms(2026, 10, 31, 11, 19) + 21_787))
    }
}
