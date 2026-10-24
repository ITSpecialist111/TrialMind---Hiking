import XCTest
@testable import TrailMind

final class LocationTextTests: XCTestCase {
    func testShareIncludesFixTimeAccuracyAndLocaleIndependentCoordinates() throws {
        let text = try XCTUnwrap(LocationText.share(latitude: 51.5, longitude: -2.5, accuracy: 8, timestamp: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(text.contains("51.500000, -2.500000"))
        XCTAssertTrue(text.contains("1970-01-01T00:00:00Z"))
        XCTAssertTrue(text.contains("+/-8 m"))
        XCTAssertTrue(text.contains("?ll=51.500000,-2.500000"))
    }

    func testInvalidPositionCannotBeShared() {
        XCTAssertNil(LocationText.share(latitude: .nan, longitude: 0, accuracy: 1, timestamp: Date()))
        XCTAssertNil(LocationText.share(latitude: 91, longitude: 0, accuracy: 1, timestamp: Date()))
        XCTAssertNil(LocationText.share(latitude: 0, longitude: 181, accuracy: 1, timestamp: Date()))
        XCTAssertNil(LocationText.share(latitude: 0, longitude: 0, accuracy: -1, timestamp: Date()))
    }
}
