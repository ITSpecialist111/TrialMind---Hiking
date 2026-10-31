import Foundation
import UIKit

/// Loads raster tiles (map/TileProvider.kt): offline packs first, then the on-disk browse cache, then the network.
/// OS Premium tiles are kept for 24 hours at most and never served stale; OpenStreetMap tiles are revalidated with
/// If-Modified-Since after seven days, as the OSMF tile policy asks. Past a source's last zoom, or where the OS
/// project refuses Premium zooms (the free plan), the last available tile is shown enlarged.
final class TileLoader {
    static let shared = TileLoader()

    /// Set by the offline-maps feature: a tile from an installed pack, if any.
    var packLookup: ((TileSource, TileKey) -> Data?)?

    static let freshMs: Int64 = 7 * 24 * 3600 * 1000
    static let premiumCacheMs: Int64 = 24 * 3600 * 1000
    static let userAgent: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        return "TrailMind-iOS/\(version) (\(Bundle.main.bundleIdentifier ?? "com.trailmind.ios"); +https://github.com/ITSpecialist111/HikingApp101)"
    }()

    private let session: URLSession
    private let cacheRoot: URL
    private let lock = NSLock()
    private var premiumDeniedIds = Set<String>()
    private var retryAfter: [String: Date] = [:]
    /// Called on the main queue when the OS project refuses Premium, or a key is rejected.
    var onProblem: ((String) -> Void)?

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tiles", isDirectory: true)
    }

    func premiumDenied(_ source: TileSource) -> Bool { lock.withLock { premiumDeniedIds.contains(source.id) } }

    func clearErrors() { lock.withLock { premiumDeniedIds.removeAll(); retryAfter.removeAll() } }

    func apiKey(for source: TileSource) -> String? {
        guard source.requiresKey else { return nil }
        let key = source.keyKind == .os ? Prefs.shared.osApiKey : Prefs.shared.mapTilerKey
        return key.isEmpty ? nil : key
    }

    private func diskURL(_ source: TileSource, _ key: TileKey) -> URL {
        cacheRoot.appendingPathComponent(source.id, isDirectory: true)
            .appendingPathComponent("\(key.z)/\(key.x)/\(key.y).tile")
    }

    private func modifiedMs(_ url: URL) -> Int64? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Loads a tile's image bytes for `key` in the source's own grid. Calls back on an arbitrary queue.
    func load(_ source: TileSource, _ key: TileKey, allowNetwork: Bool = true, completion: @escaping (Data?) -> Void) {
        // Past the source's last zoom: enlarge the last real tile.
        if key.z > source.maxZoom {
            return enlarged(source, key, fromZoom: source.maxZoom, allowNetwork: allowNetwork, completion: completion)
        }
        let premium = source.isPremium(key.z)
        if premium, premiumDenied(source), let from = source.premiumFromZoom, from - 1 >= source.minZoom {
            return enlarged(source, key, fromZoom: from - 1, allowNetwork: allowNetwork, completion: completion)
        }
        if source.canReadFromPack(key.z), let data = packLookup?(source, key) { return completion(data) }
        let file = diskURL(source, key)
        let now = nowMs()
        let age = modifiedMs(file).map { now - $0 } ?? Int64.max
        if premium ? age < TileLoader.premiumCacheMs : age < TileLoader.freshMs, let data = try? Data(contentsOf: file) {
            return completion(data)
        }
        if premium, age != Int64.max { try? FileManager.default.removeItem(at: file) }
        let netAllowed = allowNetwork && !Prefs.shared.offlineOnly
        guard netAllowed, let url = source.url(key, apiKey: apiKey(for: source)) else {
            return completion(!premium ? (try? Data(contentsOf: file)) : nil)
        }
        let retryKey = "\(source.id)/\(key)"
        if let until = lock.withLock({ retryAfter[retryKey] }), until > Date() { return completion(nil) }
        var request = URLRequest(url: url)
        request.setValue(TileLoader.userAgent, forHTTPHeaderField: "User-Agent")
        if !premium, age != Int64.max, let m = modifiedMs(file) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            request.setValue(formatter.string(from: Date(timeIntervalSince1970: Double(m) / 1000)), forHTTPHeaderField: "If-Modified-Since")
        }
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return completion(nil) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data, !data.isEmpty {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                return completion(data)
            }
            if status == 304 {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return completion(try? Data(contentsOf: file))
            }
            if premium && (status == 401 || status == 403) {
                let first = self.lock.withLock { self.premiumDeniedIds.insert(source.id).inserted }
                if first { DispatchQueue.main.async { Prefs.shared.osPremium = false; self.onProblem?("premium") } }
                if let from = source.premiumFromZoom, from - 1 >= source.minZoom {
                    return self.enlarged(source, key, fromZoom: from - 1, allowNetwork: allowNetwork, completion: completion)
                }
                return completion(nil)
            }
            if status == 401 || status == 403 { DispatchQueue.main.async { self.onProblem?("key:\(source.keyKind.rawValue)") } }
            if error != nil || status == 429 || status >= 500 {
                self.lock.withLock { self.retryAfter[retryKey] = Date().addingTimeInterval(30) }
            }
            if premium, status == 200 { DispatchQueue.main.async { Prefs.shared.osPremium = true } }
            completion(!premium ? (try? Data(contentsOf: file)) : nil)
        }.resume()
    }

    /// The quarter (or smaller part) of an ancestor tile at `fromZoom` that covers `key`, scaled up to a full tile.
    private func enlarged(_ source: TileSource, _ key: TileKey, fromZoom: Int, allowNetwork: Bool, completion: @escaping (Data?) -> Void) {
        let dz = key.z - fromZoom
        guard dz > 0, dz <= 8 else { return completion(nil) }
        let parent = TileKey(fromZoom, key.x >> dz, key.y >> dz)
        load(source, parent, allowNetwork: allowNetwork) { data in
            guard let data, let image = UIImage(data: data)?.cgImage else { return completion(nil) }
            let n = 1 << dz
            let w = image.width / n, h = image.height / n
            let crop = CGRect(x: (key.x - parent.x * n) * w, y: (key.y - parent.y * n) * h, width: w, height: h)
            guard w > 0, h > 0, let part = image.cropping(to: crop) else { return completion(nil) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let out = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { ctx in
                ctx.cgContext.interpolationQuality = .medium
                UIImage(cgImage: part).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            }
            completion(out.pngData())
        }
    }

    /// Bytes of the browse cache, for the Offline page.
    func cacheBytes() -> Int64 {
        guard let e = FileManager.default.enumerator(at: cacheRoot, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    func clearCache() { try? FileManager.default.removeItem(at: cacheRoot) }

    /// Deletes Premium tiles older than 24 hours (TilePolicy's purge), run at launch and when returning to the app.
    func purgeExpiredPremium() {
        let sources = TileSources.builtIns()
        let now = nowMs()
        DispatchQueue.global(qos: .utility).async {
            for s in sources where s.premiumFromZoom != nil {
                let dir = self.cacheRoot.appendingPathComponent(s.id, isDirectory: true)
                guard let zooms = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
                for z in zooms { guard let zi = Int(z), s.isPremium(zi) else { continue }
                    let zdir = dir.appendingPathComponent(z, isDirectory: true)
                    guard let e = FileManager.default.enumerator(at: zdir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                    for case let url as URL in e {
                        if let m = self.modifiedMs(url), now - m >= TileLoader.premiumCacheMs { try? FileManager.default.removeItem(at: url) }
                    }
                }
            }
        }
    }
}
