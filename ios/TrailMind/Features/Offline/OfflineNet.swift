import Foundation
import Network

/// Network access for offline maps and search, with TrailMind's User-Agent on every request (TileProvider.fetchNetwork,
/// OsNames.get and What3words.get on Android).
final class OfflineNet: NSObject, URLSessionTaskDelegate {
    static let shared = OfflineNet()

    /// The answer to one tile request (TileProvider.Fetch).
    enum Fetch {
        case ok(Data, fetchedAtMs: Int64)
        case http(Int)
        case error(String)
        case noNetwork
        case noKey
    }

    private let monitor = NWPathMonitor()
    private var pathSatisfied = true
    private var started = false
    private let lock = NSLock()
    private lazy var tileSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Two requests at a time, as Android's tile provider allows.
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    /// what3words answers must not be redirected anywhere else.
    private lazy var noRedirectSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private lazy var plainSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.pathSatisfied = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "trailmind.offline.path"))
    }

    /// Maps, names and downloads need a connection, and none is used when the user chose Offline only. iPhone can't tell
    /// a satellite link apart, so unlike Android this doesn't hold downloads back on one.
    func networkAllowed() -> Bool {
        if Prefs.shared.offlineOnly { return false }
        return lock.withLock { pathSatisfied }
    }

    // MARK: Tiles

    /// One tile from the network, following the source's template with its key filled in. Premium answers keep the
    /// plan flag up to date as Android does: a refused Premium zoom means OpenData only, a served one means Premium.
    func fetchTile(_ source: TileSource, _ key: TileKey, ifModifiedSinceMs: Int64 = 0, completion: @escaping (Fetch) -> Void) {
        guard let template = source.template else { return completion(.error("offline source")) }
        if !networkAllowed() { return completion(.noNetwork) }
        let apiKey = source.requiresKey ? TileLoader.shared.apiKey(for: source) : nil
        if source.requiresKey && apiKey == nil { return completion(.noKey) }
        guard let url = URL(string: TilePolicy.fillTemplate(template, key, apiKey)) else { return completion(.error("Bad tile address")) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(TileLoader.userAgent, forHTTPHeaderField: "User-Agent")
        // An expired cached tile is asked for conditionally, as the OSM tile policy expects: 304 means keep it.
        if ifModifiedSinceMs > 0 { request.setValue(Self.httpDate(ifModifiedSinceMs), forHTTPHeaderField: "If-Modified-Since") }
        let premium = source.isPremium(key.z)
        let keyed = source.requiresKey
        tileSession.dataTask(with: request) { data, response, error in
            if let error { return completion(.error(error.localizedDescription)) }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            // OSM serves its "Access blocked" image with HTTP 200; it must never be kept as a tile.
            if http?.value(forHTTPHeaderField: "x-blocked") != nil { return completion(.http(403)) }
            if code == 304 { return completion(.http(304)) }
            if code != 200 {
                if code == 403 && premium {
                    DispatchQueue.main.async { if Prefs.shared.osPremium { Prefs.shared.osPremium = false } }
                }
                return completion(.http(code))
            }
            if premium && keyed {
                DispatchQueue.main.async { if !Prefs.shared.osPremium { Prefs.shared.osPremium = true } }
            }
            guard let data else { return completion(.error("network error")) }
            if data.count > PackPlan.maxTileBytes { return completion(.error("tile too large")) }
            completion(.ok(data, fetchedAtMs: nowMs()))
        }.resume()
    }

    private final class FetchBox {
        var value: Fetch = .error("network error")
    }

    /// The same, waiting for the answer: for the download thread only, never the main thread.
    func fetchTileSync(_ source: TileSource, _ key: TileKey) -> Fetch {
        let box = FetchBox()
        let done = DispatchSemaphore(value: 0)
        fetchTile(source, key) { result in
            box.value = result
            done.signal()
        }
        done.wait()
        return box.value
    }

    func fetchTile(_ source: TileSource, _ key: TileKey) async -> Fetch {
        await withCheckedContinuation { continuation in
            fetchTile(source, key) { continuation.resume(returning: $0) }
        }
    }

    static func httpDate(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: Text requests (OS Names, what3words)

    struct TextFailure: Error {
        /// HTTP status, or nil when the request never got an answer.
        let status: Int?
        let tooLarge: Bool
    }

    /// A GET for a JSON answer: the body as text, or the status that refused it.
    func getText(_ url: URL, timeoutMs: Int, maxBytes: Int, headers: [String: String] = [:], allowRedirects: Bool = true) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: Double(timeoutMs) / 1000)
        request.setValue(TileLoader.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = allowRedirects ? plainSession : noRedirectSession
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TextFailure(status: nil, tooLarge: false)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { throw TextFailure(status: code, tooLarge: false) }
        if data.count > maxBytes { throw TextFailure(status: nil, tooLarge: true) }
        return String(decoding: data, as: UTF8.self)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: OS Names

    /// Place search with the user's OS key.
    func searchOsNames(_ query: String, key: String) async throws -> [OsNames.Place] {
        if KotlinText.isBlank(key) { throw OsNames.Failure(message: OsNames.noKey) }
        guard let url = URL(string: OsNames.findURL(query, key)) else { throw OsNames.Failure(message: OsNames.unreachable) }
        do {
            let body = try await getText(url, timeoutMs: OsNames.searchConnectMs + OsNames.searchReadMs, maxBytes: OsNames.maxResponseBytes)
            return try OsNames.parse(body)
        } catch let failure as TextFailure {
            if failure.tooLarge { throw OsNames.Failure(message: OsNames.tooLarge) }
            throw OsNames.Failure(message: failure.status.map(OsNames.httpError) ?? OsNames.unreachable)
        }
    }

    /// A name for a downloaded area from the settlement, else hill, wood or water, nearest its centre; nil if OS Names
    /// has none or cannot be reached.
    func areaName(_ box: BoundingBox, key: String) async -> String? {
        guard let point = OsNames.nearestPoint(box) else { return nil }
        for filter in OsNames.areaFilters {
            guard let url = URL(string: OsNames.nearestURL(point, key, filter)) else { return nil }
            do {
                let body = try await getText(url, timeoutMs: OsNames.nearestTimeoutMs, maxBytes: OsNames.maxResponseBytes)
                if let entry = try OsNames.parseNearest(body) { return OsNames.areaName(entry, box) }
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: what3words

    /// Converts ///three.words to a position with the user's own what3words key.
    func searchThreeWords(_ input: String, key: String) async throws -> ThreeWordsSearch.Address {
        let request = try ThreeWordsSearch.requestURL(input)
        if KotlinText.isBlank(key) { throw ThreeWordsSearch.Failure(message: ThreeWordsSearch.noKey) }
        guard let url = URL(string: request.url) else { throw ThreeWordsSearch.Failure(message: ThreeWordsSearch.unreachable) }
        do {
            let body = try await getText(url, timeoutMs: ThreeWordsSearch.connectMs + ThreeWordsSearch.readMs,
                                         maxBytes: ThreeWordsSearch.maxResponseBytes, headers: ["X-Api-Key": key], allowRedirects: false)
            return try ThreeWordsSearch.parse(body, requested: request.words)
        } catch let failure as TextFailure {
            if failure.tooLarge { throw ThreeWordsSearch.Failure(message: ThreeWordsSearch.tooLarge) }
            throw ThreeWordsSearch.Failure(message: failure.status.map(ThreeWordsSearch.httpError) ?? ThreeWordsSearch.unreachable)
        }
    }
}
