import Foundation

/// Importing an MBTiles file (MainActivity.importMbtiles) and how much of a route the base map has on the phone
/// (RouteDetailPage.updateReadiness's map coverage).
extension OfflinePacks {
    struct ImportFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Copies an MBTiles file into the app and adds it as a pack, refusing National Grid, vector and empty files.
    /// Calls back on the main queue with the new pack's id and the file's name.
    func importFile(_ source: URL, completion: @escaping (Result<(id: Int64, name: String), Error>) -> Void) {
        let fileTitle = source.deletingPathExtension().lastPathComponent
        let name = KotlinText.isBlank(fileTitle) ? "Imported map" : fileTitle
        queue.async {
            let fileName = "import_\(nowMs()).mbtiles"
            let file = Self.fileURL(fileName)
            let result: Result<(id: Int64, name: String), Error>
            do {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: source, to: file)
                let info: MbTilesInfo.Info = try {
                    let mb = try MbTilesFile.open(file, readOnly: true)
                    if MbTilesInfo.isBritishNationalGrid(mb.metadata()["crs"]) { throw ImportFailure(message: MbTilesInfo.bngRefused) }
                    return mb.info()
                }()
                if info.tileCount <= 0 { throw ImportFailure(message: MbTilesInfo.noTiles) }
                if !MbTilesInfo.rasterFormats.contains(info.format) {
                    throw ImportFailure(message: MbTilesInfo.unsupportedFormat(info.format))
                }
                let packName = info.name.flatMap { KotlinText.isBlank($0) ? nil : $0 } ?? name
                let id = Store.shared.insertPack(name: packName, kind: .importFile, sourceId: "import", fileName: fileName,
                                                 minZoom: info.minZoom, maxZoom: info.maxZoom, bounds: info.bounds, routeId: nil,
                                                 bufferM: 0, tileTotal: info.tileCount, status: .ready, format: info.format,
                                                 attribution: info.attribution)
                Store.shared.updatePackProgress(id, done: info.tileCount, failed: 0, bytes: Self.fileSize(file), status: .ready)
                self.reloadNow()
                result = .success((id: id, name: name))
            } catch let failure as ImportFailure {
                try? FileManager.default.removeItem(at: file)
                result = .failure(failure)
            } catch {
                try? FileManager.default.removeItem(at: file)
                result = .failure(ImportFailure(message: error.localizedDescription))
            }
            // Files handed over with "Open in" are copies in the app's Inbox; the pack is a copy of its own.
            if source.pathComponents.contains("Inbox") { try? FileManager.default.removeItem(at: source) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Imports a file and reports back as Android does: offer to show the new map, or say why it can't be used.
    func importAndReport(_ url: URL) {
        AppModel.shared.toast("Importing offline map…")
        importFile(url) { result in
            switch result {
            case .success(let pack):
                AppModel.shared.choose("Offline map ready", "\"\(pack.name)\" was imported. Show it on the map now?",
                                       options: [("Use it", { OfflineFeature.showImported(pack.id) })], cancel: "Later")
            case .failure(let error):
                AppModel.shared.info("Import failed", error.localizedDescription)
            }
        }
    }

    /// The share of `route` the base map has on the phone in offline packs, nil when the base map can't be saved for
    /// offline use, and when the 24-hour Explorer detail along it expires. Reads pack files: not on the main thread.
    func routeCoverage(_ route: [LatLon], base source: TileSource) -> (percent: Int?, detailUntilMs: Int64?) {
        let points = TripReadiness.sampleRoute(route)
        let packs = packsFor(source)
        let leisure = source.grid == .britishNationalGrid
        let detailZoom: Int? = leisure ? packs.map(\.premiumMaxZoom).max().flatMap { $0 >= 6 ? $0 : nil } : nil
        func bngTile(_ point: LatLon, _ zoom: Int) -> TileKey? {
            OsGrid.fromWgs84(point).map { TileKey(zoom, BngTiles.column($0.easting, zoom), BngTiles.row($0.northing, zoom)) }
        }
        var coverage: Int? = nil
        if !(source.id == TileSources.osm || source.appleMap || (source.isOnline && !source.offlineDownloadAllowed)) {
            var footprints: [Int64: TileFootprint] = [:]
            for p in packs { footprints[p.id] = footprint(p) }
            let hits = points.filter { point in
                let saved = packs.contains { pack in
                    guard let tile = leisure ? bngTile(point, pack.maxZoom) : WebMercator.tileFor(point, pack.maxZoom) else { return false }
                    var inside = true
                    if let f = footprints[pack.id], f.zoom == pack.maxZoom { inside = f.contains(tile.x, tile.y) }
                    return inside && handle(pack)?.hasTile(tile) == true
                }
                guard saved else { return false }
                guard let zoom = detailZoom else { return true }
                return bngTile(point, zoom).map { TileCache.hasFreshPremium(source, $0) } ?? false
            }.count
            coverage = TripReadiness.coverage(hits: hits, samples: points.count)
        }
        let detailExpiry: Int64? = detailZoom.flatMap { zoom in
            points.compactMap { point -> Int64? in
                guard let tile = bngTile(point, zoom) else { return nil }
                let at = TileCache.premiumCachedAt(source, tile)
                return at > 0 ? at + TilePolicy.premiumCacheMs : nil
            }.min()
        }
        let fallback: Int64? = leisure
            ? packs.filter { $0.premiumMaxZoom >= 6 && $0.premiumMs > 0 }.map { $0.premiumMs + TilePolicy.premiumCacheMs }.max() : nil
        return (coverage, detailExpiry ?? fallback)
    }
}
