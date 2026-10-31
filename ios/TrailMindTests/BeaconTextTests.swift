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
}
