import Combine
import Foundation
import UIKit

/// Live progress of the download that is running (DownloadState on Android).
struct PackProgress: Equatable {
    var packId: Int64
    var done: Int64
    var total: Int64
    var failed: Int64
    /// What the download is doing beyond map tiles ("Saving 1 m LiDAR for …").
    var note: String? = nil
}

/// The offline packs on this phone (the pack side of TileProvider on Android): the list, the MBTiles files in
/// Application Support/packs, tiles from them for the map, their outlines and 24-hour detail, and deleting them.
/// Downloads are PackDownloader's; imports are in PackImport.swift.
final class OfflinePacks: ObservableObject {
    static let shared = OfflinePacks()

    /// Every pack, newest first.
    @Published private(set) var packs: [PackMeta] = []
    /// The running download; nil when none is.
    @Published private(set) var progress: PackProgress? = nil
    /// Changes whenever a pack is added or removed or its tiles change, so outlines and pages refresh.
    @Published private(set) var revision = 0

    /// Where packs are kept: Application Support/packs, left out of iCloud backups as the hike database is.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    static func fileURL(_ fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    private let lock = NSLock()
    private var current: [PackMeta] = []
    private var handles: [Int64: MbTilesFile] = [:]
    private var footprints: [Int64: (stamp: String, footprint: TileFootprint?)] = [:]
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    let queue = DispatchQueue(label: "trailmind.offline.packs", qos: .userInitiated)

    func start() {
        guard !started else { return }
        started = true
        // A download that was running when TrailMind last stopped can't still be: show it paused, ready to resume.
        for p in Store.shared.packs() where p.kind == .download && (p.status == .downloading || p.status == .queued) {
            Store.shared.updatePack(p.id, ["status": .text(PackStatus.paused.rawValue)])
        }
        reloadNow()
        TileLoader.shared.packLookup = { [weak self] source, key in self?.tile(source, key) }
        Store.shared.$revision
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    // MARK: The list

    /// Re-reads the pack list off the main thread.
    func reload() { queue.async { self.reloadNow() } }

    /// Re-reads the pack list now, on any thread (TileProvider.reloadPacks); the published list follows on the main queue.
    func reloadNow() {
        let list = Store.shared.packs()
        let changed: Bool = lock.withLock {
            let ids = Set(list.map(\.id))
            for id in Array(handles.keys) where !ids.contains(id) {
                handles[id] = nil
                footprints[id] = nil
            }
            if list == current { return false }
            current = list
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async {
            self.packs = self.snapshot()
            self.revision &+= 1
        }
    }

    /// The pack list as last read, for any thread.
    func snapshot() -> [PackMeta] { lock.withLock { current } }

    /// Packs whose tiles serve `source`: its own file for an imported map, otherwise every download of that source.
    func packsFor(_ source: TileSource) -> [PackMeta] {
        let list = snapshot()
        if let id = source.packId { return list.filter { $0.id == id } }
        return list.filter { $0.kind == .download && $0.sourceId == source.id }
    }

    /// Published from the download thread.
    func setProgress(_ p: PackProgress?) {
        DispatchQueue.main.async { if self.progress != p { self.progress = p } }
    }

    // MARK: Files and tiles

    /// A tile from an installed pack, for the map (TileLoader.packLookup). Any thread.
    func tile(_ source: TileSource, _ key: TileKey) -> Data? {
        for p in packsFor(source) where key.z >= p.minZoom && key.z <= p.maxZoom {
            if let data = handle(p)?.tile(key) { return data }
        }
        return nil
    }

    /// The pack's open file, shared by the map and the download that fills it (TileProvider.openPack).
    func handle(_ p: PackMeta) -> MbTilesFile? {
        lock.lock()
        defer { lock.unlock() }
        if let h = handles[p.id] { return h }
        let url = Self.fileURL(p.fileName)
        guard FileManager.default.fileExists(atPath: url.path), let h = try? MbTilesFile.open(url) else { return nil }
        handles[p.id] = h
        return h
    }

    func closePack(_ id: Int64) {
        lock.withLock {
            handles[id] = nil
            footprints[id] = nil
        }
    }

    /// The pack's coverage for its outline on the map, kept until its tiles change. Reads the file: not on the main thread.
    func footprint(_ p: PackMeta) -> TileFootprint? {
        let stamp = "\(p.tileDone):\(p.status.rawValue)"
        if let cached = lock.withLock({ footprints[p.id] }), cached.stamp == stamp { return cached.footprint }
        let f = handle(p)?.footprint(maxTiles: PackPlan.maxFootprintTiles)
        lock.withLock { footprints[p.id] = (stamp, f) }
        return f
    }

    /// The tiles `meta` covers at these zooms, or nil when its route was deleted (DownloadService.tilesFor).
    func tiles(_ meta: PackMeta, _ source: TileSource, from minZoom: Int, to maxZoom: Int) -> AnySequence<TileKey>? {
        var route: [LatLon]? = nil
        if let routeId = meta.routeId {
            guard let data = Store.shared.routeData(routeId) else { return nil }
            route = data.points.map { $0.latLon() }
        }
        return PackPlan.tiles(route: route, bounds: meta.bounds, bufferM: meta.bufferM, grid: source.grid, minZoom: minZoom, maxZoom: maxZoom)
    }

    /// A pack's 24-hour detail (PremiumRenewal.detail): nil without any, or when its route was deleted. Reads tile files.
    func premiumDetail(_ pack: PackMeta, custom: TileSource?, packs: [PackMeta], now: Int64 = nowMs()) -> PackPlan.PremiumDetail? {
        guard pack.kind == .download, pack.premiumMaxZoom > 0 else { return nil }
        let source = OfflineSources.byId(pack.sourceId, custom: custom, packs)
        guard let first = PackPlan.premiumFirstZoom(packMaxZoom: pack.maxZoom, premiumFromZoom: source.premiumFromZoom),
              let tiles = tiles(pack, source, from: first, to: pack.premiumMaxZoom) else { return nil }
        return PackPlan.premiumDetail(tiles.lazy.map { TileCache.premiumCachedAt(source, $0) }, now: now)
    }

    // MARK: Deleting

    /// Deletes a pack and its file (the Offline page's Delete), then has the map load its tiles again.
    func delete(_ pack: PackMeta, completion: @escaping () -> Void) {
        if Prefs.shared.offlineMapSourceId == "pack:\(pack.id)" { Prefs.shared.offlineMapSourceId = "" }
        queue.async {
            self.closePack(pack.id)
            let path = Self.fileURL(pack.fileName).path
            for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            Store.shared.deletePack(pack.id)
            self.reloadNow()
            OfflineNotifications.shared.dismissRenewal(pack.id)
            OfflineNotifications.shared.reschedule()
            DispatchQueue.main.async {
                Self.refreshMap()
                completion()
            }
        }
    }

    /// New or removed tiles show: forget the map's tile errors and have it ask for its tiles again. Main thread.
    static func refreshMap() {
        TileLoader.shared.clearErrors()
        TileLoader.shared.onRetryDue?()
    }

    /// Bytes of a pack's file on the phone.
    static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
