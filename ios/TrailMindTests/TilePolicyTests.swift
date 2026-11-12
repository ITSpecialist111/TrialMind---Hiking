import XCTest
@testable import TrailMind

/// TilePolicy's checks from StatsAndNavTest.kt and the app's TileSourceTest.kt, and `hostOf` against what
/// java.net.URI (Java 21) gives for the same templates.
final class TilePolicyTests: XCTestCase {
    func testPremiumExpiryIncludesBoundaryClockRollbackAndIdleBatch() {
        let stored: Int64 = 1_000_000
        let expiry = stored + TilePolicy.premiumCacheMs
        XCTAssertFalse(TilePolicy.premiumPurgeDue(stored, expiry - 1))
        XCTAssertTrue(TilePolicy.premiumPurgeDue(stored, expiry))
        XCTAssertTrue(TilePolicy.premiumPurgeDue(stored, expiry + 1))
        XCTAssertTrue(TilePolicy.premiumPurgeDue(stored, stored - 1))
        XCTAssertTrue(TilePolicy.premiumPurgeDue(stored, expiry - 15 * 60_000, 15 * 60_000))
        XCTAssertFalse(TilePolicy.premiumPurgeDue(stored, expiry - 15 * 60_000 - 1, 15 * 60_000))
        XCTAssertFalse(TilePolicy.premiumPurgeDue(stored, stored, 15 * 60_000))
    }

    func testTilePolicy() {
        let now: Int64 = 100 * 3_600_000
        XCTAssertTrue(TilePolicy.premiumCacheFresh(now - 24 * 3_600_000 + 1, now))
        XCTAssertFalse(TilePolicy.premiumCacheFresh(now - 24 * 3_600_000, now))
        XCTAssertFalse(TilePolicy.premiumCacheFresh(now - 25 * 3_600_000, now))
        XCTAssertFalse(TilePolicy.premiumCacheFresh(now + 60_000, now))
        XCTAssertTrue(TilePolicy.isBulkDownloadForbidden("https://tile.openstreetmap.org/{z}/{x}/{y}.png"))
        XCTAssertTrue(TilePolicy.isBulkDownloadForbidden("https://a.tile.opentopomap.org/{z}/{x}/{y}.png"))
        XCTAssertTrue(TilePolicy.isBulkDownloadForbidden("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"))
        XCTAssertFalse(TilePolicy.isBulkDownloadForbidden("https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/{z}/{x}/{y}.png?key={key}"))
        XCTAssertEqual(TilePolicy.hostOf("https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/{z}/{x}/{y}.png?key={key}"), "api.os.uk")
        XCTAssertFalse(TilePolicy.isBulkDownloadForbidden("https://tiles.example.com/{z}/{x}/{-y}.png"))
        XCTAssertEqual(
            TilePolicy.fillTemplate("https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/{z}/{x}/{y}.png?key={key}", TileKey(12, 2010, 1300), "K"),
            "https://api.os.uk/maps/raster/v1/zxy/Outdoor_3857/12/2010/1300.png?key=K"
        )
        XCTAssertEqual(TilePolicy.fillTemplate("https://h/{z}/{x}/{-y}.png", TileKey(3, 1, 5)), "https://h/3/1/2.png")
        XCTAssertNil(TilePolicy.validateTemplate("https://example.com/{z}/{x}/{y}.png"))
        XCTAssertNotNil(TilePolicy.validateTemplate("ftp://example.com/{z}/{x}/{y}.png"))
        XCTAssertNotNil(TilePolicy.validateTemplate("https://example.com/tiles.png"))
    }

    func testSubdomainsRotateAndTemplatesAreTrimmed() {
        XCTAssertEqual(TilePolicy.fillTemplate("https://{s}.h/{z}/{x}/{y}", TileKey(5, 3, 4)), "https://b.h/5/3/4")
        XCTAssertEqual(TilePolicy.fillTemplate("https://{s}.h/{z}/{x}/{y}", TileKey(5, 3, 4), nil, subdomains: ""), "https://.h/5/3/4")
        XCTAssertEqual(TilePolicy.validateTemplate("  https://example.com/{z}/{x}/{-y}.png\n"), nil)
        XCTAssertEqual(TilePolicy.validateTemplate("https://my_tiles.example.com/{z}/{x}/{y}.png"), "URL host is not valid")
        XCTAssertEqual(TilePolicy.validateTemplate("https://example.com/{z}/{x}.png"), "URL must contain {z}, {x} and {y} (or {-y})")
        XCTAssertEqual(TilePolicy.validateTemplate("example.com/{z}/{x}/{y}.png"), "URL must start with https://")
        XCTAssertTrue(TilePolicy.isBulkDownloadForbidden("https://tiles_.example.com/{z}/{x}/{y}.png"))
        XCTAssertTrue(TilePolicy.isBulkDownloadForbidden("https://api.maptiler.com/maps/outdoor/{z}/{x}/{y}.png?key={key}"))
    }

    func testOpenDataTilesStayBelowPremiumZooms() {
        for premiumFromZoom in [17, 6] {
            for zoom in 0...TilePolicy.maxZoom {
                let request = TileKey(zoom, 12345, 23456)
                let loaded = TilePolicy.openDataTile(request, premiumFromZoom)
                XCTAssertTrue(loaded.z < premiumFromZoom, "\(request) became \(loaded)")
                if zoom >= premiumFromZoom {
                    XCTAssertEqual(loaded.z, premiumFromZoom - 1)
                    let scale = 1 << (zoom - loaded.z)
                    XCTAssertEqual(loaded.x, request.x / scale)
                    XCTAssertEqual(loaded.y, request.y / scale)
                } else {
                    XCTAssertEqual(loaded, request)
                }
            }
        }
        let osm = TileKey(19, 12345, 23456)
        XCTAssertEqual(TilePolicy.openDataTile(osm, nil), osm)
    }

    func testHostsAreFoundWhereJavaNetUriFindsThem() {
        let javaHosts: [(String, String?)] = [
            ("https://tile.openstreetmap.org/{z}/{x}/{y}.png", "tile.openstreetmap.org"),
            ("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", "0.tile.openstreetmap.org"),
            ("https://tiles.example.com/{z}/{x}/{-y}.png", "tiles.example.com"),
            ("http://LocalHost:8080/{z}/{x}/{y}.png", "localhost"),
            ("http://192.168.1.20:8080/tiles/{z}/{x}/{y}.png", "192.168.1.20"),
            ("http://[::1]:8080/{z}/{x}/{y}.png", "[::1]"),
            ("http://[::ffff:10.0.0.1]/{z}/{x}/{y}.png", "[::ffff:10.0.0.1]"),
            ("http://[fe80::1%25eth0]/{z}", "[fe80::1%25eth0]"),
            ("http://[1:2:3]/{z}", nil),
            ("http://[::1/{z}", nil),
            ("https://user@Tiles.Example.com/{z}/{x}/{y}.png", "tiles.example.com"),
            ("https://tiles.example.com./{z}/{x}/{y}.png", "tiles.example.com."),
            ("https://my_tiles.example.com/{z}/{x}/{y}.png", nil),
            ("https://tiles.123/{z}/{x}/{y}.png", nil),
            ("https://tiles-.example.com/{z}", nil),
            ("https://-tiles.example.com/{z}", nil),
            ("https://tiles.example.com:80a/{z}.png", nil),
            ("https://tiles.example.com:/{z}.png", "tiles.example.com"),
            ("https://tiles.example.com:99999999999/{z}.png", nil),
            ("https://exa mple.com/{z}/{x}/{y}.png", nil),
            ("https://example.com/{z}/{x}/{y}.png?bbox={1}", nil),
            ("https://example.com/{z}/{x}/{y}.png?layers=[a]", "example.com"),
            ("https://example.com/[a]/{z}/{x}/{y}.png", nil),
            ("https://example.com/%zz/{z}", nil),
            ("https://example.com/%41/{z}", "example.com"),
            ("https://example.com/{z}/{x}/{y}.png#frag", "example.com"),
            ("https://example.com/{z}/{x}/{y}.png#a#b", nil),
            ("https:///{z}/{x}/{y}.png", nil),
            ("https://", nil),
            ("https:", nil),
            ("tiles/{z}/{x}/{y}.png", nil),
            ("//cdn.example.com/{z}/{x}/{y}.png", "cdn.example.com"),
            ("mailto:tiles@example.com", nil),
            ("http://1.2.3/{z}", nil),
            ("http://1.2.3.4.example.org/{z}", "1.2.3.4.example.org"),
            ("http://1.2.3.256/{z}", nil),
            ("http://01.02.03.04/{z}", "01.02.03.04"),
            ("http://999999999999.1.1.1/{z}", nil),
            ("https://xn--tiles-example.com/{z}", "xn--tiles-example.com"),
            ("https://tïles.example.com/{z}", nil),
            ("https://example.com/tïles/{z}", "example.com"),
            ("https://example.com/{z}/{x}/{y}.png?q=a b", nil),
            ("https://example.com/{z}/{x}/{y}.png?q=a|b", nil),
            ("HTTPS://EXAMPLE.COM/{Z}/{X}/{Y}.PNG", "example.com"),
            ("1https://example.com/{z}", nil),
            ("ht tp://example.com/{z}", nil),
            ("https://example.com:8080:90/{z}", nil),
            ("https://a@b@example.com/{z}", nil),
            ("https://example.com/{zoom}/{x}/{y}.png", "example.com"),
            ("https://example.com/{z}/{x}/{y}.png?key={api_key}", nil),
            ("https://localhost/{z}", "localhost"),
            ("https://a.b-c.d/{z}", "a.b-c.d"),
            ("https://a..b/{z}", nil),
            ("https://.example.com/{z}", nil),
            ("https://example.com%2F/{z}", nil),
            ("https://[::1]x/{z}", nil),
            ("https://0/{z}", "0"),
            ("https://0.0.0.0/{z}", "0.0.0.0"),
        ]
        for (template, host) in javaHosts {
            XCTAssertEqual(TilePolicy.hostOf(template), host, template)
        }
    }
}
