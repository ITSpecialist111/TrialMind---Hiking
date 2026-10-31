import XCTest
@testable import TrailMind

/// Smoke checks for the hand-ported base types; the full GeoTest port covers the rest.
final class CoreBaseTests: XCTestCase {
    func testBenNevisGridReference() throws {
        let ref = try XCTUnwrap(OsGrid.fromWgs84(LatLon(56.796849, -5.003508)))
        let text = try XCTUnwrap(ref.format(10))
        XCTAssertTrue(text.hasPrefix("NN 166"), text)
        let parsed = try XCTUnwrap(OsGrid.parse(text))
        XCTAssertEqual(parsed.position.lat, 56.796849, accuracy: 0.0002)
        XCTAssertEqual(parsed.position.lon, -5.003508, accuracy: 0.0002)
    }

    func testUnitsMatchAndroidFormatting() {
        XCTAssertEqual(Units.distance(999.6), "1000 m")
        XCTAssertEqual(Units.distance(1234), "1.23 km")
        XCTAssertEqual(Units.distance(12345), "12.3 km")
        XCTAssertEqual(Units.minutes(145), "2h 25m")
        XCTAssertEqual(Units.bearing(-1), "359°")
        XCTAssertEqual(Units.latLon(51.5, -2.5), "51.50000°N 2.50000°W")
    }

    func testWebMercatorRoundTrip() {
        let p = LatLon(51.78, -2.55)
        let x = WebMercator.lonToX(p.lon, 15), y = WebMercator.latToY(p.lat, 15)
        XCTAssertEqual(WebMercator.xToLon(x, 15), p.lon, accuracy: 1e-9)
        XCTAssertEqual(WebMercator.yToLat(y, 15), p.lat, accuracy: 1e-9)
        XCTAssertEqual(WebMercator.tileFor(p, 0), TileKey(0, 0, 0))
    }
}
