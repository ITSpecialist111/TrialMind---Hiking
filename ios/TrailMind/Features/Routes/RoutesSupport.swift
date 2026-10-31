import Combine
import Foundation
import Network

extension Prefs {
    /// The walking pace from Settings, or the defaults when a stored value is out of range (Android's `Prefs.pace`).
    var routePace: PaceSettings {
        (try? PaceSettings(flatSpeedKmh: flatSpeedKmh, conditionsFactor: conditionsFactor)) ?? PaceSettings()
    }
}

/// Times and dates as the phone shows them (DaylightText.clockTime and finishTime, Pages.fmtDate).
enum RouteFormat {
    private static func formatter(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = date
        f.timeStyle = time
        return f
    }

    private static let clockFormatter = formatter(date: .none, time: .short)
    private static let dateFormatter = formatter(date: .short, time: .none)
    private static let mediumFormatter = formatter(date: .medium, time: .short)
    private static let shortFormatter = formatter(date: .short, time: .short)

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// "17:45" (or "5:45 PM"), as the phone's clock shows times.
    static func clock(_ ms: Int64) -> String { clockFormatter.string(from: date(ms)) }

    /// "17:45" today, "tomorrow 07:12", or "28/09/2026 10:01".
    static func finish(_ ms: Int64) -> String {
        let calendar = Calendar.current
        let day = date(ms)
        let prefix: String
        if calendar.isDateInToday(day) {
            prefix = ""
        } else if calendar.isDateInTomorrow(day) {
            prefix = "tomorrow "
        } else {
            prefix = dateFormatter.string(from: day) + " "
        }
        return prefix + clock(ms)
    }

    /// "31 Oct 2026 at 09:21": when a route was imported or checked.
    static func dateTime(_ ms: Int64) -> String { mediumFormatter.string(from: date(ms)) }

    /// "31/10/2026, 09:21": when pre-loaded OS detail runs out.
    static func shortDateTime(_ ms: Int64) -> String { shortFormatter.string(from: date(ms)) }
}

/// Whether the phone can reach the internet and the user allows it (TileProvider.networkAllowed). Readable from any
/// thread.
final class RouteNetwork {
    static let shared = RouteNetwork()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var reachable = true
    private var offlineOnly = Prefs.shared.offlineOnly
    private var started = false
    private var cancellable: AnyCancellable?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.reachable = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "trailmind-routes-network"))
        cancellable = Prefs.shared.$offlineOnly.sink { [weak self] value in
            guard let self else { return }
            self.lock.withLock { self.offlineOnly = value }
        }
    }

    /// The phone has a connection.
    var online: Bool { lock.withLock { reachable } }

    /// The phone has a connection and Settings allow using it.
    var networkAllowed: Bool { lock.withLock { reachable && !offlineOnly } }
}

/// HTTP for the routes feature: every request sends the app's User-Agent, and replies are capped in size as the
/// Android app caps them, either failing or (for Overpass) keeping what arrived before the cap.
final class RouteHTTP: NSObject, URLSessionDataDelegate {
    static let shared = RouteHTTP()

    struct Response {
        let status: Int
        let data: Data
        /// The reply was cut off at the size cap.
        let truncated: Bool
        let headers: [AnyHashable: Any]

        var text: String { String(decoding: data, as: UTF8.self) }

        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value as? String
        }
    }

    struct TooLarge: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class Job {
        let maxBytes: Int
        let tooLarge: String?
        let completion: (Result<Response, Error>) -> Void
        var data = Data()
        var response: HTTPURLResponse?
        var truncated = false
        var failure: Error?

        init(maxBytes: Int, tooLarge: String?, completion: @escaping (Result<Response, Error>) -> Void) {
            self.maxBytes = maxBytes
            self.tooLarge = tooLarge
            self.completion = completion
        }
    }

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "trailmind-routes-http"
        return q
    }()
    private var jobs: [Int: Job] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()

    /// Starts a request. Replies over `maxBytes` fail with `tooLarge` as the message, or are cut short and marked
    /// truncated when `tooLarge` is nil. The completion runs on a background queue.
    @discardableResult
    func start(_ request: URLRequest, maxBytes: Int, tooLarge: String?, completion: @escaping (Result<Response, Error>) -> Void) -> URLSessionDataTask {
        var r = request
        r.setValue(TileLoader.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: r)
        let job = Job(maxBytes: maxBytes, tooLarge: tooLarge, completion: completion)
        delegateQueue.addOperation { self.jobs[task.taskIdentifier] = job }
        // Registered before the task can call back: the delegate queue is serial.
        delegateQueue.addOperation { task.resume() }
        return task
    }

    /// The same, waiting for the reply: only for background queues.
    func fetch(_ request: URLRequest, maxBytes: Int, tooLarge: String?, onTask: ((URLSessionDataTask) -> Void)? = nil) throws -> Response {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Response, Error> = .failure(URLError(.unknown))
        let task = start(request, maxBytes: maxBytes, tooLarge: tooLarge) { r in
            result = r
            done.signal()
        }
        onTask?(task)
        done.wait()
        return try result.get()
    }

    static func get(_ url: String, timeout: TimeInterval = 30) -> URLRequest? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u)
        r.timeoutInterval = timeout
        return r
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        jobs[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = jobs[dataTask.taskIdentifier], !job.truncated, job.failure == nil else { return }
        let room = job.maxBytes - job.data.count
        if data.count <= room {
            job.data.append(data)
            return
        }
        if let message = job.tooLarge {
            job.failure = TooLarge(message: message)
        } else {
            job.data.append(data.prefix(room))
            job.truncated = true
        }
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { return }
        let result: Result<Response, Error>
        if let failure = job.failure {
            result = .failure(failure)
        } else if let response = job.response, error == nil || job.truncated {
            result = .success(Response(status: response.statusCode, data: job.data, truncated: job.truncated, headers: response.allHeaderFields))
        } else {
            result = .failure(error ?? URLError(.badServerResponse))
        }
        // Off the delegate queue, so reading a large reply never holds up the other requests.
        DispatchQueue.global(qos: .userInitiated).async { job.completion(result) }
    }
}

/// Files the routes feature keeps per route, in Application Support as the Android app keeps them in its files folder.
enum RouteFiles {
    static let root: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func folder(_ name: String) -> URL {
        var url = root.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    /// Writes `text` through a temporary file, so a reader never sees half a file.
    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Forecasts, facilities and LiDAR checks saved for a route, removed with it.
    static func deleteSaved(_ routeId: Int64) {
        RouteForecasts.delete(routeId)
        OverpassFacilities.shared.delete(routeId)
        LidarChecks.shared.delete(routeId)
    }
}

/// Network failures in words a walker can act on.
enum RouteErrors {
    static func isUnreachable(_ e: Error) -> Bool {
        guard let u = e as? URLError else { return false }
        return [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost,
                .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff].contains(u.code)
    }

    static func message(_ e: Error) -> String {
        if let l = e as? LocalizedError, let d = l.errorDescription { return d }
        return e.localizedDescription
    }
}
