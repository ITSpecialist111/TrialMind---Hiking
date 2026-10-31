import XCTest
@testable import TrailMind

/// Search input (SearchPage.submit) and the offline-area polygons drawn on the map (TileMapView.drawOfflineAreas).
final class OfflineSearchAndAreasTests: XCTestCase {
    private func local(_ text: String, imperial: Bool = false) throws -> OsNames.Place {
        guard case .local(let place) = SearchInput.classify(text, imperial: imperial) else {
            XCTFail("\(text) was not found on the phone")
            throw XCTSkip("not local")
        }
        return place
    }

    func testGridReferencesAreFoundOffline() throws {
        let place = try local("NY 21580 07220")
        XCTAssertEqual(place.type, "Grid reference")
        XCTAssertEqual(place.area, "1 m square")
        XCTAssertEqual(place.grid, "NY 21580 07220")
        XCTAssertEqual(place.zoom, 15.0)
        let expected = try XCTUnwrap(OsGrid.parse("NY 21580 07220")).position
        XCTAssertEqual(place.position.lat, expected.lat, accuracy: 1e-12)
        XCTAssertEqual(place.position.lon, expected.lon, accuracy: 1e-12)

        let square = try local("sd12")
        XCTAssertEqual(square.area, "10.0 km square")
        XCTAssertEqual(square.grid, "SD12")
        XCTAssertEqual(square.zoom, 15.0)
        XCTAssertEqual(try local("SD").zoom, 9.0)
        XCTAssertEqual(try local("SD").area, "100.0 km square")
        XCTAssertEqual(try local("SD 123 456", imperial: true).area, "328 ft square")
    }

    func testDecimalCoordinatesAreFoundOffline() throws {
        let place = try local("54.4609, -3.0886")
        XCTAssertEqual(place.type, "Coordinates")
        XCTAssertEqual(place.area, "")
        XCTAssertEqual(place.position, LatLon(54.4609, -3.0886))
        XCTAssertEqual(place.grid, OsGrid.fromWgs84(LatLon(54.4609, -3.0886))?.format(6))
        XCTAssertEqual(place.zoom, 15.0)
        XCTAssertEqual(try local("51.5 N 0.12 W").position, LatLon(51.5, -0.12))
        // Outside Great Britain there is no grid reference.
        XCTAssertNil(try local("48.8584 2.2945").grid)
    }

    func testPositionsThatAreNotValidSayWhy() {
        XCTAssertEqual(SearchInput.classify("SI 123 456", imperial: false), .invalid(SearchInput.invalidGrid))
        XCTAssertEqual(SearchInput.classify("NY 123 4567", imperial: false), .invalid(SearchInput.invalidGrid))
        XCTAssertEqual(SearchInput.classify("95.0, 10.0", imperial: false), .invalid(SearchInput.invalidCoordinates))
        XCTAssertEqual(SearchInput.classify("-12 N, 3 E", imperial: false), .invalid(SearchInput.invalidCoordinates))
    }

    func testThreeWordsAndPlaceNamesGoOnline() {
        XCTAssertEqual(SearchInput.classify("///filled.count.soap", imperial: false), .threeWords)
        XCTAssertEqual(SearchInput.classify("filled.count.soap", imperial: false), .threeWords)
        XCTAssertEqual(SearchInput.classify("///", imperial: false), .threeWords)
        XCTAssertEqual(SearchInput.classify("Scafell Pike", imperial: false), .places)
        XCTAssertEqual(SearchInput.classify("Ben Nevis", imperial: false), .places)
        XCTAssertEqual(SearchInput.classify("Coleford", imperial: false), .places)
        // Two letters and digits read as a grid reference, as on Android, so a postcode district such as GL16 is refused.
        XCTAssertEqual(SearchInput.classify("GL16", imperial: false), .invalid(SearchInput.invalidGrid))
    }

    func testKeepsTheFiveLatestSearches() {
        XCTAssertEqual(SearchInput.recent("Parkend", []), ["Parkend"])
        XCTAssertEqual(SearchInput.recent("parkend", ["Coleford", "Parkend", "Lydney"]), ["parkend", "Coleford", "Lydney"])
        XCTAssertEqual(SearchInput.recent("F", ["A", "B", "C", "D", "E"]), ["F", "A", "B", "C", "D"])
    }

    func testResultDetailsLeaveOutBlankParts() {
        let place = OsNames.Place(name: "Parkend", type: "Village", area: "Forest of Dean", position: LatLon(51.77, -2.56), grid: "SO 616 080", zoom: 15)
        XCTAssertEqual(SearchInput.detail(place), "Village · Forest of Dean · SO 616 080")
        var bare = place
        bare.area = " "
        bare.grid = nil
        XCTAssertEqual(SearchInput.detail(bare), "Village")
    }

    func testWebMercatorFootprintsBecomeTileCornerPolygons() throws {
        let f = try XCTUnwrap(TileFootprint.of(12, [2010, 2011, 2010], [1300, 1300, 1301]))
        let shape = FootprintPolygons.of(f, nationalGrid: false)
        XCTAssertEqual(shape.fills.count, 2)
        XCTAssertEqual(shape.edges.count, 1)
        XCTAssertEqual(shape.edges[0].count, 6)
        let nw = shape.edges[0][0]
        XCTAssertEqual(nw.lon, WebMercator.xToLon(2010.0 * 256, 12), accuracy: 1e-12)
        XCTAssertEqual(nw.lat, WebMercator.yToLat(1300.0 * 256, 12), accuracy: 1e-12)
        // The fill's first rectangle spans the top row's two tiles.
        let top = shape.fills[0]
        XCTAssertEqual(top.count, 4)
        XCTAssertEqual(top[1].lon, WebMercator.xToLon(2012.0 * 256, 12), accuracy: 1e-12)
        XCTAssertEqual(top[2].lat, WebMercator.yToLat(1301.0 * 256, 12), accuracy: 1e-12)
        XCTAssertTrue(f.contains(2011, 1300))
        XCTAssertTrue(f.contains(2010, 1301))
        XCTAssertFalse(f.contains(2011, 1301))
        XCTAssertFalse(f.contains(2012, 1300))
    }

    func testNationalGridOutlinesBendThroughEveryCorner() throws {
        let f = try XCTUnwrap(TileFootprint.of(3, [2, 3], [5, 5]))
        let shape = FootprintPolygons.of(f, nationalGrid: true)
        XCTAssertEqual(shape.edges.count, 1)
        XCTAssertEqual(shape.edges[0].count, 6)
        XCTAssertEqual(shape.fills.map(\.count), [6])
        let corner = shape.edges[0][0]
        let expected = OsGrid.toWgs84(BngTiles.easting(2, 3), BngTiles.northing(5, 3))
        XCTAssertEqual(corner.lat, expected.lat, accuracy: 1e-12)
        XCTAssertEqual(corner.lon, expected.lon, accuracy: 1e-12)
    }
}
