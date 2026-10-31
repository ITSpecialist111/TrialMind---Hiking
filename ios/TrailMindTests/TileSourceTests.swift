import XCTest
@testable import TrailMind

final class TileSourceTests: XCTestCase {
    private func source(_ id: String) throws -> TileSource { try XCTUnwrap(TileSources.builtIns().first { $0.id == id }) }

    func testOSLayersUseTheWebMercatorRasterAPIWithTheUsersKey() throws {
        let url = try XCTUnwrap(try source(TileSources.osOutdoor).url(TileKey(15, 16148, 10889), apiKey: " abc123 "))
        XCTAssertEqual(url.absoluteString, "https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/15/16148/10889.png?key=abc123")
        XCTAssertTrue(try XCTUnwrap(try source(TileSources.osRoad).url(TileKey(7, 1, 2), apiKey: "k")).path.contains("Road_3857"))
        XCTAssertTrue(try XCTUnwrap(try source(TileSources.osLight).url(TileKey(20, 1, 2), apiKey: "k")).path.contains("Light_3857"))
    }

    func testKeyedSourcesNeedAKeyAndEscapeIt() throws {
        let os = try source(TileSources.osOutdoor)
        XCTAssertNil(os.url(TileKey(12, 1, 1), apiKey: nil))
        XCTAssertNil(os.url(TileKey(12, 1, 1), apiKey: "  "))
        let url = try XCTUnwrap(os.url(TileKey(10, 1, 1), apiKey: "a&b=c"))
        XCTAssertFalse(url.absoluteString.contains("a&b=c"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b=c")
    }

    func testPremiumZoomsMatchAndroid() throws {
        let outdoor = try source(TileSources.osOutdoor)
        XCTAssertEqual(outdoor.premiumFromZoom, 17)
        XCTAssertTrue(outdoor.canStoreInPack(16))
        XCTAssertFalse(outdoor.canStoreInPack(17))
        let leisure = try source(TileSources.osLeisure)
        XCTAssertEqual(leisure.grid, .britishNationalGrid)
        XCTAssertTrue(leisure.isPremium(6))
        XCTAssertFalse(leisure.isPremium(5))
    }

    func testOpenStreetMapIsBrowseOnlyAndAppleHasNoTiles() throws {
        let osm = try source(TileSources.osm)
        XCTAssertEqual(osm.url(TileKey(3, 4, 2), apiKey: nil)?.absoluteString, "https://tile.openstreetmap.org/3/4/2.png")
        XCTAssertFalse(osm.offlineDownloadAllowed)
        let apple = try source(TileSources.apple)
        XCTAssertNil(apple.url(TileKey(10, 0, 0), apiKey: "k"))
        XCTAssertTrue(apple.appleMap)
    }

    func testOldMapsAreOverlaysOnTheUsersMapTilerKey() {
        let old = TileSources.historic()
        XCTAssertEqual(old.count, 6)
        XCTAssertTrue(old.allSatisfy { $0.overlay && $0.historic && $0.keyKind == .mapTiler && !$0.offlineDownloadAllowed })
        XCTAssertEqual(old.first?.id, TileSources.nlsSixInch)
    }
}
