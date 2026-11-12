import XCTest
@testable import TrailMind

final class VehicleDetectorTests: XCTestCase {
    private typealias Verdict = VehicleDetector.Verdict

    private let detector = VehicleDetector()
    private var t: Int64 = 0
    private var lat = 51.8

    /// One fix every `dtS` seconds, moving north at `mps` and reporting `reported` (nil: no Doppler speed).
    private func fix(_ mps: Double, dtS: Int = 2, reported: Double?, accuracyM: Float? = 8) -> Verdict {
        t += Int64(dtS) * 1_000
        lat += mps * Double(dtS) / 111_320.0
        return detector.onFix(t, lat, -2.5, accuracyM: accuracyM, speedMps: reported)
    }

    /// As above, reporting the true speed (the Kotlin default `reported = mps`).
    private func fix(_ mps: Double, dtS: Int = 2, accuracyM: Float? = 8) -> Verdict {
        fix(mps, dtS: dtS, reported: mps, accuracyM: accuracyM)
    }

    private func drive(_ mps: Double, _ seconds: Int, reported: Bool = true) -> [Verdict] {
        (0..<(seconds / 2)).map { _ in fix(mps, dtS: 2, reported: reported ? mps : nil) }
    }

    func testWalkingNeverTriggers() {
        XCTAssertTrue(drive(1.4, 600).allSatisfy { $0 == .onFoot })
        XCTAssertNil(detector.runStartedMs)
    }

    func testAHardRunDownhillIsNotAVehicle() {
        XCTAssertTrue(drive(4.5, 300).allSatisfy { $0 == .onFoot })
    }

    func testDrivingAwayIsFoundAfterHalfAMinute() throws {
        _ = drive(1.3, 60)
        let verdicts = drive(14.0, 60)
        XCTAssertEqual(verdicts.first, .maybe)
        let first = try XCTUnwrap(verdicts.firstIndex(of: .vehicle))
        // 2 s apart: the fast run starts at the first fast fix and is confirmed 30 s later.
        XCTAssertEqual(first, 15)
        XCTAssertTrue(verdicts.dropFirst(first).allSatisfy { $0 == .vehicle })
    }

    func testTheRunStartIsWhereTheDriveBegan() {
        _ = drive(1.3, 60)
        let startOfDrive = t + 2_000
        _ = drive(14.0, 40)
        XCTAssertEqual(detector.runStartedMs, startOfDrive)
    }

    func testSpeedIsWorkedOutFromPositionsWhenTheReceiverGivesNone() {
        _ = drive(1.3, 30, reported: false)
        let verdicts = drive(14.0, 60, reported: false)
        XCTAssertTrue(verdicts.contains(.vehicle))
    }

    func testAShortBurstIsHeldThenReleased() {
        _ = drive(1.3, 30)
        let burst = drive(9.0, 14)
        XCTAssertTrue(burst.allSatisfy { $0 == .maybe })
        // Back to walking: the run is over once the dip lasts longer than the allowance.
        let after = drive(1.3, 20)
        XCTAssertEqual(after.last, .onFoot)
        XCTAssertNil(detector.runStartedMs)
    }

    func testASingleSpikeIsNotEnough() {
        _ = drive(1.3, 30)
        XCTAssertEqual(fix(1.3, reported: 25.0), .maybe)
        XCTAssertEqual(fix(1.3), .maybe)
        let rest = drive(1.3, 30)
        XCTAssertEqual(rest.last, .onFoot)
    }

    func testAQueueOrJunctionDoesNotEndTheRun() {
        _ = drive(12.0, 20)
        let stopped = drive(0.0, 6)
        XCTAssertTrue(stopped.allSatisfy { $0 == .maybe })
        let verdicts = drive(12.0, 30)
        XCTAssertTrue(verdicts.contains(.vehicle))
    }

    func testALongStopEndsTheRun() {
        _ = drive(12.0, 20)
        let verdicts = drive(0.0, 20)
        XCTAssertEqual(verdicts.last, .onFoot)
        // And the next drive has to last half a minute of its own.
        XCTAssertEqual(drive(12.0, 20).last, .maybe)
    }

    func testPoorFixesAreIgnored() {
        _ = drive(1.3, 20)
        // A wild speed on a fix with a 120 m error circle starts nothing.
        XCTAssertEqual(fix(1.3, reported: 30.0, accuracyM: 120), .onFoot)
        XCTAssertNil(detector.runStartedMs)
        // Nor does one end a real run.
        _ = drive(14.0, 10)
        XCTAssertEqual(fix(1.3, reported: 0.0, accuracyM: 120), .maybe)
        XCTAssertNotNil(detector.runStartedMs)
    }

    func testNoFixesForAWhileBreaksTheRun() {
        _ = drive(14.0, 20)
        // A minute of silence (a tunnel, GPS off): the run can't carry across it, so a new one starts here.
        let verdict = fix(14.0, dtS: 60)
        XCTAssertEqual(verdict, .maybe)
        XCTAssertEqual(detector.runStartedMs, t)
    }

    func testStandingStillWithAStuckSpeedReadingIsNotAVehicle() {
        // A receiver that reports speed while the position doesn't move: the distance test refuses it.
        for _ in 0..<40 {
            t += 2_000
            XCTAssertNotEqual(detector.onFix(t, 51.8, -2.5, accuracyM: 8, speedMps: 9.0), .vehicle)
        }
    }

    func testResetStartsAgain() {
        _ = drive(14.0, 50)
        detector.reset()
        XCTAssertEqual(fix(1.3), .onFoot)
    }
}
