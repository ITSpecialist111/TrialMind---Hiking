import XCTest
@testable import TrailMind

final class WaymarkedTrailsTests: XCTestCase {
    private func trail(_ name: String = "x") -> WaymarkedTrails.Trail { WaymarkedTrails.Trail(id: 1, name: name, ref: nil, group: "") }

    func testListsRelationsByNameOrRef() throws {
        let json = try RoutesJSON.parse(#"""
        {"results": [
          {"type": "relation", "id": 9, "name": "Offa's Dyke Path", "ref": "ODP", "group": "NAT"},
          {"type": "way", "id": 10, "name": "A way"},
          {"id": 11, "name": " ", "ref": "W1", "group": "LOC"},
          {"id": 12, "name": "", "ref": ""},
          {"id": 13.9, "name": "Same ref", "ref": "Same ref", "group": "REG"},
          {"id": 14, "name": "Odd group", "group": "X"},
          {"id": 15, "name": "Coast", "group": "INT"}
        ]}
        """#)
        let trails = try WaymarkedTrails.trails(json)
        XCTAssertEqual(trails.map(\.id), [9, 11, 13, 14, 15])
        XCTAssertEqual(trails.map(\.name), ["Offa's Dyke Path", "W1", "Same ref", "Odd group", "Coast"])
        XCTAssertEqual(trails.map(\.ref), ["ODP", "W1", "Same ref", nil, nil])
        XCTAssertEqual(trails.map(\.kind), ["National trail", "Local walk", "Regional route", "Waymarked route", "International trail"])
        XCTAssertEqual(trails[0].webUrl, "https://hiking.waymarkedtrails.org/#route?id=9")
        XCTAssertEqual(try WaymarkedTrails.trails(RoutesJSON.parse("{}")), [])
        XCTAssertThrowsError(try WaymarkedTrails.trails(RoutesJSON.parse(#"{"results": [{"name": "No id"}]}"#)))
    }

    func testRequestsMatchTheAndroidApp() {
        XCTAssertEqual(WaymarkedTrails.searchURL("Offa's Dyke"),
                       "https://hiking.waymarkedtrails.org/api/v1/list/search?query=Offa%27s+Dyke&limit=30")
        XCTAssertEqual(WaymarkedTrails.detailsURL(42), "https://hiking.waymarkedtrails.org/api/v1/details/relation/42")
        XCTAssertEqual(WaymarkedTrails.elevationURL(42), "https://hiking.waymarkedtrails.org/api/v1/details/relation/42/way-elevation")
        let box = BoundingBox(54.4, -3.2, 54.5, -3.0)
        let a = WebMercator.toMetres(LatLon(54.4, -3.2))
        let b = WebMercator.toMetres(LatLon(54.5, -3.0))
        XCTAssertEqual(WaymarkedTrails.areaURL(box),
                       "https://hiking.waymarkedtrails.org/api/v1/list/by_area?bbox=\(Int64(a.x)),\(Int64(a.y)),\(Int64(b.x)),\(Int64(b.y))&limit=40")
        XCTAssertTrue(WaymarkedTrails.areaURL(box).contains("bbox=-356222,"))
        XCTAssertTrue(WaymarkedTrails.wantsHeights(lengthM: 60_000))
        XCTAssertFalse(WaymarkedTrails.wantsHeights(lengthM: 60_001))
        XCTAssertFalse(WaymarkedTrails.wantsHeights(lengthM: 0))
    }

    func testDownloadJoinsTheWaysOfARoute() throws {
        let details = try RoutesJSON.parse(#"""
        {"name": "", "route": {"route_type": "route", "length": 2500, "main": [
          {"route_type": "linear", "ways": [
            {"id": 1, "geometry": {"coordinates": [[0, 0], [100, 0]]}},
            {"id": 2, "geometry": {"coordinates": [[100, 0], [200, 0]]}}
          ]},
          {"route_type": "base", "id": 3, "geometry": {"coordinates": [[300, 0], [200, 0]]}},
          "not an object",
          {"route_type": "appendix", "ways": []}
        ]}}
        """#)
        let d = try WaymarkedTrails.download(details: details, heights: nil, trail: trail("Fallback name"))
        XCTAssertEqual(d.name, "Fallback name")
        XCTAssertEqual(d.lengthM, 2500)
        XCTAssertFalse(d.hasElevation)
        XCTAssertEqual(d.points.map { kRound(WebMercator.toMetres($0.latLon()).x) }, [0, 100, 200, 300])
        XCTAssertTrue(d.points.allSatisfy { $0.ele == nil })
        XCTAssertEqual(try WaymarkedTrails.lengthM(details: details), 2500)
    }

    func testHeightsFollowTheRouteDirectionAndAreThinned() throws {
        let heightsJSON = try RoutesJSON.parse(#"""
        {"segments": {"5": {"elevation": [
            {"x": 40, "y": 0, "ele": 140, "pos": 40},
            {"x": 35, "y": 0, "ele": 135, "pos": 35},
            {"x": 30, "y": 0, "ele": 130, "pos": 30},
            {"x": 20, "y": 0, "ele": 120, "pos": 20},
            {"x": 15, "y": 0, "ele": null, "pos": 15},
            {"x": 0, "y": 0, "ele": 100, "pos": 0}
          ]}, "nonsense": {"elevation": [{"x": 1, "y": 1}]}, "6": {}}}
        """#)
        let heights = try WaymarkedTrails.heights(heightsJSON)
        XCTAssertEqual(Array(heights.keys), [5])
        XCTAssertEqual(heights[5]?.count, 6)
        XCTAssertNil(heights[5]?[4].ele)
        let details = try RoutesJSON.parse(#"{"name": "Hill", "route": {"route_type": "linear", "linear": "no", "length": 40, "ways": [{"id": 5, "geometry": {"coordinates": [[0, 0], [40, 0]]}}]}}"#)
        let d = try WaymarkedTrails.download(details: details, heights: heights, trail: trail())
        XCTAssertEqual(d.name, "Hill")
        XCTAssertTrue(d.hasElevation)
        XCTAssertEqual(d.points.map(\.ele), [100, nil, 130, 140])
        XCTAssertEqual(d.points.map { kRound(WebMercator.toMetres($0.latLon()).x) }, [0, 15, 30, 40])
        XCTAssertTrue(try WaymarkedTrails.heights(RoutesJSON.parse("{}")).isEmpty)
    }

    func testSplitRoutesUseTheForwardBranch() throws {
        let details = try RoutesJSON.parse(#"{"route": {"route_type": "split", "forward": [{"route_type": "base", "geometry": {"coordinates": [[0, 0], [50, 0]]}}], "backward": [{"route_type": "base", "geometry": {"coordinates": [[0, 0], [0, 50]]}}]}}"#)
        let d = try WaymarkedTrails.download(details: details, heights: [:], trail: trail("Split"))
        XCTAssertEqual(d.points.map { kRound(WebMercator.toMetres($0.latLon()).x) }, [0, 50])
        XCTAssertEqual(d.points.map { kRound(WebMercator.toMetres($0.latLon()).y) }, [0, 0])
        XCTAssertEqual(d.lengthM, 0)
        XCTAssertFalse(d.hasElevation)
        XCTAssertEqual(d.name, "Split")
    }

    func testARouteWithoutALineIsRefused() throws {
        let details = try RoutesJSON.parse(#"{"route": {"route_type": "route", "main": []}}"#)
        XCTAssertThrowsError(try WaymarkedTrails.download(details: details, heights: nil, trail: trail())) {
            XCTAssertEqual($0.localizedDescription, "OpenStreetMap has no usable line for this route yet.")
        }
        XCTAssertThrowsError(try WaymarkedTrails.download(details: RoutesJSON.parse("{}"), heights: nil, trail: trail()))
    }

    /// GeoTest.pathJoinOrientsAndChainsPieces, on the copy of core PathJoin that Waymarked Trails downloads use.
    func testPathJoinOrientsAndChainsPieces() {
        func pt(_ lon: Double) -> TrackPoint { TrackPoint(lat: 54.0, lon: lon) }
        let a = [pt(0.000), pt(0.001)]
        let bReversed = [pt(0.003), pt(0.002), pt(0.001)]
        XCTAssertEqual(WaymarkedTrails.join([a, bReversed]).map(\.lon), [0.000, 0.001, 0.002, 0.003])
        // A first piece stored backwards is flipped so the line does not start with a jump.
        XCTAssertEqual(WaymarkedTrails.join([Array(a.reversed()), [pt(0.002), pt(0.003)]]).map(\.lon), [0.000, 0.001, 0.002, 0.003])
        // Unordered sections are chained nearest end first.
        let far = [pt(0.010), pt(0.011)]
        let near = [pt(0.002), pt(0.003)]
        XCTAssertEqual(WaymarkedTrails.join([a, far, near], ordered: false).map(\.lon), [0.000, 0.001, 0.002, 0.003, 0.010, 0.011])
        // Ordered sections keep their order and are only flipped.
        XCTAssertEqual(WaymarkedTrails.join([a, far, near]).map(\.lon), [0.000, 0.001, 0.010, 0.011, 0.003, 0.002])
        XCTAssertEqual(WaymarkedTrails.join([[], []]), [])
    }
}
