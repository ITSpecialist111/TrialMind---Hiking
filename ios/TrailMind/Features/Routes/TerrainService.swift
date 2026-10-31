import CoreGraphics
import Foundation
import MapKit
import UIKit

/// Permanent, bounded cache and shared access to the Mapzen Terrarium terrain tiles (TerrainProvider.kt): heights
/// for routes and the long-press menu, and the steep-ground shading. Safe to use from any thread.
final class TerrainService {
    static let shared = TerrainService()

    private final class Grid { let values: [Float]; init(_ v: [Float]) { values = v } }
    private final class Slope { let image: CGImage; init(_ i: CGImage) { image = i } }

    private let root = RouteFiles.folder("terrain")
    private let permits = DispatchSemaphore(value: 2)
    private let slopeWorkers = DispatchSemaphore(value: 2)
    private let lock = NSLock()
    private var writes = 0
    private var slopeRetryAt: [TileKey: Int64] = [:]
    private let grids = NSCache<NSString, Grid>()
    private let slopes = NSCache<NSString, Slope>()

    private static let gridCacheBytes = 20 * 256 * 256 * 4
    private static let slopeTiles = 64

    /// Where map tiles for the terrain overlays are made: a few at a time, so waiting on downloads never ties up
    /// more threads than that.
    static let overlayQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        q.name = "trailmind-terrain-overlays"
        return q
    }()

    init() {
        grids.totalCostLimit = Self.gridCacheBytes
        slopes.countLimit = Self.slopeTiles
    }

    private static func name(_ key: TileKey) -> NSString { "\(key.z)/\(key.x)/\(key.y)" as NSString }

    /// Height at a point, downloading its tile when allowed; nil where there is none.
    func sample(_ at: LatLon, allowNetwork: Bool = true) -> Double? {
        Terrain.heightAt(at.lat, at.lon) { key in grid(key, allowNetwork: allowNetwork) }
    }

    /// The points with missing heights filled from the terrain model.
    func fill(_ points: [TrackPoint], allowNetwork: Bool = true) -> [TrackPoint] {
        Terrain.fillMissingHeights(points) { sample($0, allowNetwork: allowNetwork) }
    }

    /// A terrain tile's heights from memory, the phone or the network.
    func grid(_ key: TileKey, allowNetwork: Bool = true) -> [Float]? {
        guard TerrainSource.isTerrainTile(key) else { return nil }
        if let cached = grids.object(forKey: Self.name(key)) { return cached.values }
        let file = self.file(key)
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return decode(file).map { remember(key, $0) }
        }
        if !allowNetwork || !RouteNetwork.shared.networkAllowed { return nil }
        guard let bytes = fetch(key), write(file, bytes) else { return nil }
        return decode(file).map { remember(key, $0) }
    }

    private func remember(_ key: TileKey, _ values: [Float]) -> [Float] {
        grids.setObject(Grid(values), forKey: Self.name(key), cost: values.count * 4)
        return values
    }

    /// Saves the terrain tiles for an offline pack; already saved tiles are skipped without decoding them.
    func download(_ keys: AnySequence<TileKey>, cancelled: () -> Bool = { false }) -> (saved: Int, failed: Int) {
        var saved = 0
        var failed = 0
        for key in keys {
            if cancelled() { break }
            if FileManager.default.fileExists(atPath: file(key).path) || grid(key, allowNetwork: true) != nil { saved += 1 } else { failed += 1 }
        }
        return (saved, failed)
    }

    // MARK: Steep ground

    /// The steep-ground shading of a terrain tile, built if need be; nil while its heights cannot be had.
    func slopeTile(_ key: TileKey) -> CGImage? {
        guard key.z == Terrain.zoom else { return nil }
        if let cached = slopes.object(forKey: Self.name(key)) { return cached.image }
        // Without this, every redraw would retry a tile that is not on the phone and cannot be fetched.
        if lock.withLock({ (slopeRetryAt[key] ?? 0) > nowMs() }) { return nil }
        slopeWorkers.wait()
        defer { slopeWorkers.signal() }
        if let cached = slopes.object(forKey: Self.name(key)) { return cached.image }
        guard let image = buildSlopeTile(key) else {
            lock.withLock { slopeRetryAt[key] = nowMs() + TerrainSource.slopeRetryMs }
            return nil
        }
        slopes.setObject(Slope(image), forKey: Self.name(key))
        lock.withLock { slopeRetryAt[key] = nil }
        return image
    }

    private func buildSlopeTile(_ key: TileKey) -> CGImage? {
        let worldTiles = 1 << key.z
        let network = RouteNetwork.shared.networkAllowed
        guard let centre = grid(key, allowNetwork: network) else { return nil }
        let padded = Terrain.padded(centre) { dx, dy in
            let y = key.y + dy
            return (0..<worldTiles).contains(y) ? grid(TileKey(key.z, kMod(key.x + dx, worldTiles), y), allowNetwork: network) : nil
        }
        let classes = Terrain.slopeClasses(padded, Terrain.tileSize) { row in
            Terrain.metresPerPixel(WebMercator.yToLat(Double(key.y * Terrain.tileSize + row) + 0.5, Double(key.z)), key.z)
        }
        return RouteImages.image(argb: TerrainSource.slopeArgb(classes), width: Terrain.tileSize, height: Terrain.tileSize)
    }

    // MARK: Files

    private func file(_ key: TileKey) -> URL { root.appendingPathComponent("\(key.z)/\(key.x)/\(key.y).png") }

    private func decode(_ file: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: file),
              let pixels = RouteImages.argbPixels(data, width: Terrain.tileSize, height: Terrain.tileSize) else { return nil }
        return Terrain.decodeTerrarium(pixels)
    }

    private func fetch(_ key: TileKey) -> Data? {
        permits.wait()
        defer { permits.signal() }
        guard RouteNetwork.shared.networkAllowed, let request = RouteHTTP.get(TerrainSource.url(key), timeout: 15) else { return nil }
        guard let response = try? RouteHTTP.shared.fetch(request, maxBytes: TerrainSource.maxTileBytes, tooLarge: "terrain tile too large"),
              response.status == 200, !response.data.isEmpty else { return nil }
        return response.data
    }

    private func write(_ file: URL, _ bytes: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
        } catch {
            return false
        }
        let count = lock.withLock { () -> Int in
            writes += 1
            return writes
        }
        if count % 32 == 0 { trimDiskCache() }
        return true
    }

    /// Keeps the saved tiles under 200 MB, dropping the least recently used.
    func trimDiskCache() {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            files.append((url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
        }
        var bytes = files.reduce(Int64(0)) { $0 + $1.size }
        if bytes <= TerrainSource.maxDiskBytes { return }
        for f in files.sorted(by: { $0.date < $1.date }) {
            if bytes <= TerrainSource.maxDiskBytes * 9 / 10 { break }
            bytes -= f.size
            try? FileManager.default.removeItem(at: f.url)
        }
    }
}

/// Steep ground (25° and steeper) shaded over the map from zoom 13 (TileMapView.drawSteepGround): each requested
/// tile is cut from the zoom-13 slope tile above it and enlarged. Where there is nothing to shade yet it answers with a
/// transparent tile, never with no data, so MapKit doesn't keep asking.
final class SteepGroundOverlay: MKTileOverlay {
    private let terrain: TerrainService

    init(terrain: TerrainService) {
        self.terrain = terrain
        super.init(urlTemplate: nil)
        minimumZ = Terrain.zoom
        maximumZ = 21
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard path.z >= Terrain.zoom else { return result(EmptyTile.data, nil) }
        TerrainService.overlayQueue.addOperation { [terrain] in
            let dz = path.z - Terrain.zoom
            let parent = TileKey(Terrain.zoom, path.x >> dz, path.y >> dz)
            guard let slope = terrain.slopeTile(parent) else {
                // Its heights aren't on the phone: with signal they may come, so ask again then.
                if RouteNetwork.shared.networkAllowed { TerrainOverlays.shared.retryLater(TerrainOverlays.steepId) }
                return result(EmptyTile.data, nil)
            }
            let n = 1 << dz
            let part = Double(Terrain.tileSize) / Double(n)
            let crop = CGRect(x: Double(path.x - parent.x * n) * part, y: Double(path.y - parent.y * n) * part, width: part, height: part)
            let data = RouteImages.tile(pixels: 256) { cg in
                cg.interpolationQuality = .medium
                // Draw the whole slope tile scaled so the wanted part fills this tile.
                let scale = 256.0 / part
                let rect = CGRect(x: -crop.minX * scale, y: -crop.minY * scale, width: Double(Terrain.tileSize) * scale,
                                  height: Double(Terrain.tileSize) * scale)
                UIImage(cgImage: slope).draw(in: rect)
            }
            result(data ?? EmptyTile.data, nil)
        }
    }
}
