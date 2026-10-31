import CoreGraphics
import Foundation
import MapKit
import UIKit

/// The Environment Agency's 1 m LiDAR terrain for England in 256 m grid squares (LidarProvider.kt): saved as the
/// service sends them, decoded on demand, checked along routes, and turned into hill shading with crags for the map.
/// Safe to use from any thread.
final class LidarService {
    static let shared = LidarService()

    private final class Floats { let values: [Float]; init(_ v: [Float]) { values = v } }
    private final class Flags { let values: [Bool]; init(_ v: [Bool]) { values = v } }
    /// A square's shading; no image where LiDAR has no data there.
    private final class Shade { let image: CGImage?; init(_ i: CGImage?) { image = i } }

    private let root = RouteFiles.folder("lidar")
    private let permits = DispatchSemaphore(value: 2)
    private let lock = NSLock()
    private var saved = Set<Lidar.Square>()
    private var indexed = false
    private var started = false
    private var retryAt: [Lidar.Square: Int64] = [:]
    private var inFlight: [Lidar.Square: DispatchGroup] = [:]
    private var stale = Set<Lidar.Square>()
    private var writes = 0
    private let heightsCache = NSCache<NSString, Floats>()
    private let cragsCache = NSCache<NSString, Flags>()
    private let shades = NSCache<NSString, Shade>()

    /// Called on the main queue when squares arrived that already-shaded neighbours need, so the map can redraw.
    var onStale: (() -> Void)?

    init() {
        heightsCache.totalCostLimit = 48 * Lidar.size * Lidar.size * 4
        cragsCache.countLimit = 64
        shades.countLimit = LidarSource.maxVisible + 16
    }

    private static func name(_ s: Lidar.Square) -> NSString { "\(s.col)_\(s.row)" as NSString }

    /// Lists the squares already on the phone.
    func start() {
        let first: Bool = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        guard first else { return }
        DispatchQueue.global(qos: .utility).async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: self.root.path)) ?? []
            let squares = names.compactMap(LidarSource.squareOf)
            self.lock.withLock {
                self.saved.formUnion(squares)
                self.indexed = true
            }
        }
    }

    func isSaved(_ square: Lidar.Square) -> Bool { !square.inExtent || lock.withLock { saved.contains(square) } }

    func missing(_ squares: [Lidar.Square]) -> Int { squares.filter { !isSaved($0) }.count }

    /// The square's heights (empty where LiDAR doesn't cover it) from memory, the phone or the network; nil if unavailable.
    func heights(_ square: Lidar.Square, allowNetwork: Bool) -> [Float]? {
        if !square.inExtent { return [] }
        if let cached = heightsCache.object(forKey: Self.name(square)) { return cached.values }
        let file = self.file(square)
        let (known, isIndexed) = lock.withLock { (saved.contains(square), indexed) }
        if known || (!isIndexed && FileManager.default.fileExists(atPath: file.path)) {
            if let bytes = try? Data(contentsOf: file), let values = decode(bytes, square) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                _ = lock.withLock { saved.insert(square) }
                remember(square, values)
                return values
            }
            try? FileManager.default.removeItem(at: file)
            _ = lock.withLock { saved.remove(square) }
        }
        if !allowNetwork || !RouteNetwork.shared.networkAllowed { return nil }
        // One download per square, however many map tiles and checks want it at once.
        let (group, mine): (DispatchGroup, Bool) = lock.withLock {
            if let g = inFlight[square] { return (g, false) }
            let g = DispatchGroup()
            g.enter()
            inFlight[square] = g
            return (g, true)
        }
        if !mine {
            _ = group.wait(timeout: .now() + 60)
            return heightsCache.object(forKey: Self.name(square))?.values
        }
        defer {
            lock.withLock { inFlight[square] = nil }
            group.leave()
        }
        guard let bytes = fetch(square), let values = decode(bytes, square) else { return nil }
        if write(file, bytes) { _ = lock.withLock { saved.insert(square) } }
        remember(square, values)
        // Neighbours shaded before this square arrived repeated their own edge: shade them again with its heights.
        for dy in -1...1 {
            for dx in -1...1 {
                let near = Lidar.Square(square.col + dx, square.row + dy)
                cragsCache.removeObject(forKey: Self.name(near))
                if near != square, shades.object(forKey: Self.name(near)) != nil {
                    _ = lock.withLock { stale.insert(near) }
                }
            }
        }
        // The map may have drawn this place without it (zoomed out, or before the download): draw it again.
        DispatchQueue.main.async { self.onStale?() }
        return values
    }

    private func remember(_ square: Lidar.Square, _ values: [Float]) {
        heightsCache.setObject(Floats(values), forKey: Self.name(square), cost: max(1, values.count * 4))
    }

    /// Height at a point from LiDAR already on the phone, or nil.
    func sample(_ at: LatLon) -> Double? {
        guard let grid = OsGrid.fromWgs84(at) else { return nil }
        let square = Lidar.squareAt(grid.easting, grid.northing)
        guard let values = heights(square, allowNetwork: false), !values.isEmpty else { return nil }
        return Lidar.height(values, square, grid.easting, grid.northing)
    }

    /// Heights and crags from LiDAR on the phone, for checking a route.
    func ground() -> LidarRouteCheck.Ground { GroundReader(service: self) }

    private struct GroundReader: LidarRouteCheck.Ground {
        let service: LidarService

        func height(_ easting: Double, _ northing: Double) -> Double? {
            let square = Lidar.squareAt(easting, northing)
            guard let values = service.heights(square, allowNetwork: false), !values.isEmpty else { return nil }
            return Lidar.height(values, square, easting, northing)
        }

        func crag(_ easting: Double, _ northing: Double) -> Bool {
            let square = Lidar.squareAt(easting, northing)
            guard let mask = service.cragMask(square) else { return false }
            let col = kTruncate(easting - Double(square.east)).clamped(0, Lidar.size - 1)
            let row = kTruncate(Double(square.north + Lidar.size) - northing).clamped(0, Lidar.size - 1)
            return mask[row * Lidar.size + col]
        }
    }

    private func cragMask(_ square: Lidar.Square) -> [Bool]? {
        if let cached = cragsCache.object(forKey: Self.name(square)) { return cached.values }
        guard let centre = heights(square, allowNetwork: false), !centre.isEmpty else { return nil }
        let mask = Lidar.crags(padded(square, centre))
        cragsCache.setObject(Flags(mask), forKey: Self.name(square))
        return mask
    }

    private func padded(_ square: Lidar.Square, _ centre: [Float]) -> [Float] {
        Lidar.padded(centre) { dx, dy in
            // Rows run south, so the square above (dy = -1) is the next one north.
            heights(Lidar.Square(square.col + dx, square.row - dy), allowNetwork: false).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Saves `squares` for offline use, skipping saved ones; how many are on the phone and how many failed.
    func download(_ squares: [Lidar.Square], cancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in }) -> (ok: Int, failed: Int) {
        var ok = 0
        var failed = 0
        for (i, square) in squares.enumerated() {
            if cancelled() { return (ok, failed) }
            if isSaved(square) || heights(square, allowNetwork: true) != nil { ok += 1 } else { failed += 1 }
            progress(i + 1)
        }
        return (ok, failed)
    }

    // MARK: Shading

    /// The square's shading for the map, built if need be: no image where LiDAR has no data or while its heights are
    /// unavailable, and `missing` in that last case (the square isn't on the phone and couldn't be fetched).
    func shade(_ square: Lidar.Square, allowNetwork: Bool) -> (image: CGImage?, missing: Bool) {
        let isStale = lock.withLock { stale.contains(square) }
        if !isStale, let cached = shades.object(forKey: Self.name(square)) { return (cached.image, false) }
        if !square.inExtent { return (nil, false) }
        if lock.withLock({ (retryAt[square] ?? 0) > nowMs() }) {
            let old = shades.object(forKey: Self.name(square))
            return (old?.image, old == nil)
        }
        _ = lock.withLock { stale.remove(square) }
        guard let centre = heights(square, allowNetwork: allowNetwork) else {
            if allowNetwork { lock.withLock { retryAt[square] = nowMs() + LidarSource.retryMs } }
            // The old shading on screen still lacks its neighbour's edge until a rebuild succeeds.
            if isStale { _ = lock.withLock { stale.insert(square) } }
            let old = shades.object(forKey: Self.name(square))
            return (old?.image, old == nil)
        }
        if centre.isEmpty {
            shades.setObject(Shade(nil), forKey: Self.name(square))
            return (nil, false)
        }
        let p = padded(square, centre)
        // Always worked out afresh: a cached mask may predate a neighbour that has just arrived.
        let mask = Lidar.crags(p)
        cragsCache.setObject(Flags(mask), forKey: Self.name(square))
        let image = RouteImages.image(argb: Lidar.overlay(p, mask), width: Lidar.size, height: Lidar.size)
        shades.setObject(Shade(image), forKey: Self.name(square))
        lock.withLock { retryAt[square] = nil }
        return (image, false)
    }

    // MARK: Files

    private func file(_ square: Lidar.Square) -> URL { root.appendingPathComponent(LidarSource.fileName(square)) }

    private func decode(_ bytes: Data, _ square: Lidar.Square) -> [Float]? {
        guard let raster = try? GeoTiff.read(bytes), var values = Lidar.place(raster, square) else { return nil }
        return Lidar.clean(&values) ? values : []
    }

    private func fetch(_ square: Lidar.Square) -> Data? {
        permits.wait()
        defer { permits.signal() }
        guard RouteNetwork.shared.networkAllowed, let request = RouteHTTP.get(LidarSource.url(square), timeout: 30),
              let response = try? RouteHTTP.shared.fetch(request, maxBytes: LidarSource.maxSquareBytes, tooLarge: "LiDAR square too large"),
              response.status == 200, !response.data.isEmpty else { return nil }
        return response.data
    }

    private func write(_ file: URL, _ bytes: Data) -> Bool {
        do {
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

    func diskBytes() -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return names.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Keeps the saved squares under 300 MB, dropping the least recently used.
    func trimDiskCache() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        var files: [(url: URL, size: Int64, date: Date)] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append((url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
        }
        var bytes = files.reduce(Int64(0)) { $0 + $1.size }
        if bytes <= LidarSource.maxDiskBytes { return }
        for f in files.sorted(by: { $0.date < $1.date }) {
            if bytes <= LidarSource.maxDiskBytes * 9 / 10 { break }
            bytes -= f.size
            if let square = LidarSource.squareOf(f.url.lastPathComponent) {
                _ = lock.withLock { saved.remove(square) }
                heightsCache.removeObject(forKey: Self.name(square))
            }
            try? FileManager.default.removeItem(at: f.url)
        }
    }
}

/// 1 m LiDAR hill shading and crags over the map (TileMapView.drawLidar). Squares already on the phone show from
/// zoom 15; missing ones are downloaded only from zoom 17, where a screen needs a few megabytes, not tens. Each square is
/// drawn through its own corners on the National Grid, edge to edge, so translucent shading never doubles up. Where
/// there is nothing to shade it answers with a transparent tile, never with no data, so MapKit doesn't keep asking.
final class LidarOverlay: MKTileOverlay {
    static let showZoom = 15
    static let fetchZoom = 17
    private let lidar: LidarService

    init(lidar: LidarService) {
        self.lidar = lidar
        super.init(urlTemplate: nil)
        minimumZ = Self.showZoom
        maximumZ = 21
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard path.z >= Self.showZoom else { return result(EmptyTile.data, nil) }
        TerrainService.overlayQueue.addOperation { [lidar] in
            let z = Double(path.z)
            let x0 = Double(path.x) * 256
            let y0 = Double(path.y) * 256
            var minE = Double.greatestFiniteMagnitude, maxE = -Double.greatestFiniteMagnitude
            var minN = Double.greatestFiniteMagnitude, maxN = -Double.greatestFiniteMagnitude
            for i in 0...2 {
                for j in 0...2 {
                    let g = OsGrid.project(LatLon(WebMercator.yToLat(y0 + 128 * Double(j), z), WebMercator.xToLon(x0 + 128 * Double(i), z)))
                    minE = min(minE, g.easting); maxE = max(maxE, g.easting)
                    minN = min(minN, g.northing); maxN = max(maxN, g.northing)
                }
            }
            guard let squares = Lidar.box(minE, minN, maxE, maxN, LidarSource.maxVisible), !squares.isEmpty else {
                return result(EmptyTile.data, nil)
            }
            let fetch = path.z >= Self.fetchZoom && RouteNetwork.shared.networkAllowed
            var shaded: [(Lidar.Square, CGImage)] = []
            var missing = false
            for s in squares {
                let shade = lidar.shade(s, allowNetwork: fetch)
                if let image = shade.image { shaded.append((s, image)) }
                missing = missing || shade.missing
            }
            // A square that couldn't be fetched is tried again after a while, as on Android.
            if missing && fetch { TerrainOverlays.shared.retryLater(TerrainOverlays.lidarId) }
            guard !shaded.isEmpty else { return result(EmptyTile.data, nil) }
            let pixels = 512
            let scale = Double(pixels) / 256
            func point(_ e: Int, _ n: Int) -> CGPoint {
                let p = OsGrid.toWgs84(Double(e), Double(n))
                return CGPoint(x: (WebMercator.lonToX(p.lon, z) - x0) * scale, y: (WebMercator.latToY(p.lat, z) - y0) * scale)
            }
            let data = RouteImages.tile(pixels: pixels) { cg in
                cg.interpolationQuality = .medium
                // Neighbours share their corners exactly, so without antialiased edges they meet with no gap or overlap.
                cg.setShouldAntialias(false)
                for (square, image) in shaded {
                    let tl = point(square.east, square.north + Lidar.size)
                    let tr = point(square.east + Lidar.size, square.north + Lidar.size)
                    let bl = point(square.east, square.north)
                    let w = CGFloat(image.width), h = CGFloat(image.height)
                    let t = CGAffineTransform(a: (tr.x - tl.x) / w, b: (tr.y - tl.y) / w, c: (bl.x - tl.x) / h, d: (bl.y - tl.y) / h,
                                              tx: tl.x, ty: tl.y)
                    cg.saveGState()
                    cg.concatenate(t)
                    UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: w, height: h))
                    cg.restoreGState()
                }
            }
            result(data ?? EmptyTile.data, nil)
        }
    }
}
