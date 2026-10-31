import Combine
import MapKit
import UIKit

/// Offline maps on the map: the base map's packs tinted and outlined where they are on the phone (Map layers → Offline
/// areas; TileMapView.offlineAreas), and an imported map or the custom source from Settings drawn over the base map.
/// Android makes those the base map itself; the iPhone's layers list holds the built-in maps, so they lie over it at
/// full strength, with the base map showing wherever they have no tiles.
final class OfflineMapLayers {
    static let shared = OfflineMapLayers()

    private static let overlayId = "offline.map"
    private static let fillId = "offline-areas-fill"
    private static let edgeId = "offline-areas-edge"
    // TileMapView's offlineFill and offlineEdge.
    private static let fill = UIColor(red: 0, green: 121 / 255, blue: 107 / 255, alpha: 34 / 255)
    private static let edge = UIColor(red: 0, green: 121 / 255, blue: 107 / 255, alpha: 220 / 255)
    /// While a download adds tiles its outline grows; it is redrawn at most this often then.
    private static let downloadRedrawMs: Int64 = 15_000

    private var cancellables = Set<AnyCancellable>()
    private var areasKey: String? = nil
    private var areasJob = 0
    private var lastAreasMs: Int64 = 0
    private var redrawQueued = false
    private var overlayKey: String? = nil
    private let queue = DispatchQueue(label: "trailmind.offline.outlines", qos: .utility)
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Prefs.shared.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        OfflinePacks.shared.$revision
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    func refresh() {
        syncOverlay()
        syncAreas()
    }

    /// The imported pack drawn over the map, if one is chosen and still installed.
    private func overlayPack() -> PackMeta? {
        let id = Prefs.shared.offlineMapSourceId
        guard id.hasPrefix("pack:"), let packId = Int64(id.dropFirst("pack:".count)) else { return nil }
        return OfflinePacks.shared.snapshot().first { $0.id == packId && $0.kind == .importFile }
    }

    // MARK: The map drawn over the base map

    private func syncOverlay() {
        let prefs = Prefs.shared
        let id = prefs.offlineMapSourceId
        var key = ""
        var make: (() -> MKTileOverlay)? = nil
        if let pack = overlayPack() {
            let source = OfflineSources.fromPack(pack)
            key = "pack:\(pack.id)"
            make = { SourceTileOverlay(source: source, replacesMap: false) }
        } else if id == TileSources.custom, let custom = OfflineSources.custom(prefs) {
            key = "custom|\(custom.template ?? "")|\(custom.maxZoom)|\(custom.name)"
            make = { CustomTileOverlay(source: custom) }
        } else if !id.isEmpty {
            // The pack was deleted or the custom source removed.
            prefs.offlineMapSourceId = ""
        }
        guard key != overlayKey else { return }
        overlayKey = key
        MapController.shared.setTileOverlay(Self.overlayId, make?(), alpha: 1, order: -100)
    }

    // MARK: Outlines

    private func syncAreas() {
        let prefs = Prefs.shared
        var packs = prefs.showOfflineAreas ? OfflinePacks.shared.packsFor(OfflineSources.base(prefs)) : []
        if prefs.showOfflineAreas, let pack = overlayPack() { packs.append(pack) }
        let key = packs.map { "\($0.id):\($0.tileDone):\($0.status.rawValue)" }.joined(separator: ",")
        guard key != areasKey else { return }
        let now = nowMs()
        let downloading = OfflinePacks.shared.progress != nil
        if downloading, areasKey != nil, now - lastAreasMs < Self.downloadRedrawMs {
            if !redrawQueued {
                redrawQueued = true
                let wait = Double(Self.downloadRedrawMs - (now - lastAreasMs)) / 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.redrawQueued = false
                    self?.syncAreas()
                }
            }
            return
        }
        areasKey = key
        lastAreasMs = now
        areasJob += 1
        let job = areasJob
        if packs.isEmpty {
            MapController.shared.setAreas(Self.fillId, nil, stroke: .clear, fill: .clear)
            MapController.shared.setAreas(Self.edgeId, nil, stroke: .clear, fill: .clear)
            return
        }
        queue.async {
            var fills: [[LatLon]] = []
            var edges: [[LatLon]] = []
            for p in packs {
                guard let f = OfflinePacks.shared.footprint(p) else { continue }
                let shape = Self.shape(f, nationalGrid: Self.isNationalGrid(p))
                fills += shape.fills
                edges += shape.edges
            }
            DispatchQueue.main.async {
                guard job == self.areasJob else { return }
                MapController.shared.setAreas(Self.fillId, fills, stroke: .clear, fill: Self.fill)
                MapController.shared.setAreas(Self.edgeId, edges, stroke: Self.edge, fill: .clear)
            }
        }
    }

    private static func isNationalGrid(_ p: PackMeta) -> Bool {
        p.kind == .download && TileSources.builtIns().first { $0.id == p.sourceId }?.grid == .britishNationalGrid
    }

    /// A footprint as map polygons: its cells merged into rectangles to tint, and its outline (with holes) to stroke.
    /// National Grid tiles are turned slightly against north, so their outlines bend through every tile corner.
    static func shape(_ f: TileFootprint, nationalGrid: Bool) -> (fills: [[LatLon]], edges: [[LatLon]]) {
        let z = f.zoom
        let corner: (FootprintShape.Corner) -> LatLon = nationalGrid
            ? { c in OsGrid.toWgs84(BngTiles.easting(c.x, z), BngTiles.northing(c.y, z)) }
            : { c in
                let size = Double(WebMercator.tileSize)
                return LatLon(WebMercator.yToLat(Double(c.y) * size, Double(z)), WebMercator.xToLon(Double(c.x) * size, Double(z)))
            }
        let fills = FootprintShape.rects(f).map { FootprintShape.ring($0, everyCorner: nationalGrid).map(corner) }
        let edges = FootprintShape.loops(f, everyCorner: nationalGrid).map { $0.map(corner) }
        return (fills, edges)
    }
}

/// The custom tile source from Settings over the map: tiles from a pack of it first, then ones fetched in the last
/// week, then the network, with the template's {s}, {-y} and {key} filled in as Android does (TilePolicy.fillTemplate).
final class CustomTileOverlay: MKTileOverlay {
    let source: TileSource

    init(source: TileSource) {
        self.source = source
        super.init(urlTemplate: nil)
        minimumZ = max(0, source.minZoom)
        maximumZ = source.maxZoom
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let key = TileKey(path.z, path.x, path.y)
        if let data = OfflinePacks.shared.tile(source, key) { return result(data, nil) }
        let file = TileCache.url(source.id, key)
        let modified = TileCache.modifiedMs(file)
        if let modified, nowMs() - modified < TileCache.freshMs, let data = try? Data(contentsOf: file) { return result(data, nil) }
        OfflineNet.shared.fetchTile(source, key, ifModifiedSinceMs: modified ?? 0) { fetch in
            switch fetch {
            case .ok(let data, _):
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                result(data, nil)
            case .http(304):
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                result((try? Data(contentsOf: file)) ?? EmptyTile.data, nil)
            default:
                // Nothing here, or no signal: an older copy if there is one, else a clear tile so MapKit stops asking.
                result((try? Data(contentsOf: file)) ?? EmptyTile.data, nil)
            }
        }
    }
}
