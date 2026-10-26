import XCTest
@testable import TrailMind

final class MapLayerTests: XCTestCase {
    func testOSLayersUseTheWebMercatorRasterAPIWithTheUsersKey() throws {
        let url = try XCTUnwrap(MapLayer.osOutdoor.tileURL(z: 15, x: 16148, y: 10889, apiKey: " abc123 "))
        XCTAssertEqual(url.absoluteString, "https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/15/16148/10889.png?key=abc123")
        XCTAssertTrue(try XCTUnwrap(MapLayer.osRoad.tileURL(z: 7, x: 1, y: 2, apiKey: "k")).path.contains("Road_3857"))
        XCTAssertTrue(try XCTUnwrap(MapLayer.osLight.tileURL(z: 20, x: 1, y: 2, apiKey: "k")).path.contains("Light_3857"))
    }

    func testOSLayersNeedAKeyAndStayInsideTheirZooms() {
        XCTAssertNil(MapLayer.osOutdoor.tileURL(z: 12, x: 1, y: 1, apiKey: nil))
        XCTAssertNil(MapLayer.osOutdoor.tileURL(z: 12, x: 1, y: 1, apiKey: "  "))
        XCTAssertNil(MapLayer.osOutdoor.tileURL(z: 6, x: 1, y: 1, apiKey: "k"))
        XCTAssertNil(MapLayer.osOutdoor.tileURL(z: 21, x: 1, y: 1, apiKey: "k"))
        XCTAssertEqual(MapLayer.osOutdoor.premiumFromZoom, 17)
    }

    func testKeyIsEscapedInTheQuery() throws {
        let url = try XCTUnwrap(MapLayer.osOutdoor.tileURL(z: 10, x: 1, y: 1, apiKey: "a&b=c"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b=c")
        XCTAssertFalse(url.absoluteString.contains("a&b=c"))
    }

    func testOpenStreetMapAndAppleNeedNoKey() {
        XCTAssertEqual(MapLayer.osm.tileURL(z: 3, x: 4, y: 2, apiKey: nil)?.absoluteString,
                       "https://tile.openstreetmap.org/3/4/2.png")
        XCTAssertNil(MapLayer.osm.tileURL(z: 20, x: 0, y: 0, apiKey: nil))
        XCTAssertNil(MapLayer.apple.tileURL(z: 10, x: 0, y: 0, apiKey: "k"))
        XCTAssertNil(MapLayer.apple.attribution())
        XCTAssertEqual(MapLayer.osOutdoor.attribution(year: 2026), "Contains OS data © Crown copyright and database rights 2026")
    }
}
