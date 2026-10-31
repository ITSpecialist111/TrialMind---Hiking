import XCTest
@testable import TrailMind

final class RenewalPromptTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        return calendar
    }

    /// `LocalDateTime.parse(text).atZone(london)` in epoch milliseconds, for "yyyy-MM-ddTHH:mm".
    private func ms(_ text: String) -> Int64 {
        let parts = text.split(whereSeparator: { "-T:".contains($0) }).map { Int($0)! }
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))!
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    func testAsksTwoHoursAheadInTheDaytime() {
        XCTAssertEqual(RenewalPrompt.at(ms("2026-09-28T18:00"), london), ms("2026-09-28T16:00"))
        XCTAssertEqual(RenewalPrompt.at(ms("2026-09-28T09:00"), london), ms("2026-09-28T07:00"))
        XCTAssertEqual(RenewalPrompt.at(ms("2026-09-28T22:59"), london), ms("2026-09-28T20:59"))
    }

    func testMovesOvernightQuestionsToTheEveningBefore() {
        XCTAssertEqual(RenewalPrompt.at(ms("2026-09-28T08:30"), london), ms("2026-09-27T20:00"))
        XCTAssertEqual(RenewalPrompt.at(ms("2026-09-28T23:30"), london), ms("2026-09-28T20:00"))
        XCTAssertEqual(RenewalPrompt.at(ms("2026-09-28T01:00"), london), ms("2026-09-27T20:00"))
        XCTAssertEqual(RenewalPrompt.at(ms("2026-09-28T02:00"), london), ms("2026-09-27T20:00"))
    }

    func testNeverAsksOvernightOrLateAcrossAClockChange() {
        var expiry = ms("2026-10-23T00:00")
        let end = ms("2026-10-27T00:00")
        while expiry < end {
            let at = RenewalPrompt.at(expiry, london)
            let time = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(at) / 1000))
            let instant = Date(timeIntervalSince1970: Double(expiry) / 1000)
            XCTAssertTrue(at <= expiry - RenewalPrompt.leadMs, "prompt after lead for \(instant)")
            XCTAssertTrue(expiry - at <= 14 * 3_600_000, "prompt too early for \(instant)")
            XCTAssertTrue(time.hour! >= 7 && time.hour! < 21, "overnight prompt \(time.hour!):\(time.minute!)")
            expiry += 7 * 60_000
        }
    }

    func testDownloadsReusePremiumOnlyWithTwentyHoursLeft() {
        let now: Int64 = 10_000_000_000
        let hour: Int64 = 3_600_000
        XCTAssertTrue(TilePolicy.premiumReusable(now, now))
        XCTAssertTrue(TilePolicy.premiumReusable(now - 4 * hour, now))
        XCTAssertFalse(TilePolicy.premiumReusable(now - 4 * hour - 1, now))
        XCTAssertFalse(TilePolicy.premiumReusable(now - 23 * hour, now))
        XCTAssertFalse(TilePolicy.premiumReusable(now + 1, now))
        XCTAssertFalse(TilePolicy.premiumReusable(0, now))
    }
}
