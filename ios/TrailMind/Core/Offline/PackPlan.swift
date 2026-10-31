import Foundation

/// Offline-pack planning and wording shared by the Offline page, the downloader and renewal reminders: which tiles a
/// pack needs, how many, what they cost, and how a finished download is reported. From the Android app's
/// ui/Pages3.kt (OfflinePage), map/DownloadService.kt and map/PremiumRenewal.kt.
enum PackPlan {
    /// Typical OS raster PNG tile size; real sizes vary 5–40 KB.
    static let avgTileKb = 18.0
    /// Pause between tile requests, to be a polite client.
    static let politeDelayMs = 60
    /// Corridor widths offered either side of a route, metres.
    static let corridorOptionsM = [250, 500, 1000, 2000]
    /// Routes offered as areas.
    static let maxRouteChoices = 8
    /// 1 m LiDAR saved along a route's offline map, within this distance of it (LidarProvider.PACK_CORRIDOR_M).
    static let lidarCorridorM = 150.0
    /// Rough size of one saved LiDAR square (LidarProvider.SQUARE_BYTES_ESTIMATE).
    static let lidarSquareBytesEstimate: Int64 = 150 * 1024
    /// Terrain-height tiles are saved this far beyond a pack (TerrainProvider.packTiles).
    static let terrainMarginM = 100.0
    /// Most tiles of one zoom read back from a pack to outline it on the map (TileProvider.MAX_FOOTPRINT_TILES).
    static let maxFootprintTiles = 100_000
    /// Browse-cache limit; the oldest tiles go first once it is passed (TileProvider.MAX_DISK_CACHE).
    static let maxBrowseCacheBytes: Int64 = 300 * 1024 * 1024
    /// Tiles larger than this are refused (TileProvider.MAX_TILE_BYTES).
    static let maxTileBytes = 2 * 1024 * 1024

    // MARK: Zooms

    /// Lowest zoom saved: the whole pyramid for National Grid maps, from zoom 7 for Web Mercator ones.
    static func minZoom(_ s: TileSource) -> Int { s.grid == .britishNationalGrid ? s.minZoom : max(s.minZoom, 7) }

    /// The "Most detailed zoom" choices.
    static func zoomOptions(_ s: TileSource) -> [Int] {
        let from = s.grid == .britishNationalGrid ? 5 : 12
        let to = s.effectiveDownloadMaxZoom
        return from <= to ? Array(from...to) : []
    }

    /// Premium zooms to pre-load for 24 hours, or nil when the key has no Premium or it is off.
    static func premiumZooms(_ s: TileSource, osPremium: Bool, premiumMaxZoom: Int) -> ClosedRange<Int>? {
        guard let from = s.premiumFromZoom, osPremium, premiumMaxZoom >= from else { return nil }
        let to = min(premiumMaxZoom, s.maxZoom)
        return to >= from ? from...to : nil
    }

    /// The closer-detail choices: off, or how far to pre-load.
    static func premiumOptions(_ s: TileSource) -> [(label: String, zoom: Int)] {
        guard let from = s.premiumFromZoom else { return [] }
        if s.id == TileSources.osLeisure {
            return [("Off", 0), ("Landranger (zoom 6)", 6), ("Explorer 1:25k (zooms 7–9)", 9)]
        }
        let to = min(from + 2, s.maxZoom)
        return [("Off", 0)] + (from <= to ? (from...to).map { ("to \($0)", $0) } : [])
    }

    static func premiumHeading(_ s: TileSource) -> String {
        s.id == TileSources.osLeisure ? "Explorer 1:25k detail — OS lets you keep this for 24 hours" : "Closer detail (kept 24 hours)"
    }

    static func overviewNote(_ s: TileSource) -> String {
        s.grid == .britishNationalGrid ? "Overview maps (kept): zooms 0–5."
            : "Zoom 15 ≈ 1:18k detail, 16 ≈ 1:9k. Lower zooms (\(minZoom(s))+) are included for overview."
    }

    /// The source chip label: OS maps without their "OS Maps – " prefix.
    static func chipName(_ s: TileSource) -> String {
        s.name.hasPrefix("OS Maps – ") ? String(s.name.dropFirst("OS Maps – ".count)) : s.name
    }

    /// First zoom of 24-hour detail a pack pre-loads: past its own zooms and from the source's first Premium zoom.
    static func premiumFirstZoom(packMaxZoom: Int, premiumFromZoom: Int?) -> Int? {
        premiumFromZoom.map { max(packMaxZoom + 1, $0) }
    }

    // MARK: Tiles

    /// The tiles a pack covers at these zooms: a corridor around its route, otherwise its box.
    static func tiles(route: [LatLon]?, bounds: BoundingBox?, bufferM: Double, grid: TileGrid, minZoom: Int, maxZoom: Int) -> AnySequence<TileKey> {
        if let route {
            return grid == .britishNationalGrid ? TileCoverage.bngCorridor(route, bufferM, minZoom, maxZoom)
                : TileCoverage.corridor(route, bufferM, minZoom, maxZoom)
        }
        guard let bounds else { return AnySequence([]) }
        return grid == .britishNationalGrid ? TileCoverage.bngBox(bounds, minZoom, maxZoom) : TileCoverage.box(bounds, minZoom, maxZoom)
    }

    /// How many tiles a download from `from` to `to` fetches. National Grid boxes are counted only to just past the limit.
    static func count(route: [LatLon]?, box: BoundingBox, bufferM: Double, grid: TileGrid, from: Int, to: Int) -> Int64 {
        if from > to { return 0 }
        if grid == .britishNationalGrid, let route { return TileCoverage.bngCorridorCount(route, bufferM, from, to) }
        if grid == .britishNationalGrid {
            return Int64(TileCoverage.bngBox(box, from, to).prefix(TilePolicy.maxTilesPerDownload + 1).reduce(0) { n, _ in n + 1 })
        }
        if let route { return TileCoverage.corridorCount(route, bufferM, from, to) }
        return WebMercator.countTiles(box, from, to)
    }

    /// The terrain-height tiles saved with a pack (TerrainProvider.packTiles), at `zoom` (Terrain.zoom).
    static func terrainTiles(route: [LatLon]?, bounds: BoundingBox?, bufferM: Double, zoom: Int) -> AnySequence<TileKey> {
        if let route, !route.isEmpty { return AnySequence(TileCoverage.corridor(route, max(bufferM, terrainMarginM), zoom)) }
        guard let bounds else { return AnySequence([]) }
        return TileCoverage.box(bounds.expandedByMetres(terrainMarginM), zoom, zoom)
    }

    // MARK: Wording

    static func countText(_ count: Int64?, grid: TileGrid) -> (text: String, tooMany: Bool) {
        guard let count else { return ("Counting tiles…", false) }
        if count > Int64(TilePolicy.maxTilesPerDownload) {
            return ("Too large: more than \(TilePolicy.maxTilesPerDownload) tiles. Choose a smaller area, a narrower corridor or a lower zoom.", true)
        }
        if count == 0 && grid == .britishNationalGrid {
            return ("Explorer and Landranger maps only cover Great Britain. Choose an area there.", false)
        }
        return ("\(count) tiles · about \(fmt("%.0f", Double(count) * avgTileKb / 1024.0)) MB", false)
    }

    static func premiumText(_ tiles: Int64) -> String {
        "\(tiles) detail tiles, about \(fmt("%.1f", Double(tiles) * avgTileKb / 1024.0)) MB. " +
            "These requests use OS Premium transactions from your plan's allowance. " +
            "They expire 24 hours after download and are automatically cleaned up. TrailMind asks before then whether to renew them."
    }

    static func lidarText(missing: Int) -> String {
        missing == 0 ? "The LiDAR within 150 m of this route is already on the phone."
            : "Hill shading, crags and ground heights within 150 m of the route: about " +
                "\(fmt("%.0f", Double(Int64(missing) * lidarSquareBytesEstimate) / 1_048_576.0)) MB more."
    }

    static func mb(_ bytes: Int64) -> String {
        bytes < 1_048_576 ? "\(bytes / 1024) KB" : fmt("%.1f MB", Double(bytes) / 1_048_576.0)
    }

    /// A pack status as the Offline page shows it ("COMPLETE" → "Complete").
    static func statusLabel(_ raw: String) -> String {
        let lower = raw.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    static func progressText(done: Int64, total: Int64, failed: Int64) -> String {
        "\(done) / \(total) tiles" + (failed > 0 ? " · \(failed) failed" : "")
    }

    /// What a pack's 24-hour detail is called.
    static func premiumLabel(sourceId: String, premiumMaxZoom: Int) -> String {
        if sourceId == TileSources.osLeisure { return premiumMaxZoom == 6 ? "Landranger detail" : "Explorer detail" }
        return "Closer detail to zoom \(premiumMaxZoom)"
    }

    // MARK: 24-hour detail

    /// Earliest expiry of a pack's fresh detail tiles (0 when none), whether all are fresh, how many there are and how
    /// many a download would fetch.
    struct PremiumDetail: Hashable {
        var expiresAtMs: Int64
        var complete: Bool
        var tiles: Int
        var toFetch: Int
    }

    /// Sums up a pack's detail tiles from when each was cached (0 for a tile that is not on the phone).
    static func premiumDetail<S: Sequence>(_ cachedAt: S, now: Int64) -> PremiumDetail where S.Element == Int64 {
        var earliest = Int64.max
        var count = 0
        var fresh = 0
        var toFetch = 0
        for at in cachedAt {
            count += 1
            if TilePolicy.premiumCacheFresh(at, now) {
                fresh += 1
                earliest = min(earliest, at &+ TilePolicy.premiumCacheMs)
            }
            if !TilePolicy.premiumReusable(at, now) { toFetch += 1 }
        }
        return PremiumDetail(expiresAtMs: fresh > 0 ? earliest : 0, complete: count > 0 && fresh == count, tiles: count, toFetch: toFetch)
    }

    /// Tiles from one download expire within this window of each other, so one question covers them all.
    static func alreadyAsked(expiresAtMs: Int64, askedFor: Int64?) -> Bool {
        guard let askedFor else { return false }
        return expiresAtMs - askedFor < TilePolicy.premiumCacheMs - TilePolicy.premiumReuseMinLeftMs
    }

    static func renewalBody(packName: String, toFetch: Int) -> String {
        "\(packName): renew it for another 24 hours? This downloads \(toFetch) detail tiles from your OS plan."
    }

    static func downloadAgainText(tiles: Int, label: String) -> String {
        "This downloads \(tiles) tiles of \(label) using OS Premium transactions from your plan. " +
            "They expire 24 hours after download, and TrailMind asks before then."
    }

    // MARK: Finishing a download

    /// Status and message for a finished run, as DownloadService decides them. Statuses are `PackStatus` raw values.
    struct Outcome: Equatable {
        var status: String
        var failed: Int64
        var message: String?
    }

    static func outcome(done: Int64, failed tileFailed: Int64, premiumFailed: Int64, lidarFailed: Int, cancelled: Bool,
                        message originalMessage: String?, premiumNote: String?) -> Outcome {
        let failed = tileFailed + premiumFailed
        let message = originalMessage ?? premiumNote
        let blocking = message != nil && message != premiumNote
        let status: String
        if blocking && done == 0 {
            status = "FAILED"
        } else if cancelled || blocking {
            status = "PAUSED"
        } else if premiumNote != nil || failed > 0 || lidarFailed > 0 {
            status = "PARTIAL"
        } else {
            status = "COMPLETE"
        }
        let lidarNote = lidarFailed > 0 ? "\(lidarFailed) LiDAR squares failed; tap Resume to retry." : nil
        let text: String?
        if let message, message == premiumNote, let lidarNote {
            text = "\(message) \(lidarNote)"
        } else if let message {
            text = message
        } else if failed > 0 && lidarFailed > 0 {
            text = "\(failed) tiles and \(lidarFailed) LiDAR squares failed; tap Resume to retry."
        } else if failed > 0 {
            text = "\(failed) tiles failed; tap Resume to retry."
        } else {
            text = lidarNote
        }
        return Outcome(status: status, failed: failed, message: text)
    }

    /// The finished-download notification text: "Complete – 812 tiles. Explorer detail until tomorrow at 09:12."
    static func summary(status: String, done: Int64, detailLabel: String?, detailUntilText: String?, message: String?) -> String {
        var text = "\(statusLabel(status)) – \(done) tiles"
        if let detailLabel, let detailUntilText {
            text += ". \(detailLabel) until \(detailUntilText)."
        } else if status != "COMPLETE", let message {
            text += ". \(message)"
        }
        return text
    }

    /// The button that carries a download pack on: resume an unfinished one, fetch expired or missing detail again,
    /// or renew detail before it expires; nil when there is nothing to do.
    static func againAction(status: String, premiumExpired: Bool, premiumPartial: Bool, premiumAgeing: Bool) -> String? {
        if status != "COMPLETE" { return "Resume" }
        if premiumExpired || premiumPartial { return "Download again" }
        if premiumAgeing { return "Renew" }
        return nil
    }

    static func againTitle(_ action: String) -> String {
        switch action {
        case "Renew": return "Renew for 24 hours?"
        case "Download again": return "Download again?"
        default: return "Use OS Premium transactions?"
        }
    }
}
