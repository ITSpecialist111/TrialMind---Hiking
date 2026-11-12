import XCTest
@testable import TrailMind

/// MBTiles metadata: what TrailMind writes for a download and reads from an imported file (map/MbTiles.kt).
final class MbTilesInfoTests: XCTestCase {
    func testWritesThePackMetadata() {
        let box = BoundingBox(54.4, -3.2, 54.5, -3.0)
        let rows = MbTilesInfo.metadata(name: "Grasmere", bounds: box, minZoom: 7, maxZoom: 16, attribution: "© OS", grid: .webMercator)
        XCTAssertEqual(rows.map(\.0), ["name", "format", "scheme", "type", "version", "minzoom", "maxzoom", "attribution", "bounds"])
        XCTAssertEqual(rows.map(\.1), ["Grasmere", "png", "tms", "baselayer", "1", "7", "16", "© OS", "-3.2,54.4,-3.0,54.5"])
        let bng = MbTilesInfo.metadata(name: "Dean", bounds: nil, minZoom: 0, maxZoom: 5, attribution: "", grid: .britishNationalGrid)
        XCTAssertEqual(bng.map(\.0), ["name", "format", "scheme", "crs", "type", "version", "minzoom", "maxzoom", "attribution"])
        XCTAssertEqual(bng[3].1, "EPSG:27700")
        // What it writes reads back the same.
        XCTAssertEqual(MbTilesInfo.bounds(rows.last?.1), box)
    }

    func testReadsAnImportedFile() {
        let info = MbTilesInfo.info(metadata: ["name": "Lakes", "format": "JPG", "bounds": "-3.2, 54.4, -3.0, 54.5", "minzoom": "10",
                                               "maxzoom": "x", "attribution": "<a href=\"https://osm.org\">&copy; OSM</a> contributors "],
                                    zoomRange: 8...16, sample: nil, tileCount: 42)
        XCTAssertEqual(info, MbTilesInfo.Info(name: "Lakes", format: "jpg", bounds: BoundingBox(54.4, -3.2, 54.5, -3.0), minZoom: 10,
                                              maxZoom: 16, attribution: "© OSM contributors", tileCount: 42))
        let bare = MbTilesInfo.info(metadata: [:], zoomRange: nil, sample: [0xFF, 0xD8, 0xFF, 0xE0], tileCount: 3)
        XCTAssertEqual(bare, MbTilesInfo.Info(name: nil, format: "jpg", bounds: nil, minZoom: 0, maxZoom: 18, attribution: "", tileCount: 3))
        XCTAssertEqual(MbTilesInfo.info(metadata: [:], zoomRange: 3...9, sample: nil, tileCount: 0).minZoom, 3)
        XCTAssertNil(MbTilesInfo.bounds("1,2,3"))
        XCTAssertNil(MbTilesInfo.bounds(nil))
        XCTAssertEqual(MbTilesInfo.bounds("1,2,,3,4"), BoundingBox(2, 1, 4, 3))
    }

    func testRecognisesTileFormats() {
        XCTAssertEqual(MbTilesInfo.sniffFormat([0x89, 0x50, 0x4E, 0x47, 0x0D]), "png")
        XCTAssertEqual(MbTilesInfo.sniffFormat([0xFF, 0xD8, 0xFF, 0xE0]), "jpg")
        XCTAssertEqual(MbTilesInfo.sniffFormat(Array("RIFF1234WEBPVP8 ".utf8)), "webp")
        XCTAssertEqual(MbTilesInfo.sniffFormat([0x1F, 0x8B, 0x08]), "pbf")
        XCTAssertEqual(MbTilesInfo.sniffFormat([0x89, 0x50, 0x4E, 0x47]), "unknown")
        XCTAssertEqual(MbTilesInfo.sniffFormat(nil), "png")
        XCTAssertTrue(MbTilesInfo.rasterFormats.contains("jpeg"))
        XCTAssertFalse(MbTilesInfo.rasterFormats.contains("pbf"))
        XCTAssertTrue(MbTilesInfo.isBritishNationalGrid("epsg:27700"))
        XCTAssertFalse(MbTilesInfo.isBritishNationalGrid("EPSG:3857"))
        XCTAssertFalse(MbTilesInfo.isBritishNationalGrid(nil))
        XCTAssertEqual(MbTilesInfo.unsupportedFormat("pbf"),
                       "This is a 'pbf' MBTiles file. TrailMind renders raster (PNG/JPEG/WebP) tiles only; vector (pbf) packs are not supported yet.")
    }
}
