import XCTest
@testable import TrailMind

final class TripReadinessTests: XCTestCase {
    func testReturnTimeRoundsUp() {
        XCTAssertEqual(TripReadiness.defaultReturnMs(10 * 3_600_000, planningMinutes: 40.0), 11 * 3_600_000)
        XCTAssertEqual(TripReadiness.defaultReturnMs(10 * 3_600_000 + 1, planningMinutes: 0.0), 10 * 3_600_000 + 15 * 60_000)
    }

    func testFollowUpStaysThirtyRealMinutesAcrossUkClockChanges() throws {
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        // 01:45 on 25 October 2026 happens twice; withEarlierOffsetAtOverlap() is the first, in BST (+01:00).
        var bst = Calendar(identifier: .gregorian)
        bst.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 3600))
        let starts = [
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 0, minute: 45))),
            try XCTUnwrap(bst.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 1, minute: 45))),
        ]
        let expected = ["02:15", "01:15"]
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = london
        clock.dateFormat = "HH:mm"
        for (index, start) in starts.enumerated() {
            let due = Int64((start.timeIntervalSince1970 * 1000).rounded())
            let next = TripReadiness.followUpMs(due)
            XCTAssertEqual(next - due, 30 * 60_000)
            XCTAssertEqual(clock.string(from: Date(timeIntervalSince1970: Double(next) / 1000.0)), expected[index])
        }
    }

    func testSummaryAndCoverage() {
        XCTAssertEqual(TripReadiness.summary(ready: 5, total: 7), "5 of 7 ready")
        XCTAssertEqual(TripReadiness.coverage(hits: 0, samples: 0), 0)
        XCTAssertEqual(TripReadiness.coverage(hits: 3, samples: 4), 75)
        let samples = TripReadiness.sampleRoute([LatLon(51.8, -2.5), LatLon(51.8, -2.49)], spacingM: 100.0)
        XCTAssertTrue(samples.count > 2)
        XCTAssertEqual(samples.first?.lon, -2.5)
        XCTAssertEqual(samples[samples.count - 1].lon, -2.49, accuracy: 0.000001)
        XCTAssertTrue(TripReadiness.sampleRoute([LatLon(51.8, -2.5), LatLon(51.8, -2.5)]).count >= 2)
    }

    func testMessageIncludesEvidenceAndHandlesNoFix() {
        let text = TripReadiness.sms(routeName: "New Fancy", location: LatLon(51.8, -2.5), time: "17:30", batteryPercent: 42)
        XCTAssertTrue(text.contains("New Fancy"))
        XCTAssertTrue(text.contains("Grid "))
        XCTAssertTrue(text.contains("mlat=51.80000&mlon=-2.50000"))
        XCTAssertTrue(text.contains("17:30"))
        XCTAssertTrue(text.contains("42%"))
        XCTAssertTrue(TripReadiness.sms(routeName: "", location: nil, time: "18:00", batteryPercent: 5).contains("No location fix"))
        XCTAssertTrue(TripReadiness.sms(routeName: "", location: nil, time: "18:00", batteryPercent: -1).contains("Battery unavailable"))
    }
}
