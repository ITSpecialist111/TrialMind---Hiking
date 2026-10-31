import XCTest
@testable import TrailMind

final class MenuMotionTests: XCTestCase {
    func testTapsAndVerticalScrollsDoNotStartDragging() {
        XCTAssertFalse(MenuMotion.shouldDrag(-7, 0, 8, 1))
        XCTAssertFalse(MenuMotion.shouldDrag(-30, 80, 8, 1))
        XCTAssertFalse(MenuMotion.shouldDrag(-60, 40, 8, 1))
        XCTAssertTrue(MenuMotion.shouldDrag(-61, 40, 8, 1))
    }

    func testClosedOpensRightAndOpenClosesLeft() {
        XCTAssertTrue(MenuMotion.shouldDrag(50, 0, 8, 0))
        XCTAssertFalse(MenuMotion.shouldDrag(-50, 0, 8, 0))
        XCTAssertTrue(MenuMotion.shouldDrag(-50, 0, 8, 1))
        XCTAssertFalse(MenuMotion.shouldDrag(50, 0, 8, 1))
        XCTAssertTrue(MenuMotion.shouldDrag(50, 0, 8, 0.5))
        XCTAssertTrue(MenuMotion.shouldDrag(-50, 0, 8, 0.5))
    }

    func testDragFollowsFingerAndClampsAtEdges() {
        XCTAssertEqual(0.75, try MenuMotion.fraction(1, -100, 400))
        XCTAssertEqual(0.25, try MenuMotion.fraction(0, 100, 400))
        XCTAssertEqual(0, try MenuMotion.fraction(1, -800, 400))
        XCTAssertEqual(1, try MenuMotion.fraction(0, 800, 400))
        XCTAssertThrowsError(try MenuMotion.fraction(0, 100, 0)) { XCTAssertTrue($0 is MenuMotion.InvalidWidth) }
    }

    func testSlowDragSettlesAtHalfwayAndFlickFollowsDirection() {
        XCTAssertFalse(MenuMotion.settleOpen(0.49, 0, 600))
        XCTAssertTrue(MenuMotion.settleOpen(0.5, 0, 600))
        XCTAssertTrue(MenuMotion.settleOpen(0.1, 600, 600))
        XCTAssertFalse(MenuMotion.settleOpen(0.9, -600, 600))
        XCTAssertFalse(MenuMotion.settleOpen(0.1, 599, 600))
    }
}
