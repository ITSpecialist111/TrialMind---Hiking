import XCTest
@testable import TrailMind

final class LocationToolsTests: XCTestCase {
    func testThreeWordsExpireAndAreNeverSharedAfterMovingSquare() {
        XCTAssertTrue(ThreeWordAddress.canShare(1_000, 61_000, 61_000, true))
        XCTAssertFalse(ThreeWordAddress.canShare(1_000, 61_001, 61_001, true))
        XCTAssertFalse(ThreeWordAddress.canShare(60_000, 60_000, 61_000, false))
        XCTAssertFalse(ThreeWordAddress.canShare(62_000, 61_000, 61_000, true))
        XCTAssertFalse(ThreeWordAddress.canShare(60_000, 62_000, 61_000, true))
    }

    func testThreeWordsAreNotCoordinatesOrUrls() {
        XCTAssertEqual("filled.count.soap", ThreeWordAddress.normalize(" ///Filled.Count.Soap "))
        for bad in ["51.50,-2.0", "one.two", "one.two.three.four", "https://w3w.co/filled.count.soap", "one.2.three", "one..three"] {
            XCTAssertNil(ThreeWordAddress.normalize(bad))
        }
    }

    func testSkyCardinalsAndZenith() throws {
        let north = try XCTUnwrap(SatelliteSky.project(0.0, 0.0))
        XCTAssertEqual(0.0, north.x, accuracy: 1e-9); XCTAssertEqual(-1.0, north.y, accuracy: 1e-9)
        let east = try XCTUnwrap(SatelliteSky.project(90.0, 0.0))
        XCTAssertEqual(1.0, east.x, accuracy: 1e-9); XCTAssertEqual(0.0, east.y, accuracy: 1e-9)
        XCTAssertEqual(0.0, try XCTUnwrap(SatelliteSky.project(225.0, 90.0)).x, accuracy: 1e-9)
        XCTAssertNil(SatelliteSky.project(.nan, 0.0))
        XCTAssertNil(SatelliteSky.project(0.0, -1.0))
    }

    func testEmergencyWordsNeverReplaceCoordinatesOrBreakSingleSms() throws {
        #if CORE_PORTS_MERGED
        let here = LatLon(51.521251, -0.203586)
        let text = SosText.contact("I need help", location: here, altitudeM: 24, time: "12:34", batteryPercent: 67,
                                   words: "filled.count.soap")
        XCTAssertTrue(text.contains("///filled.count.soap"))
        XCTAssertTrue(text.contains("51.52125,-0.20359"))
        XCTAssertTrue(text.utf16.count <= SosText.maxChars)
        XCTAssertTrue(SosText.isGsm7(text))
        let emergency = SosText.emergency("I need help", location: here, time: "12:34", words: "filled.count.soap")
        XCTAssertTrue(emergency.contains("Grid ") && emergency.contains("lat ") && emergency.contains("///filled.count.soap"))
        XCTAssertTrue(!SosText.contact("Help", location: nil, altitudeM: nil, time: "12:34", batteryPercent: 50,
                                       words: "filled.count.soap").contains("///"))
        #else
        throw XCTSkip("Needs SosText (frontier/SosText.kt), which the port/core-frontier branch ports: drop this #if once merged")
        #endif
    }
}
