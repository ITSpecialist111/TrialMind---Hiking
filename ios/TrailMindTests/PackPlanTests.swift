import XCTest
@testable import TrailMind

/// Offline-pack planning: zoom choices, tile counts, wording, 24-hour detail and how a download is reported
/// (OfflinePage, DownloadService and PremiumRenewal on Android).
final class PackPlanTests: XCTestCase {
    private func source(_ id: String) -> TileSource { TileSources.builtIns().first { $0.id == id }! }
    private var outdoor: TileSource { source(TileSources.osOutdoor) }
    private var leisure: TileSource { source(TileSources.osLeisure) }
    private var osm: TileSource { source(TileSources.osm) }
    private let custom = TileSources.custom(name: "Local", template: "https://tiles.example.com/{z}/{x}/{y}.png", attribution: "",
                                            maxZoom: 10, offlineAllowed: true, bulkForbidden: false)

    func testZoomChoicesFollowTheSource() {
        XCTAssertEqual(PackPlan.minZoom(outdoor), 7)
        XCTAssertEqual(PackPlan.minZoom(leisure), 0)
        XCTAssertEqual(PackPlan.minZoom(custom), 7)
        XCTAssertEqual(PackPlan.zoomOptions(outdoor), [12, 13, 14, 15, 16])
        XCTAssertEqual(PackPlan.zoomOptions(leisure), [5])
        XCTAssertEqual(PackPlan.zoomOptions(custom), [])
        XCTAssertEqual(PackPlan.overviewNote(outdoor), "Zoom 15 ≈ 1:18k detail, 16 ≈ 1:9k. Lower zooms (7+) are included for overview.")
        XCTAssertEqual(PackPlan.overviewNote(leisure), "Overview maps (kept): zooms 0–5.")
        XCTAssertEqual(PackPlan.chipName(outdoor), "Outdoor")
        XCTAssertEqual(PackPlan.chipName(leisure), "Explorer® & Landranger®")
        XCTAssertEqual(PackPlan.chipName(osm), "OpenStreetMap (online)")
    }

    func testPremiumZoomsNeedThePlanAndAChoice() {
        XCTAssertEqual(PackPlan.premiumZooms(outdoor, osPremium: true, premiumMaxZoom: 18), 17...18)
        XCTAssertNil(PackPlan.premiumZooms(outdoor, osPremium: false, premiumMaxZoom: 18))
        XCTAssertNil(PackPlan.premiumZooms(outdoor, osPremium: true, premiumMaxZoom: 0))
        XCTAssertEqual(PackPlan.premiumZooms(leisure, osPremium: true, premiumMaxZoom: 9), 6...9)
        XCTAssertEqual(PackPlan.premiumZooms(leisure, osPremium: true, premiumMaxZoom: 6), 6...6)
        XCTAssertEqual(PackPlan.premiumZooms(leisure, osPremium: true, premiumMaxZoom: 12), 6...9)
        XCTAssertNil(PackPlan.premiumZooms(osm, osPremium: true, premiumMaxZoom: 18))
        XCTAssertEqual(PackPlan.premiumOptions(outdoor).map(\.label), ["Off", "to 17", "to 18", "to 19"])
        XCTAssertEqual(PackPlan.premiumOptions(outdoor).map(\.zoom), [0, 17, 18, 19])
        XCTAssertEqual(PackPlan.premiumOptions(leisure).map(\.label), ["Off", "Landranger (zoom 6)", "Explorer 1:25k (zooms 7–9)"])
        XCTAssertEqual(PackPlan.premiumOptions(leisure).map(\.zoom), [0, 6, 9])
        XCTAssertTrue(PackPlan.premiumOptions(osm).isEmpty)
        XCTAssertEqual(PackPlan.premiumHeading(leisure), "Explorer 1:25k detail — OS lets you keep this for 24 hours")
        XCTAssertEqual(PackPlan.premiumHeading(outdoor), "Closer detail (kept 24 hours)")
        XCTAssertEqual(PackPlan.premiumFirstZoom(packMaxZoom: 16, premiumFromZoom: 17), 17)
        XCTAssertEqual(PackPlan.premiumFirstZoom(packMaxZoom: 5, premiumFromZoom: 6), 6)
        XCTAssertEqual(PackPlan.premiumFirstZoom(packMaxZoom: 18, premiumFromZoom: 17), 19)
        XCTAssertNil(PackPlan.premiumFirstZoom(packMaxZoom: 16, premiumFromZoom: nil))
    }

    func testTilesAreTheBoxOrTheRouteCorridor() throws {
        let box = BoundingBox(54.40, -3.20, 54.50, -3.00)
        XCTAssertEqual(Array(PackPlan.tiles(route: nil, bounds: box, bufferM: 0, grid: .webMercator, minZoom: 12, maxZoom: 14)),
                       Array(TileCoverage.box(box, 12, 14)))
        let start = LatLon(54.45, -3.20)
        let route = (0...20).map { Geo.destination(start, bearingDeg: 60.0, distanceM: Double($0) * 500.0) }
        XCTAssertEqual(Array(PackPlan.tiles(route: route, bounds: box, bufferM: 500, grid: .webMercator, minZoom: 12, maxZoom: 14)),
                       Array(TileCoverage.corridor(route, 500, 12, 14)))
        XCTAssertEqual(Array(PackPlan.tiles(route: route, bounds: nil, bufferM: 500, grid: .britishNationalGrid, minZoom: 3, maxZoom: 5)),
                       Array(TileCoverage.bngCorridor(route, 500, 3, 5)))
        XCTAssertEqual(Array(PackPlan.tiles(route: nil, bounds: box, bufferM: 0, grid: .britishNationalGrid, minZoom: 0, maxZoom: 5)),
                       Array(TileCoverage.bngBox(box, 0, 5)))
        XCTAssertTrue(Array(PackPlan.tiles(route: nil, bounds: nil, bufferM: 0, grid: .webMercator, minZoom: 7, maxZoom: 16)).isEmpty)

        XCTAssertEqual(PackPlan.count(route: nil, box: box, bufferM: 0, grid: .webMercator, from: 7, to: 16), WebMercator.countTiles(box, 7, 16))
        XCTAssertEqual(PackPlan.count(route: route, box: box, bufferM: 500, grid: .webMercator, from: 7, to: 16),
                       TileCoverage.corridorCount(route, 500, 7, 16))
        XCTAssertEqual(PackPlan.count(route: route, box: box, bufferM: 500, grid: .britishNationalGrid, from: 0, to: 5),
                       TileCoverage.bngCorridorCount(route, 500, 0, 5))
        XCTAssertEqual(PackPlan.count(route: nil, box: box, bufferM: 0, grid: .webMercator, from: 17, to: 16), 0)
        // National Grid boxes stop counting just past the limit, so a huge area answers quickly.
        let britain = BoundingBox(50.0, -6.0, 58.5, 1.8)
        XCTAssertEqual(PackPlan.count(route: nil, box: britain, bufferM: 0, grid: .britishNationalGrid, from: 0, to: 9),
                       Int64(TilePolicy.maxTilesPerDownload + 1))
        XCTAssertEqual(PackPlan.count(route: nil, box: BoundingBox(48.80, 2.25, 48.90, 2.40), bufferM: 0, grid: .britishNationalGrid, from: 0, to: 5), 0)
    }

    func testTerrainTilesFollowTheRouteOrTheBox() {
        let start = LatLon(54.45, -3.20)
        let route = (0...10).map { Geo.destination(start, bearingDeg: 30.0, distanceM: Double($0) * 400.0) }
        XCTAssertEqual(Array(PackPlan.terrainTiles(route: route, bounds: nil, bufferM: 50, zoom: 13)),
                       TileCoverage.corridor(route, 100, 13))
        XCTAssertEqual(Array(PackPlan.terrainTiles(route: route, bounds: nil, bufferM: 1000, zoom: 13)),
                       TileCoverage.corridor(route, 1000, 13))
        let box = BoundingBox(54.40, -3.20, 54.50, -3.00)
        XCTAssertEqual(Array(PackPlan.terrainTiles(route: nil, bounds: box, bufferM: 0, zoom: 13)),
                       Array(TileCoverage.box(box.expandedByMetres(100), 13, 13)))
        XCTAssertTrue(Array(PackPlan.terrainTiles(route: [], bounds: nil, bufferM: 0, zoom: 13)).isEmpty)
    }

    func testWordsTheCountsAndSizes() {
        XCTAssertEqual(PackPlan.countText(nil, grid: .webMercator).text, "Counting tiles…")
        let tooMany = PackPlan.countText(25_001, grid: .webMercator)
        XCTAssertTrue(tooMany.tooMany)
        XCTAssertEqual(tooMany.text, "Too large: more than 25000 tiles. Choose a smaller area, a narrower corridor or a lower zoom.")
        XCTAssertFalse(PackPlan.countText(25_000, grid: .webMercator).tooMany)
        XCTAssertEqual(PackPlan.countText(0, grid: .britishNationalGrid).text,
                       "Explorer and Landranger maps only cover Great Britain. Choose an area there.")
        XCTAssertEqual(PackPlan.countText(0, grid: .webMercator).text, "0 tiles · about 0 MB")
        XCTAssertEqual(PackPlan.countText(1000, grid: .webMercator).text, "1000 tiles · about 18 MB")
        XCTAssertEqual(PackPlan.premiumText(512), "512 detail tiles, about 9.0 MB. These requests use OS Premium transactions from your " +
            "plan's allowance. They expire 24 hours after download and are automatically cleaned up. TrailMind asks before then whether to renew them.")
        XCTAssertEqual(PackPlan.lidarText(missing: 0), "The LiDAR within 150 m of this route is already on the phone.")
        XCTAssertEqual(PackPlan.lidarText(missing: 10), "Hill shading, crags and ground heights within 150 m of the route: about 1 MB more.")
        XCTAssertEqual(PackPlan.mb(1023), "0 KB")
        XCTAssertEqual(PackPlan.mb(2048), "2 KB")
        XCTAssertEqual(PackPlan.mb(1_048_576), "1.0 MB")
        XCTAssertEqual(PackPlan.mb(5_500_000), "5.2 MB")
        XCTAssertEqual(PackPlan.statusLabel("COMPLETE"), "Complete")
        XCTAssertEqual(PackPlan.statusLabel("DOWNLOADING"), "Downloading")
        XCTAssertEqual(PackPlan.progressText(done: 10, total: 20, failed: 0), "10 / 20 tiles")
        XCTAssertEqual(PackPlan.progressText(done: 10, total: 20, failed: 3), "10 / 20 tiles · 3 failed")
        XCTAssertEqual(PackPlan.premiumLabel(sourceId: TileSources.osLeisure, premiumMaxZoom: 6), "Landranger detail")
        XCTAssertEqual(PackPlan.premiumLabel(sourceId: TileSources.osLeisure, premiumMaxZoom: 9), "Explorer detail")
        XCTAssertEqual(PackPlan.premiumLabel(sourceId: TileSources.osOutdoor, premiumMaxZoom: 18), "Closer detail to zoom 18")
        XCTAssertEqual(PackPlan.renewalBody(packName: "Parkend", toFetch: 340),
                       "Parkend: renew it for another 24 hours? This downloads 340 detail tiles from your OS plan.")
        XCTAssertEqual(PackPlan.downloadAgainText(tiles: 12, label: "Explorer detail"),
                       "This downloads 12 tiles of Explorer detail using OS Premium transactions from your plan. " +
                        "They expire 24 hours after download, and TrailMind asks before then.")
    }

    func testSumsUpTwentyFourHourDetail() {
        let hour: Int64 = 3_600_000
        let now = 100 * hour
        let detail = PackPlan.premiumDetail([now - hour, now - 5 * hour, 0, now - 25 * hour], now: now)
        XCTAssertEqual(detail, PackPlan.PremiumDetail(expiresAtMs: now + 19 * hour, complete: false, tiles: 4, toFetch: 3))
        XCTAssertEqual(PackPlan.premiumDetail([now - hour, now - 2 * hour], now: now),
                       PackPlan.PremiumDetail(expiresAtMs: now + 22 * hour, complete: true, tiles: 2, toFetch: 0))
        XCTAssertEqual(PackPlan.premiumDetail([Int64](), now: now), PackPlan.PremiumDetail(expiresAtMs: 0, complete: false, tiles: 0, toFetch: 0))
        XCTAssertEqual(PackPlan.premiumDetail([0, 0], now: now), PackPlan.PremiumDetail(expiresAtMs: 0, complete: false, tiles: 2, toFetch: 2))
    }

    func testAsksOnceForEachDownloadsDetail() {
        let hour: Int64 = 3_600_000
        XCTAssertFalse(PackPlan.alreadyAsked(expiresAtMs: 50 * hour, askedFor: nil))
        XCTAssertTrue(PackPlan.alreadyAsked(expiresAtMs: 50 * hour, askedFor: 50 * hour))
        XCTAssertTrue(PackPlan.alreadyAsked(expiresAtMs: 50 * hour, askedFor: 46 * hour + 1))
        XCTAssertFalse(PackPlan.alreadyAsked(expiresAtMs: 50 * hour, askedFor: 46 * hour))
        XCTAssertFalse(PackPlan.alreadyAsked(expiresAtMs: 74 * hour, askedFor: 50 * hour))
    }

    func testReportsAFinishedDownloadAsTheServiceDoes() {
        func outcome(done: Int64 = 100, failed: Int64 = 0, premiumFailed: Int64 = 0, lidar: Int = 0, cancelled: Bool = false,
                     message: String? = nil, note: String? = nil) -> PackPlan.Outcome {
            PackPlan.outcome(done: done, failed: failed, premiumFailed: premiumFailed, lidarFailed: lidar, cancelled: cancelled,
                             message: message, premiumNote: note)
        }
        let note = "Your OS plan doesn't include closer detail, so only the overview map was saved."
        XCTAssertEqual(outcome(), PackPlan.Outcome(status: "COMPLETE", failed: 0, message: nil))
        XCTAssertEqual(outcome(failed: 3), PackPlan.Outcome(status: "PARTIAL", failed: 3, message: "3 tiles failed; tap Resume to retry."))
        XCTAssertEqual(outcome(done: 0, message: "OS Data Hub API key missing."),
                       PackPlan.Outcome(status: "FAILED", failed: 0, message: "OS Data Hub API key missing."))
        XCTAssertEqual(outcome(done: 5, message: "OS Data Hub API key missing.").status, "PAUSED")
        XCTAssertEqual(outcome(cancelled: true), PackPlan.Outcome(status: "PAUSED", failed: 0, message: nil))
        XCTAssertEqual(outcome(note: note), PackPlan.Outcome(status: "PARTIAL", failed: 0, message: note))
        XCTAssertEqual(outcome(done: 0, note: note).status, "PARTIAL")
        XCTAssertEqual(outcome(lidar: 2, note: note).message, note + " 2 LiDAR squares failed; tap Resume to retry.")
        XCTAssertEqual(outcome(failed: 2, premiumFailed: 1, lidar: 4),
                       PackPlan.Outcome(status: "PARTIAL", failed: 3, message: "3 tiles and 4 LiDAR squares failed; tap Resume to retry."))
        XCTAssertEqual(outcome(lidar: 1), PackPlan.Outcome(status: "PARTIAL", failed: 0, message: "1 LiDAR squares failed; tap Resume to retry."))

        XCTAssertEqual(PackPlan.summary(status: "COMPLETE", done: 812, detailLabel: "Explorer detail", detailUntilText: "tomorrow at 09:12", message: nil),
                       "Complete – 812 tiles. Explorer detail until tomorrow at 09:12.")
        XCTAssertEqual(PackPlan.summary(status: "PAUSED", done: 5, detailLabel: nil, detailUntilText: nil, message: "No internet connection."),
                       "Paused – 5 tiles. No internet connection.")
        XCTAssertEqual(PackPlan.summary(status: "COMPLETE", done: 10, detailLabel: nil, detailUntilText: nil, message: "ignored"),
                       "Complete – 10 tiles")
    }

    func testOffersTheRightWayToCarryOn() {
        XCTAssertEqual(PackPlan.againAction(status: "PAUSED", premiumExpired: false, premiumPartial: false, premiumAgeing: false), "Resume")
        XCTAssertEqual(PackPlan.againAction(status: "COMPLETE", premiumExpired: true, premiumPartial: false, premiumAgeing: false), "Download again")
        XCTAssertEqual(PackPlan.againAction(status: "COMPLETE", premiumExpired: false, premiumPartial: true, premiumAgeing: true), "Download again")
        XCTAssertEqual(PackPlan.againAction(status: "COMPLETE", premiumExpired: false, premiumPartial: false, premiumAgeing: true), "Renew")
        XCTAssertNil(PackPlan.againAction(status: "COMPLETE", premiumExpired: false, premiumPartial: false, premiumAgeing: false))
        XCTAssertEqual(PackPlan.againTitle("Renew"), "Renew for 24 hours?")
        XCTAssertEqual(PackPlan.againTitle("Download again"), "Download again?")
        XCTAssertEqual(PackPlan.againTitle("Resume"), "Use OS Premium transactions?")
    }
}
