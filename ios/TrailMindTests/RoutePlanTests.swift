import XCTest
@testable import TrailMind

final class RoutePlanTests: XCTestCase {
    private let start = LatLon(51.7834, -2.53921)
    private let middle = LatLon(51.784, -2.54)
    private let end = LatLon(51.785, -2.541)

    func testJoinsSnappedLegsAndKeepsHeights() throws {
        let plan = RoutePlan()
        XCTAssertTrue(plan.add(start))
        XCTAssertTrue(plan.add(middle))
        XCTAssertTrue(plan.replaceLeg(0, [TrackPoint(lat: start.lat, lon: start.lon, ele: 200.0), TrackPoint(lat: 51.7837, lon: -2.5401, ele: 210.0),
                                          TrackPoint(lat: middle.lat, lon: middle.lon, ele: 220.0)]))
        XCTAssertTrue(plan.add(end))
        XCTAssertTrue(plan.replaceLeg(1, [TrackPoint(lat: middle.lat, lon: middle.lon, ele: 220.0), TrackPoint(lat: end.lat, lon: end.lon, ele: 230.0)]))
        XCTAssertEqual(plan.line.count, 4)
        XCTAssertEqual(plan.line[2].ele, 220.0)
        XCTAssertTrue(plan.legs.allSatisfy { $0.snapped })
        XCTAssertTrue(plan.legs.allSatisfy { $0.parts.count == 1 && $0.parts[0].points == $0.points })
        XCTAssertTrue(plan.estimate(try PaceSettings(flatSpeedKmh: 4.5)).ascentM > 0)
        XCTAssertTrue(plan.estimate(try PaceSettings(flatSpeedKmh: 4.5)).planningMinutes > 0)
    }

    func testUndoClearAndLoop() {
        let plan = RoutePlan()
        XCTAssertTrue(plan.add(start))
        XCTAssertFalse(plan.backToStart())
        XCTAssertTrue(plan.add(middle))
        XCTAssertTrue(plan.backToStart())
        XCTAssertTrue(plan.isLoop)
        XCTAssertEqual(plan.line.count, 3)
        XCTAssertFalse(plan.add(end))
        XCTAssertTrue(plan.undo())
        XCTAssertFalse(plan.isLoop)
        XCTAssertEqual(plan.controlPoints.count, 2)
        plan.clear()
        XCTAssertTrue(plan.line.isEmpty)
        XCTAssertTrue(plan.legs.isEmpty)
    }

    func testRejectsInvalidSnaps() {
        let plan = RoutePlan()
        plan.add(start)
        plan.add(middle)
        XCTAssertFalse(plan.replaceLeg(0, [TrackPoint(lat: 52.0, lon: end.lon), TrackPoint(lat: middle.lat, lon: middle.lon)]))
        XCTAssertFalse(plan.replaceLeg(0, [TrackPoint(lat: start.lat, lon: start.lon)]))
        XCTAssertFalse(plan.replaceLeg(0, [TrackPoint(lat: start.lat, lon: start.lon), TrackPoint(lat: start.lat, lon: start.lon)]))
        XCTAssertFalse(plan.legs[0].snapped)
    }

    func testPreservesTappedEndpointsWhenRouterSnapsNearby() throws {
        let plan = RoutePlan()
        plan.add(start)
        plan.add(middle)
        XCTAssertTrue(plan.replaceLeg(0, [
            TrackPoint(lat: start.lat + 0.0002, lon: start.lon, ele: 180.0),
            TrackPoint(lat: middle.lat - 0.0004, lon: middle.lon, ele: 190.0),
        ]))
        XCTAssertEqual(plan.line.first?.latLon(), start)
        XCTAssertEqual(plan.line.last?.latLon(), middle)
        XCTAssertEqual(plan.line.count, 4)
        XCTAssertEqual(plan.line.first?.ele, 180.0)
        XCTAssertEqual(plan.legs[0].parts.map { $0.snapped }, [false, true, false])
        XCTAssertEqual(plan.legs[0].parts.first?.points.first?.latLon(), start)
        XCTAssertEqual(plan.legs[0].parts.last?.points.last?.latLon(), middle)
        XCTAssertTrue(Geo.distanceM(plan.line[0].latLon(), plan.line[1].latLon()) > 5)
        XCTAssertTrue(plan.estimate(try PaceSettings(flatSpeedKmh: 4.5)).distanceM >
            Geo.distanceM(plan.line[1].latLon(), plan.line[2].latLon()))
    }

    func testShortEndpointOffsetsRemainConnectedAndSolid() {
        let plan = RoutePlan()
        plan.add(start)
        plan.add(middle)
        XCTAssertTrue(plan.replaceLeg(0, [
            TrackPoint(lat: start.lat + 0.00001, lon: start.lon),
            TrackPoint(lat: middle.lat - 0.00001, lon: middle.lon),
        ]))
        XCTAssertEqual(plan.legs[0].parts.count, 1)
        XCTAssertEqual(plan.line, plan.legs[0].parts.first?.points)
        XCTAssertEqual(plan.legs[0].parts.first?.snapped, true)
    }

    func testStaleReplyCannotReplaceReusedLegIndex() {
        let plan = RoutePlan()
        plan.add(start)
        plan.add(middle)
        let staleLeg = plan.legs[0]
        plan.undo()
        plan.add(middle)
        let snapped = [TrackPoint(lat: start.lat, lon: start.lon, ele: 200.0), TrackPoint(lat: middle.lat, lon: middle.lon, ele: 210.0)]
        XCTAssertFalse(plan.replaceLeg(0, snapped, expected: staleLeg))
        XCTAssertFalse(plan.legs[0].snapped)
        XCTAssertTrue(plan.replaceLeg(0, snapped, expected: plan.legs[0]))
    }
}
