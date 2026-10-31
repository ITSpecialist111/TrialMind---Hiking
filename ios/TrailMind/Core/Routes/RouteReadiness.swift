import Foundation

/// An offline pack as the route readiness check reads it (the PackMeta fields RouteDetailPage.updateReadiness uses).
struct ReadinessPack: Hashable {
    var id: Int64
    var maxZoom: Int
    /// Highest Premium zoom pre-loaded with the pack (0 = none).
    var premiumMaxZoom: Int = 0
    /// When the Premium tiles were last fully loaded (0 = never).
    var premiumMs: Int64 = 0
}

/// The offline-map line of a route's "Ready to go?" check (RouteDetailPage.updateReadiness): how much of the route the
/// base map's saved packs cover, and until when OS Explorer detail pre-loaded with them lasts.
enum RouteReadiness {
    /// Pre-loaded OS Premium detail may be kept for 24 hours.
    static let premiumHoldMs: Int64 = 24 * 3_600_000

    /// Whether `source` can only be read with signal, so saved tiles can't cover a route. Apple's map can't be saved.
    static func needsSignal(_ source: TileSource) -> Bool {
        source.id == TileSources.osm || source.appleMap || (source.isOnline && !source.offlineDownloadAllowed)
    }

    /// Whether offline packs can be downloaded for `source`.
    static func canDownload(_ source: TileSource) -> Bool { source.offlineDownloadAllowed }

    /// The percentage of `points` (the route sampled every 100 m) that the packs cover at their own last zoom, nil when
    /// the source needs signal; and, for OS Explorer & Landranger, when the pre-loaded detail expires.
    /// - `hasTile(pack, key)`: whether `pack` holds `key`, in the source's own grid.
    /// - `premiumCachedAt(key)`: when a Premium tile was cached (epoch ms), or 0 when it is not on the phone.
    static func mapCoverage(source: TileSource, points: [LatLon], packs: [ReadinessPack], nowMs: Int64,
                            hasTile: (ReadinessPack, TileKey) -> Bool,
                            premiumCachedAt: (TileKey) -> Int64) -> (coverage: Int?, untilMs: Int64?) {
        let leisure = source.grid == .britishNationalGrid
        let detailZoom: Int? = leisure ? packs.map(\.premiumMaxZoom).max().flatMap { $0 >= 6 ? $0 : nil } : nil
        func bngTile(_ point: LatLon, _ z: Int) -> TileKey? { OsGrid.fromWgs84(point).map { RouteText.bngTile($0, z) } }

        var coverage: Int? = nil
        if !needsSignal(source) {
            var hits = 0
            for point in points {
                let inPack = packs.contains { pack in
                    let tile = leisure ? bngTile(point, pack.maxZoom) : WebMercator.tileFor(point, pack.maxZoom)
                    return tile.map { hasTile(pack, $0) } ?? false
                }
                guard inPack else { continue }
                if let zoom = detailZoom {
                    guard let tile = bngTile(point, zoom) else { continue }
                    let cachedAt = premiumCachedAt(tile)
                    guard cachedAt > 0 && TilePolicy.premiumCacheFresh(cachedAt, nowMs) else { continue }
                }
                hits += 1
            }
            coverage = TripReadiness.coverage(hits: hits, samples: points.count)
        }

        var until: Int64? = nil
        if let zoom = detailZoom {
            until = points.compactMap { point -> Int64? in
                guard let tile = bngTile(point, zoom) else { return nil }
                let cachedAt = premiumCachedAt(tile)
                return cachedAt > 0 ? cachedAt + premiumHoldMs : nil
            }.min()
        }
        if until == nil && leisure {
            until = packs.filter { $0.premiumMaxZoom >= 6 && $0.premiumMs > 0 }.map { $0.premiumMs + premiumHoldMs }.max()
        }
        return (coverage, until)
    }
}
