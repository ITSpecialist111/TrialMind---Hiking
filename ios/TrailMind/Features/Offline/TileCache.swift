import Foundation

/// The browse cache TileLoader keeps under Caches/tiles/<source>/<z>/<x>/<y>.tile, as the offline feature uses it:
/// 24-hour Premium detail pre-loaded by downloads (TileProvider.storePremium/premiumCachedAt), its expiry, and keeping
/// the cache within its limit (TileProvider.trimDiskCache). A tile's modification date is when it was fetched.
enum TileCache {
    static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tiles", isDirectory: true)
    /// Browsed tiles are fresh for a week; old maps are deleted after that (MapTiler's terms).
    static let freshMs: Int64 = 7 * 24 * 3_600_000

    struct StoreFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func url(_ sourceId: String, _ key: TileKey) -> URL {
        root.appendingPathComponent(sourceId, isDirectory: true).appendingPathComponent("\(key.z)/\(key.x)/\(key.y).tile")
    }

    static func modifiedMs(_ url: URL) -> Int64? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// When a cached tile was fetched, or 0 when it is not on the phone (`File.lastModified()`).
    static func premiumCachedAt(_ source: TileSource, _ key: TileKey) -> Int64 { modifiedMs(url(source.id, key)) ?? 0 }

    /// A Premium tile pre-loaded for offline use that is still inside its 24 hours.
    static func hasFreshPremium(_ source: TileSource, _ key: TileKey, now: Int64 = nowMs()) -> Bool {
        let at = premiumCachedAt(source, key)
        return at > 0 && TilePolicy.premiumCacheFresh(at, now)
    }

    /// Keeps a pre-loaded Premium tile in the browse cache, dated when it was fetched, so TileLoader serves it for
    /// 24 hours at most and the purge then deletes it.
    static func storePremium(_ source: TileSource, _ key: TileKey, _ data: Data, fetchedAtMs: Int64) throws {
        precondition(source.isPremium(key.z))
        if !TilePolicy.premiumCacheFresh(fetchedAtMs, nowMs()) { throw StoreFailure(message: "Premium tile has expired") }
        let file = url(source.id, key)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(fetchedAtMs) / 1000)],
                                                  ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw StoreFailure(message: "Could not save Premium tile. Check available storage.")
        }
    }

    private static func premiumFiles() -> [(url: URL, modifiedMs: Int64)] {
        var out: [(URL, Int64)] = []
        for s in TileSources.builtIns() {
            guard let from = s.premiumFromZoom, from <= s.maxZoom else { continue }
            for z in from...s.maxZoom {
                let dir = root.appendingPathComponent(s.id, isDirectory: true).appendingPathComponent(String(z), isDirectory: true)
                guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                else { continue }
                for case let file as URL in e {
                    guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                          values.isRegularFile == true, let date = values.contentModificationDate else { continue }
                    out.append((file, Int64((date.timeIntervalSince1970 * 1000).rounded())))
                }
            }
        }
        return out
    }

    /// Deletes Premium tiles whose 24 hours are up, or will be within `aheadMs` (TileProvider.purgeExpiredPremium).
    static func purgeExpiredPremium(aheadMs: Int64 = 0) {
        let now = nowMs()
        for file in premiumFiles() where TilePolicy.premiumPurgeDue(file.modifiedMs, now, aheadMs) {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// When the oldest Premium tile on the phone was fetched, or nil when there is none.
    static func oldestPremiumMs() -> Int64? { premiumFiles().map(\.modifiedMs).min() }

    /// Keeps the browse cache under its limit by deleting the tiles fetched longest ago, after dropping expired Premium
    /// detail and old maps older than a week (TileProvider.trimDiskCache, run at start-up).
    static func trim() {
        purgeExpiredPremium()
        let cutoff = nowMs() - freshMs
        for s in TileSources.historic() {
            let dir = root.appendingPathComponent(s.id, isDirectory: true)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let file as URL in e {
                if let m = modifiedMs(file), m < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for case let file as URL in e {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            files.append((file, size, v.contentModificationDate ?? .distantPast))
            total += size
        }
        if total <= PackPlan.maxBrowseCacheBytes { return }
        for f in files.sorted(by: { $0.modified < $1.modified }) {
            if total <= PackPlan.maxBrowseCacheBytes * 8 / 10 { break }
            total -= f.size
            try? FileManager.default.removeItem(at: f.url)
        }
    }
}
