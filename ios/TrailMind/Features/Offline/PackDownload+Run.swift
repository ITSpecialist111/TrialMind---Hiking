import Foundation

/// One pack's download (DownloadService.run): the pack's own tiles into its MBTiles file, then 24-hour Premium detail
/// into the browse cache (OS lets TrailMind keep it for 24 hours only; the pack keeps OpenData only), then terrain
/// heights and 1 m LiDAR along a route when the routes feature provides them.
extension PackDownloader {
    private static let noNetworkMessage = "No internet connection (or offline-only mode is on)."
    private static let backgroundMessage = "Paused when iPhone stopped TrailMind in the background. It carries on when you open TrailMind."

    private struct SaveFailure: Error {
        let message: String
    }

    /// Reads settings on the main thread; the download thread never waits for anything that waits for it.
    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private func sleepMs(_ ms: Int) { Thread.sleep(forTimeInterval: Double(ms) / 1000) }

    func run(_ packId: Int64) {
        let store = Store.shared
        let packs = OfflinePacks.shared
        guard var meta = store.pack(packId) else { return }
        let (custom, packLidar) = onMain { (OfflineSources.custom(Prefs.shared), Prefs.shared.packLidar) }
        let source = OfflineSources.byId(meta.sourceId, custom: custom, packs.snapshot())
        guard let template = source.template, source.offlineDownloadAllowed, !TilePolicy.isBulkDownloadForbidden(template),
              source.id == meta.sourceId else {
            store.updatePackProgress(packId, done: meta.tileDone, failed: meta.tileFailed, bytes: meta.bytes, status: .failed,
                                     message: "This source does not permit offline downloads.")
            return
        }
        if meta.maxZoom > source.effectiveDownloadMaxZoom || meta.premiumMaxZoom > source.maxZoom
            || meta.tileTotal > Int64(TilePolicy.maxTilesPerDownload) {
            store.updatePackProgress(packId, done: meta.tileDone, failed: meta.tileFailed, bytes: meta.bytes, status: .failed,
                                     message: "Download exceeds this source's limits.")
            return
        }
        guard let tiles = packs.tiles(meta, source, from: meta.minZoom, to: meta.maxZoom) else {
            store.updatePackProgress(packId, done: 0, failed: 0, bytes: 0, status: .failed, message: "The route for this pack was deleted.")
            return
        }
        let premiumFrom = max(meta.maxZoom + 1, source.premiumFromZoom ?? Int.max)
        let premiumTiles: AnySequence<TileKey> = meta.premiumMaxZoom >= premiumFrom
            ? (packs.tiles(meta, source, from: premiumFrom, to: meta.premiumMaxZoom) ?? AnySequence([])) : AnySequence([])
        guard let mb = packs.handle(meta) else {
            store.updatePackProgress(packId, done: 0, failed: 0, bytes: 0, status: .failed, message: "Pack file missing.")
            return
        }
        began(packId, name: meta.name)
        defer {
            ended()
            packs.setProgress(nil)
            packs.reloadNow()
        }
        let total = meta.tileTotal
        var done: Int64 = 0
        var failed: Int64 = 0
        var bytes = meta.bytes
        var authFailures = 0
        var noNetwork = 0
        var message: String? = nil
        var stop: Stop? = nil
        func report(_ failedNow: Int64, note: String? = nil) {
            store.updatePackProgress(packId, done: done, failed: failedNow, bytes: bytes, status: .downloading)
            let p = PackProgress(packId: packId, done: done, total: total, failed: failedNow, note: note)
            packs.setProgress(p)
            reportProgress(p, name: meta.name)
        }
        report(0)
        packs.reloadNow()
        do {
            tileLoop: for k in tiles {
                if let s = stopRequested() { stop = s; break }
                if !source.canStoreInPack(k.z) {
                    message = "This source does not permit saving this zoom in an offline pack."
                    break
                }
                if mb.hasTile(k) {
                    done += 1
                    continue
                }
                switch OfflineNet.shared.fetchTileSync(source, k) {
                case .ok(let data, _):
                    do { try mb.putTile(k, data) } catch { throw SaveFailure(message: error.localizedDescription) }
                    bytes += Int64(data.count)
                    done += 1
                    authFailures = 0
                    noNetwork = 0
                case .http(let code):
                    failed += 1
                    if code == 401 || code == 403 { authFailures += 1 }
                    if code == 429 { sleepMs(5_000) }
                case .noKey:
                    message = "OS Data Hub API key missing."
                    break tileLoop
                case .noNetwork:
                    failed += 1
                    noNetwork += 1
                    sleepMs(2_000)
                case .error:
                    failed += 1
                }
                if authFailures >= 3 {
                    message = "Access denied by the tile server. Check your API key and plan."
                    break
                }
                if noNetwork >= 5 {
                    message = Self.noNetworkMessage
                    break
                }
                if (done + failed) % 25 == 0 { report(failed) }
                sleepMs(PackPlan.politeDelayMs)
            }
            // Premium zooms go to the browse cache, which OS allows to keep them for 24 hours; the pack keeps OpenData only.
            var premiumFailed: Int64 = 0
            var premiumNote: String? = nil
            var earliestPremiumMs = Int64.max
            if stop == nil && message == nil {
                premiumLoop: for k in premiumTiles {
                    if let s = stopRequested() { stop = s; break }
                    let cachedAt = TileCache.premiumCachedAt(source, k)
                    if TilePolicy.premiumReusable(cachedAt, nowMs()) {
                        earliestPremiumMs = min(earliestPremiumMs, cachedAt)
                        done += 1
                        continue
                    }
                    switch OfflineNet.shared.fetchTileSync(source, k) {
                    case .ok(let data, let fetchedAtMs):
                        do { try TileCache.storePremium(source, k, data, fetchedAtMs: fetchedAtMs) } catch {
                            throw SaveFailure(message: error.localizedDescription)
                        }
                        earliestPremiumMs = min(earliestPremiumMs, TileCache.premiumCachedAt(source, k))
                        done += 1
                        noNetwork = 0
                    case .http(let code):
                        if code == 401 {
                            message = "OS rejected your API key. Check it in Settings."
                            break premiumLoop
                        }
                        if code == 403 {
                            premiumNote = "Your OS plan doesn't include closer detail, so only the overview map was saved."
                            break premiumLoop
                        }
                        premiumFailed += 1
                        if code == 429 { sleepMs(5_000) }
                    case .noNetwork:
                        premiumFailed += 1
                        noNetwork += 1
                        sleepMs(2_000)
                    case .noKey:
                        message = "OS Data Hub API key missing."
                        break premiumLoop
                    case .error:
                        premiumFailed += 1
                    }
                    if noNetwork >= 5 {
                        message = Self.noNetworkMessage
                        break
                    }
                    if (done + failed + premiumFailed) % 25 == 0 { report(failed + premiumFailed) }
                    sleepMs(PackPlan.politeDelayMs)
                }
            }
            if meta.premiumMaxZoom >= premiumFrom && stop == nil && message == nil && premiumNote == nil && premiumFailed == 0 {
                store.updatePack(packId, ["premium_ms": .int(earliestPremiumMs == Int64.max ? 0 : earliestPremiumMs)])
            }
            var lidarFailed = 0
            if stop == nil && message == nil {
                let routePoints = meta.routeId.flatMap { store.routeData($0)?.points.map { $0.latLon() } }
                if let saveTerrain = FeatureHooks.saveTerrainTiles {
                    let terrain = Array(PackPlan.terrainTiles(route: routePoints, bounds: meta.bounds, bufferM: meta.bufferM, zoom: Terrain.zoom))
                    _ = saveTerrain(terrain) { self.stopRequested() != nil }
                }
                if let routePoints, packLidar, let saveLidar = FeatureHooks.saveLidarSquares {
                    let squares = Lidar.corridor(routePoints.map { OsGrid.project($0) }, PackPlan.lidarCorridorM)
                    let note = "Saving 1 m LiDAR for \(meta.name)"
                    let result = saveLidar(squares, { self.stopRequested() != nil }) { saved in
                        if saved % 8 == 1 {
                            let p = PackProgress(packId: packId, done: Int64(saved), total: Int64(squares.count), failed: 0, note: note)
                            packs.setProgress(p)
                            self.reportProgress(p, name: meta.name)
                        }
                    }
                    lidarFailed = result.failed
                }
                if let s = stopRequested() { stop = s }
            }
            let outcome = PackPlan.outcome(done: done, failed: failed, premiumFailed: premiumFailed, lidarFailed: lidarFailed,
                                           cancelled: stop != nil, message: message, premiumNote: premiumNote)
            var status = PackStatus(rawValue: outcome.status) ?? .paused
            var text = outcome.message
            if stop == .background {
                status = .paused
                text = Self.backgroundMessage
                interrupted(packId)
            }
            store.updatePackProgress(packId, done: done, failed: outcome.failed, bytes: bytes, status: status, message: text)
            meta = store.pack(packId) ?? meta
            if stop == .background { return }
            let detailUntil: Int64? = status == .complete && earliestPremiumMs != Int64.max ? earliestPremiumMs + TilePolicy.premiumCacheMs : nil
            let summary = PackPlan.summary(status: status.rawValue, done: done,
                                           detailLabel: detailUntil.map { _ in PackPlan.premiumLabel(sourceId: meta.sourceId, premiumMaxZoom: meta.premiumMaxZoom) },
                                           detailUntilText: detailUntil.map { OfflineText.atTime($0) }, message: meta.message)
            OfflineNotifications.shared.postFinished(packId, name: meta.name, summary: summary, retry: status == .paused && stop == nil)
        } catch let failure as SaveFailure {
            store.updatePackProgress(packId, done: meta.tileDone, failed: meta.tileFailed, bytes: meta.bytes, status: .paused,
                                     message: failure.message)
        } catch {
            store.updatePackProgress(packId, done: meta.tileDone, failed: meta.tileFailed, bytes: meta.bytes, status: .paused,
                                     message: error.localizedDescription)
        }
    }
}
