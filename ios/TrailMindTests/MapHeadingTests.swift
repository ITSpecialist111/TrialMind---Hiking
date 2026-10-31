import XCTest
@testable import TrailMind

final class MapHeadingTests: XCTestCase {
    private let compass = MapHeading.Reading(10.0, 10_000)

    private func course(speed: Double = 1.0, accuracy: Double = 5.0, bearingAccuracy: Double? = 10.0,
                        at: Int64 = 10_000) -> MapHeading.Course {
        MapHeading.Course(MapHeading.Reading(90.0, at), speed, accuracy, bearingAccuracy, 0.1)
    }

    func testWalkingUsesCourseEvenWhenCompassClaimsAccuracy() {
        XCTAssertEqual(MapHeading.Result(90.0, .course), MapHeading.choose(10_000, compass, true, course()))
    }

    func testStoppedOrInaccurateGpsUsesCompass() {
        for gps in [course(speed: 0.79), course(accuracy: 25.01), course(bearingAccuracy: 25.01),
                    course(speed: 1.19, bearingAccuracy: nil)] {
            XCTAssertEqual(MapHeading.Source.compass, MapHeading.choose(10_000, compass, true, gps).source)
        }
    }

    func testStaleOrDisturbedSensorsNeverLookLive() {
        XCTAssertNil(MapHeading.choose(12_001, compass, true, nil).degrees)
        XCTAssertNil(MapHeading.choose(10_000, compass, false, course(speed: 0.0)).degrees)
        XCTAssertNil(MapHeading.choose(15_001, compass, true, course()).degrees)
        XCTAssertNil(MapHeading.choose(9_999, compass, true, course()).degrees)
    }

    func testExactThresholdsAndRecovery() {
        XCTAssertEqual(MapHeading.Source.course,
                       MapHeading.choose(15_000, nil, false, course(speed: 0.8, accuracy: 25.0, bearingAccuracy: 25.0)).source)
        XCTAssertEqual(MapHeading.Source.compass, MapHeading.choose(12_000, compass, true, nil).source)
        XCTAssertEqual(MapHeading.Source.course, MapHeading.choose(10_000, nil, false, course(speed: 1.2, bearingAccuracy: nil)).source)
    }

    func testNonFiniteDataRejected() {
        XCTAssertNil(MapHeading.choose(10_000, MapHeading.Reading(.nan, 10_000), true, course(accuracy: .nan)).degrees)
    }
}
