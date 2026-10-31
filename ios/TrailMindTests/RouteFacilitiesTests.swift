import XCTest
@testable import TrailMind

final class RouteFacilitiesTests: XCTestCase {
    func testNarrowsLongRoutesWithoutDroppingBelowHundredMetres() {
        let short = [LatLon(51.0, -2.0), LatLon(51.1, -2.0)]
        let long = (0...20).map { LatLon(51.0 + Double($0) * 0.05, -2.0) }
        XCTAssertEqual(RouteFacilities.corridorM(short), 250)
        XCTAssertTrue((100...249).contains(RouteFacilities.corridorM(long)))
        XCTAssertEqual(RouteFacilities.corridorM((0...80).map { LatLon(51.0 + Double($0) * 0.05, -2.0) }), 100)
        let near = Facility(category: .water, position: LatLon(51.0018, -1.997))
        XCTAssertTrue(RouteFacilities.locate(short, [near], corridorM: 100).isEmpty)
    }

    func testSimplifiesWithEndpointsAndPointLimit() {
        let route = (0...1000).map { LatLon(51.78 + Double($0) * 0.00001, -2.54 + sin(Double($0) / 12.0) * 0.0003) }
        let reduced = RouteFacilities.simplify(route)
        XCTAssertTrue(reduced.count <= 150)
        XCTAssertEqual(reduced.first, route.first)
        XCTAssertEqual(reduced.last, route.last)
        let longRoute = (0...1000).map { LatLon(51.0 + Double($0) * 0.003, -2.54 + sin(Double($0) / 2.0) * 0.5) }
        XCTAssertTrue(RouteFacilities.simplify(longRoute).count <= 150)
        let folded = (0...1000).map { index in
            LatLon(51.0, index % 3 == 0 ? -2.54 : index % 3 == 1 ? -2.538 : -2.542)
        }
        XCTAssertTrue(RouteFacilities.simplify(folded).count <= 150)
    }

    func testProjectsFiltersAndDeduplicatesLoop() {
        let route = [LatLon(51.78, -2.54), LatLon(51.78, -2.53), LatLon(51.781, -2.53), LatLon(51.781, -2.54), LatLon(51.78, -2.54)]
        let items = [
            Facility(category: .parking, position: route[0], name: "New Fancy"),
            Facility(category: .parking, position: LatLon(51.78001, -2.54), name: "New Fancy"),
            Facility(category: .cafe, position: LatLon(51.78, -2.535), name: "Café"),
            Facility(category: .water, position: LatLon(51.79, -2.535)),
        ]
        let found = RouteFacilities.locate(route, items)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].category, .parking)
        XCTAssertEqual(found[0].alongM, 0.0, accuracy: 1.0)
        XCTAssertTrue(found[1].alongM > 300)
        XCTAssertTrue(found[1].offM < 2)
    }

    func testAssignsFacilityNearBothLegsToFirstPassing() throws {
        let route = [LatLon(51.0, -2.0), LatLon(51.0, -1.99), LatLon(51.0005, -1.99), LatLon(51.0005, -2.0)]
        let item = Facility(category: .water, position: LatLon(51.00048, -1.995))
        let found = RouteFacilities.locate(route, [item])
        XCTAssertEqual(found.count, 1)
        let only = try XCTUnwrap(found.first)
        XCTAssertTrue(only.alongM < 700, "Expected first leg, got \(only.alongM) m")
    }

    func testFavoursClosePassOverEarlierCorridorEdge() throws {
        let route = [LatLon(51.0, -2.0), LatLon(51.0, -1.99), LatLon(51.002, -1.99), LatLon(51.002, -2.0)]
        let found = RouteFacilities.locate(route, [Facility(category: .cafe, position: LatLon(51.0019, -1.995))])
        XCTAssertEqual(found.count, 1)
        let only = try XCTUnwrap(found.first)
        XCTAssertTrue(only.alongM > 900, "Expected close return leg, got \(only.alongM) m")
        XCTAssertTrue(only.offM < 20)
    }

    func testRejectsPrivateAndUnnamedPeaks() {
        XCTAssertNil(FacilityCategory.fromTags(["amenity": "parking", "access": "private"]))
        XCTAssertNil(FacilityCategory.fromTags(["natural": "peak"]))
        XCTAssertEqual(FacilityCategory.fromTags(["natural": "peak", "name": "May Hill"]), .peak)
    }

    func testBriefingOnlyIncludesSavedFacilities() {
        let base = BriefingInput(routeName: "Loop",
                                 estimate: HikeEstimate(naismithMinutes: 60.0, toblerMinutes: 70.0, distanceM: 4000.0, ascentM: 0.0, descentM: 0.0),
                                 start: LatLon(51.78, -2.54), end: LatLon(51.78, -2.54), maxEleM: nil, waypointNames: [], sun: nil, plannedStartMs: 0)
        XCTAssertFalse(Briefing.ruleBased(base).contains { $0.hasPrefix("Facilities:") })
        var withWater = base
        withWater.facilities = [Facility(category: .water, position: base.start, alongM: 1200.0)]
        XCTAssertTrue(Briefing.ruleBased(withWater).contains { $0 == "Facilities: Drinking water at 1.20 km." })
        var partial = withWater
        partial.facilitiesPartial = true
        XCTAssertTrue(Briefing.ruleBased(partial).contains { $0 == "Facilities (limited results): Drinking water at 1.20 km." })
    }
}
