import XCTest
@testable import TrailMind

/// OS Names: default names for downloaded areas (ported from the Android app's OsNamesTest, from real OS Names
/// nearest-place answers), place search answers and the requests behind them.
final class OsNamesTests: XCTestCase {
    func testNamesAreasAfterTheNearestPlaceAndItsDistrict() {
        XCTAssertEqual("Parkend, Forest of Dean", OsNames.areaName("Parkend", "Village", "", "Forest of Dean", 12.0))
        XCTAssertEqual("Grasmere, Westmorland and Furness", OsNames.areaName("Grasmere", "Village", "", "Westmorland and Furness", 8.0))
        XCTAssertEqual("Yr Wyddfa, Gwynedd", OsNames.areaName("Yr Wyddfa", "Hill Or Mountain", "", "Gwynedd - Gwynedd", 5.0))
        XCTAssertEqual("Forest of Dean", OsNames.areaName("Forest of Dean", "Other Settlement", "", "Forest of Dean", 3.0))
        XCTAssertEqual("Ben Macdui", OsNames.areaName("Ben Macdui", "Hill Or Mountain", "", "", 4.0))
    }

    func testBigAreasUseTheDistrictAndRoadsUseTheirPlace() {
        XCTAssertEqual("Forest of Dean", OsNames.areaName("Upper Whitelea Green", "Woodland Or Forest", "", "Forest of Dean", 29.0))
        XCTAssertEqual("Parkend, Forest of Dean", OsNames.areaName("B4234", "Numbered Road", "Parkend", "Forest of Dean", 3.0))
        XCTAssertEqual("Westmorland and Furness", OsNames.areaName("A591", "Numbered Road", "", "Westmorland and Furness", 3.0))
        XCTAssertEqual("Coleford", OsNames.areaName("GL16 8", "Postcode", "Coleford", "", 3.0))
        XCTAssertNil(OsNames.areaName("A4136", "Numbered Road", "", "", 3.0))
        XCTAssertNil(OsNames.areaName("", "", "", "", 3.0))
    }

    func testNamesAnAreaFromANearestAnswer() throws {
        let box = BoundingBox(51.75, -2.58, 51.78, -2.53)
        let village = try XCTUnwrap(OsNames.parseNearest("""
            {"header":{"totalresults":1},"results":[{"GAZETTEER_ENTRY":{"ID":"osgb4000000074553608","NAME1":"Parkend",
            "LOCAL_TYPE":"Village","POPULATED_PLACE":"","DISTRICT_BOROUGH":"Forest of Dean","COUNTY_UNITARY":"Gloucestershire"}}]}
            """))
        XCTAssertEqual(OsNames.areaName(village, box), "Parkend, Forest of Dean")
        // A blank district falls back to the county or unitary authority.
        let town = try XCTUnwrap(OsNames.parseNearest("""
            {"results":[{"GAZETTEER_ENTRY":{"NAME1":"Coleford","LOCAL_TYPE":"Town","DISTRICT_BOROUGH":"","COUNTY_UNITARY":"Gloucestershire"}}]}
            """))
        XCTAssertEqual(OsNames.areaName(town, box), "Coleford, Gloucestershire")
        // More than 20 km corner to corner: the district alone.
        XCTAssertEqual(OsNames.areaName(village, BoundingBox(51.6, -2.8, 51.9, -2.4)), "Forest of Dean")
        XCTAssertNil(try OsNames.parseNearest(#"{"header":{},"results":[]}"#))
        XCTAssertNil(try OsNames.parseNearest(#"{"header":{}}"#))
        XCTAssertThrowsError(try OsNames.parseNearest("<html>Service unavailable</html>"))
    }

    func testReadsPlacesFromAFindAnswer() throws {
        let places = try OsNames.parse("""
            {"header":{"totalresults":5},"results":[
              {"GAZETTEER_ENTRY":{"NAME1":"Parkend","LOCAL_TYPE":"Village","GEOMETRY_X":361468.0,"GEOMETRY_Y":208167.0,
                "POPULATED_PLACE":"","DISTRICT_BOROUGH":"Forest of Dean","COUNTY_UNITARY":"Gloucestershire","POSTCODE_DISTRICT":"GL15"}},
              {"GAZETTEER_ENTRY":{"NAME1":"Gloucestershire","LOCAL_TYPE":"County","GEOMETRY_X":380000,"GEOMETRY_Y":"215000",
                "COUNTY_UNITARY":"Gloucestershire"}},
              {"GAZETTEER_ENTRY":{"NAME1":"  ","GEOMETRY_X":1,"GEOMETRY_Y":2}},
              {"GAZETTEER_ENTRY":{"NAME1":"Nowhere","GEOMETRY_X":"east","GEOMETRY_Y":2}},
              {"OTHER":{}}
            ]}
            """)
        XCTAssertEqual(places.count, 2)
        let parkend = places[0]
        XCTAssertEqual(parkend.name, "Parkend")
        XCTAssertEqual(parkend.type, "Village")
        XCTAssertEqual(parkend.area, "Forest of Dean")
        XCTAssertEqual(parkend.grid, "SO 614 081")
        XCTAssertEqual(parkend.zoom, 15.0)
        XCTAssertEqual(parkend.position.lat, 51.767, accuracy: 0.01)
        XCTAssertEqual(parkend.position.lon, -2.557, accuracy: 0.01)
        // The area skips fields that repeat the name; counties and cities open further out.
        let county = places[1]
        XCTAssertEqual(county.area, "")
        XCTAssertEqual(county.zoom, 12.0)
        XCTAssertEqual(county.grid, "SO 800 150")
        XCTAssertEqual(try OsNames.parse(#"{"header":{}}"#), [])
        XCTAssertThrowsError(try OsNames.parse("not json")) { error in
            XCTAssertEqual(OsNames.userMessage((error as? OsNames.Failure)?.message), OsNames.unreachable)
        }
    }

    func testBuildsRequestsAsJavasUrlEncoderDoes() {
        XCTAssertEqual(OsNames.urlEncode("a b*c.d-e_f~ü&+"), "a+b*c.d-e_f%7E%C3%BC%26%2B")
        XCTAssertEqual(OsNames.findURL("Yr Wyddfa", "k+y"),
                       "https://api.os.uk/search/names/v1/find?query=Yr+Wyddfa&maxresults=20&key=k%2By")
        let nearest = OsNames.nearestURL("361468,208167", "KEY", OsNames.settlements)
        XCTAssertTrue(nearest.hasPrefix("https://api.os.uk/search/names/v1/nearest?point=361468,208167&radius=1000&fq=LOCAL_TYPE%3ACity%20LOCAL_TYPE%3ATown%20"))
        XCTAssertTrue(nearest.hasSuffix("&key=KEY"))
        XCTAssertFalse(nearest.contains("+"))
        XCTAssertEqual(OsNames.nearestURL("1,2", "K", nil), "https://api.os.uk/search/names/v1/nearest?point=1,2&radius=1000&key=K")
        XCTAssertEqual(OsNames.areaFilters.count, 3)
    }

    func testNearestPointIsTheBoxCentreOnTheGrid() throws {
        let point = try XCTUnwrap(OsNames.nearestPoint(BoundingBox(51.75, -2.58, 51.78, -2.53)))
        let parts = point.split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 2)
        let grid = try XCTUnwrap(OsGrid.fromWgs84(LatLon(51.765, -2.555)))
        XCTAssertEqual(parts[0], kRound(grid.easting))
        XCTAssertEqual(parts[1], kRound(grid.northing))
        XCTAssertNil(OsNames.nearestPoint(BoundingBox(45.0, 1.0, 46.0, 2.0)))
    }

    func testSearchErrorsShowOsNamesOwnWordsOrConnectionAdvice() {
        XCTAssertEqual(OsNames.httpError(403), "OS Names could not use this API key. Check it in Settings.")
        XCTAssertEqual(OsNames.httpError(429), "OS Names is busy. Please try again later.")
        XCTAssertEqual(OsNames.httpError(500), "OS Names returned HTTP 500.")
        XCTAssertEqual(OsNames.userMessage(OsNames.httpError(401)), OsNames.httpError(401))
        XCTAssertEqual(OsNames.userMessage(OsNames.noKey), OsNames.noKey)
        XCTAssertEqual(OsNames.userMessage(OsNames.unreachable), OsNames.unreachable)
        XCTAssertEqual(OsNames.userMessage("The request timed out."), OsNames.unreachable)
        XCTAssertEqual(OsNames.userMessage(nil), OsNames.unreachable)
    }
}
