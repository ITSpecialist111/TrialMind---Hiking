import XCTest
@testable import TrailMind

final class HeadingGateTests: XCTestCase {
    func testFinalRateLimitedHeadingIsDeliveredWithoutAnotherSensorEvent() {
        let gate = HeadingGate()
        XCTAssertTrue(gate.accept(0.0, 0))
        XCTAssertFalse(gate.accept(45.0, 20))
        XCTAssertEqual(47, gate.pendingDelayMs(20))
        XCTAssertFalse(gate.accept(90.0, 60))
        XCTAssertNil(gate.flush(66))
        XCTAssertEqual(90.0, gate.flush(67))
        XCTAssertNil(gate.pendingDelayMs(67))
        XCTAssertNil(gate.flush(100))
    }

    func testReturningToDrawnHeadingCancelsPendingTurn() {
        let gate = HeadingGate()
        XCTAssertTrue(gate.accept(359.5, 0))
        XCTAssertFalse(gate.accept(20.0, 20))
        XCTAssertFalse(gate.accept(0.0, 40))
        XCTAssertNil(gate.flush(67))
    }

    func testHalfDegreeStepsReachFinalHeading() {
        let gate = HeadingGate()
        XCTAssertTrue(gate.accept(350.0, 0))
        var drawn = 350.0
        for step in 1...80 {
            let heading = (350.0 + Double(step) * 0.5).truncatingRemainder(dividingBy: 360.0)
            if gate.accept(heading, Int64(step) * 10) { drawn = heading }
        }
        drawn = gate.flush(867) ?? drawn
        XCTAssertEqual(30.0, drawn)
    }

    func testResetAcceptsFirstReadingAndDropsPendingWork() {
        let gate = HeadingGate()
        XCTAssertTrue(gate.accept(10.0, 100))
        XCTAssertFalse(gate.accept(30.0, 120))
        gate.reset()
        XCTAssertNil(gate.flush(200))
        XCTAssertTrue(gate.accept(10.5, 200))
    }

    func testFirstHeadingAndStationaryNoise() {
        let gate = HeadingGate()
        XCTAssertTrue(gate.accept(90.0, 0))
        XCTAssertFalse(gate.accept(90.0, 1000))
        XCTAssertFalse(gate.accept(90.9, 2000))
        XCTAssertFalse(gate.accept(89.1, 3000))
        XCTAssertTrue(gate.accept(91.0, 4000))
    }

    func testThresholdAccumulatesFromLastAcceptedHeading() {
        let gate = HeadingGate()
        XCTAssertTrue(gate.accept(10.0, 0))
        XCTAssertFalse(gate.accept(10.4, 100))
        XCTAssertFalse(gate.accept(10.8, 200))
        XCTAssertTrue(gate.accept(11.2, 300))
    }

    func testWrapsAcrossNorthInBothDirections() {
        let gate = HeadingGate()
        XCTAssertTrue(gate.accept(359.5, 0))
        XCTAssertFalse(gate.accept(0.4, 100))
        XCTAssertTrue(gate.accept(0.5, 200))
        XCTAssertFalse(gate.accept(360.5, 300))
        XCTAssertTrue(gate.accept(359.5, 400))
        XCTAssertFalse(gate.accept(-0.5, 500))
    }

    func testRateCapDoesNotConsumeRejectedHeading() {
        let gate = HeadingGate()
        XCTAssertTrue(gate.accept(0.0, 0))
        XCTAssertFalse(gate.accept(45.0, 66))
        XCTAssertTrue(gate.accept(45.0, 67))
        XCTAssertFalse(gate.accept(90.0, 133))
        XCTAssertTrue(gate.accept(90.0, 134))
    }

    func testSustainedTurningIsCappedAtFifteenUpdatesPerSecond() {
        let gate = HeadingGate()
        let updates = (Int64(0)..<1000).filter { gate.accept(Double($0), $0) }.count
        XCTAssertEqual(15, updates)
    }

    func testInvalidReadingsDoNotChangeAcceptedState() {
        let gate = HeadingGate()
        XCTAssertFalse(gate.accept(.nan, 0))
        XCTAssertFalse(gate.accept(.infinity, 10))
        XCTAssertTrue(gate.accept(10.0, 20))
        XCTAssertFalse(gate.accept(-.infinity, 100))
        XCTAssertTrue(gate.accept(11.0, 100))
    }
}
