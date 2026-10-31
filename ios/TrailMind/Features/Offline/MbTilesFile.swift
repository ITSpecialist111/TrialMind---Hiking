import Foundation

/// A minimal MBTiles 1.3 (raster) file on the system SQLite (map/MbTiles.kt). Rows are stored flipped as TMS has them,
/// for National Grid packs too: (2^z - 1) - row, even when that is negative. Safe to share between threads: each call
/// prepares its own statement and the connection is serialised.
final class MbTilesFile {
    let url: URL
    private let db: SQLiteDB
    private let lock = NSLock()

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private init(url: URL, db: SQLiteDB) {
        self.url = url
        self.db = db
    }

    static func open(_ url: URL, readOnly: Bool = false) throws -> MbTilesFile {
        let db = try SQLiteDB(path: url.path, readOnly: readOnly)
        if !readOnly { try? db.exec("PRAGMA synchronous = NORMAL") }
        return MbTilesFile(url: url, db: db)
    }

    /// A new, empty pack with TrailMind's metadata.
    static func create(_ url: URL, name: String, bounds: BoundingBox?, minZoom: Int, maxZoom: Int, attribution: String,
                       grid: TileGrid) throws -> MbTilesFile {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try open(url)
        try file.db.exec("""
            CREATE TABLE IF NOT EXISTS metadata (name TEXT, value TEXT);
            CREATE TABLE IF NOT EXISTS tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
            CREATE UNIQUE INDEX IF NOT EXISTS tile_index ON tiles (zoom_level, tile_column, tile_row);
            DELETE FROM metadata;
            """)
        for (key, value) in MbTilesInfo.metadata(name: name, bounds: bounds, minZoom: minZoom, maxZoom: maxZoom,
                                                 attribution: attribution, grid: grid) {
            try file.db.run("INSERT INTO metadata (name, value) VALUES (?, ?)", [.text(key), .text(value)])
        }
        return file
    }

    func tile(_ k: TileKey) -> Data? {
        lock.withLock {
            (try? db.query("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                           [.int(Int64(k.z)), .int(Int64(k.x)), .int(Int64(k.tmsY))]) { $0.blob(0) })?.first ?? nil
        }
    }

    func hasTile(_ k: TileKey) -> Bool {
        lock.withLock {
            !((try? db.query("SELECT 1 FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1",
                             [.int(Int64(k.z)), .int(Int64(k.x)), .int(Int64(k.tmsY))]) { _ in true }) ?? []).isEmpty
        }
    }

    func putTile(_ k: TileKey, _ data: Data) throws {
        try lock.withLock {
            do {
                try db.run("INSERT OR REPLACE INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?,?,?,?)",
                           [.int(Int64(k.z)), .int(Int64(k.x)), .int(Int64(k.tmsY)), .blob(data)])
            } catch {
                throw Failure(message: "Could not save map tile. Check available storage.")
            }
        }
    }

    func metadata() -> [String: String] {
        lock.withLock {
            var out: [String: String] = [:]
            _ = try? db.query("SELECT name, value FROM metadata") { s in
                if !s.isNull(0) { out[s.text(0)] = s.isNull(1) ? "" : s.text(1) }
            }
            return out
        }
    }

    func tileCount() -> Int64 {
        lock.withLock { (try? db.query("SELECT COUNT(*) FROM tiles") { $0.int(0) })?.first ?? 0 }
    }

    func zoomRange() -> ClosedRange<Int>? {
        lock.withLock {
            (try? db.query("SELECT MIN(zoom_level), MAX(zoom_level) FROM tiles") { s -> ClosedRange<Int>? in
                s.isNull(0) ? nil : Int(s.int(0))...max(Int(s.int(0)), Int(s.int(1)))
            })?.first ?? nil
        }
    }

    private func sampleTile() -> [UInt8]? {
        lock.withLock {
            ((try? db.query("SELECT tile_data FROM tiles LIMIT 1") { $0.blob(0) })?.first ?? nil).map { [UInt8]($0) }
        }
    }

    func info() -> MbTilesInfo.Info {
        MbTilesInfo.info(metadata: metadata(), zoomRange: zoomRange(), sample: sampleTile(), tileCount: tileCount())
    }

    /// The tiles of the most detailed zoom that has at most `maxTiles`, or nil when the file is empty.
    func footprint(maxTiles: Int) -> TileFootprint? {
        lock.withLock {
            // Inlined, not bound: a bound string would compare as TEXT, which is greater than every count.
            guard let z = (try? db.query("SELECT zoom_level FROM tiles GROUP BY zoom_level HAVING COUNT(*) <= \(maxTiles) ORDER BY zoom_level DESC LIMIT 1") {
                Int($0.int(0))
            })?.first else { return nil }
            var xs: [Int] = []
            var ys: [Int] = []
            let lastRow = (1 << z) - 1
            _ = try? db.query("SELECT tile_column, tile_row FROM tiles WHERE zoom_level=?", [.int(Int64(z))]) { s in
                xs.append(Int(s.int(0)))
                ys.append(lastRow - Int(s.int(1)))
            }
            return TileFootprint.of(z, xs, ys)
        }
    }
}
