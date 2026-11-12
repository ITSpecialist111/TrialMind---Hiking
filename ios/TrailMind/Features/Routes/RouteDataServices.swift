import Foundation

/// Route checks against 1 m LiDAR (LidarChecks.kt): downloads the squares along a route, finds steep ground and
/// crags, and keeps the result. Checks carry on when the route page is closed.
final class LidarChecks: ObservableObject {
    static let shared = LidarChecks()

    struct Progress: Equatable {
        var done = 0
        var total = 0
    }

    /// Checks under way, by route.
    @Published private(set) var running: [Int64: Progress] = [:]
    /// Why the last check of a route failed.
    @Published private(set) var errors: [Int64: String] = [:]
    /// Bumped whenever a check finishes or is deleted.
    @Published private(set) var revision = 0

    private let lock = NSLock()
    private var deleted = Set<Int64>()
    private let folder = RouteFiles.folder("lidar-checks")

    func progress(_ routeId: Int64) -> Progress? { running[routeId] }
    func error(_ routeId: Int64) -> String? { errors[routeId] }

    /// Starts checking a route; false if one is already running or the line is too short. Call on the main queue.
    @discardableResult
    func start(_ routeId: Int64, _ points: [LatLon]) -> Bool {
        if running[routeId] != nil || points.count < 2 { return false }
        running[routeId] = Progress()
        errors[routeId] = nil
        _ = lock.withLock { deleted.remove(routeId) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.check(routeId, points) }
            DispatchQueue.main.async {
                self.running[routeId] = nil
                if case .failure(let e) = result { self.errors[routeId] = RouteErrors.message(e) }
                self.revision += 1
            }
        }
        return true
    }

    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func check(_ routeId: Int64, _ points: [LatLon]) throws -> SavedLidarCheck {
        let lidar = LidarService.shared
        let squares = LidarCheckPlan.squares(points)
        if squares.isEmpty { throw Failure(message: "LiDAR covers England only.") }
        DispatchQueue.main.async { self.running[routeId]?.total = squares.count }
        let outcome = lidar.download(squares, cancelled: { self.lock.withLock { self.deleted.contains(routeId) } }) { done in
            if done % 4 == 0 || done == squares.count {
                DispatchQueue.main.async { self.running[routeId]?.done = done }
            }
        }
        if lock.withLock({ deleted.contains(routeId) }) { throw Failure(message: "Route was deleted.") }
        if outcome.failed == squares.count { throw Failure(message: "Couldn't download LiDAR. Check the connection and try again.") }
        let report = LidarRouteCheck.check(points, lidar.ground())
        let saved = SavedLidarCheck(checkedMs: nowMs(), report: report)
        try lock.withLock {
            if deleted.contains(routeId) { throw Failure(message: "Route was deleted.") }
            do {
                try RouteFiles.write(saved.json(), to: file(routeId))
            } catch {
                throw Failure(message: "Could not save the LiDAR check.")
            }
        }
        return saved
    }

    func saved(_ routeId: Int64) -> SavedLidarCheck? { RouteFiles.read(file(routeId)).flatMap(SavedLidarCheck.from) }

    func delete(_ routeId: Int64) {
        lock.withLock {
            deleted.insert(routeId)
            try? FileManager.default.removeItem(at: file(routeId))
        }
        DispatchQueue.main.async { self.revision += 1 }
    }

    private func file(_ routeId: Int64) -> URL { folder.appendingPathComponent("\(routeId).json") }
}

/// Facilities near a route from Overpass, saved per route for offline use (OverpassFacilities.kt): one query at a
/// time, never soon after Overpass asked TrailMind to wait.
final class OverpassFacilities: ObservableObject {
    static let shared = OverpassFacilities()

    /// Routes whose facilities are being found.
    @Published private(set) var fetching = Set<Int64>()
    /// Bumped whenever saved facilities change.
    @Published private(set) var revision = 0

    private let lock = NSLock()
    private let requestLock = NSLock()
    private var backoffUntilMs: Int64 = 0
    private var deletedRoutes = Set<Int64>()
    private var listeners: [Int64: [UUID: (Result<SavedFacilities, Error>) -> Void]] = [:]
    private let folder = RouteFiles.folder("pois")

    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func isFetching(_ routeId: Int64) -> Bool { fetching.contains(routeId) }

    @discardableResult
    func addListener(_ routeId: Int64, _ listener: @escaping (Result<SavedFacilities, Error>) -> Void) -> UUID {
        let id = UUID()
        listeners[routeId, default: [:]][id] = listener
        return id
    }

    func removeListener(_ routeId: Int64, _ id: UUID) {
        listeners[routeId]?[id] = nil
        if listeners[routeId]?.isEmpty == true { listeners[routeId] = nil }
    }

    /// Starts finding a route's facilities; false if that is already under way. Call on the main queue.
    @discardableResult
    func start(_ routeId: Int64, _ points: [LatLon]) -> Bool {
        if fetching.contains(routeId) || points.isEmpty { return false }
        fetching.insert(routeId)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.fetch(routeId, points) }
            DispatchQueue.main.async {
                self.fetching.remove(routeId)
                if case .success = result { self.revision += 1 }
                self.listeners[routeId]?.values.forEach { $0(result) }
            }
        }
        return true
    }

    /// Whether the phone can search now.
    var online: Bool { RouteNetwork.shared.networkAllowed }

    private func fetch(_ routeId: Int64, _ points: [LatLon]) throws -> SavedFacilities {
        let query = Overpass.query(points)
        var lastError: Error?
        for server in Overpass.servers {
            do {
                let (items, partial) = try oneAtATime { try request(server, query, points) }
                let saved = SavedFacilities(fetchedMs: nowMs(), items: items, partial: partial || RouteFacilities.corridorM(points) < 250)
                try lock.withLock {
                    if deletedRoutes.contains(routeId) { throw Failure(message: "Route was deleted.") }
                    do {
                        try RouteFiles.write(saved.json(), to: file(routeId))
                    } catch {
                        throw Failure(message: "Could not save facilities offline.")
                    }
                }
                return saved
            } catch {
                lastError = error
                let message = RouteErrors.message(error)
                let deleted = lock.withLock { deletedRoutes.contains(routeId) }
                if deleted || message == "Could not save facilities offline."
                    || (message.range(of: "HTTP 4\\d\\d", options: .regularExpression) != nil && !message.contains("HTTP 429")) { break }
            }
        }
        throw lastError ?? Failure(message: "Facilities are unavailable.")
    }

    /// Runs `block` as the only Overpass query in flight, and not while Overpass has asked TrailMind to wait.
    private func oneAtATime<T>(_ block: () throws -> T) throws -> T {
        // Fails at once rather than queueing, so a second search neither follows a 429 nor holds a thread.
        guard requestLock.try() else { throw Failure(message: Overpass.anotherSearchMessage) }
        defer { requestLock.unlock() }
        let wait = lock.withLock { backoffUntilMs } - nowMs()
        if wait > 0 { throw Failure(message: Overpass.busyMessage(waitMs: wait)) }
        return try block()
    }

    private func request(_ server: String, _ query: String, _ points: [LatLon]) throws -> (items: [Facility], partial: Bool) {
        guard let url = URL(string: server) else { throw Failure(message: "Facilities are unavailable.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 145
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Overpass.body(query).utf8)
        let response = try RouteHTTP.shared.fetch(request, maxBytes: Overpass.maxBytes, tooLarge: nil)
        if let until = Overpass.backoffUntil(status: response.status, retryAfter: response.header("Retry-After"), nowMs: nowMs()) {
            lock.withLock { backoffUntilMs = until }
        }
        if response.status != 200 { throw Failure(message: "Overpass answered HTTP \(response.status).") }
        return try Overpass.parse([UInt8](response.data), truncated: response.truncated, points: points)
    }

    func saved(_ routeId: Int64) -> SavedFacilities? { RouteFiles.read(file(routeId)).flatMap(SavedFacilities.from) }

    func hasSaved(_ routeId: Int64) -> Bool { FileManager.default.fileExists(atPath: file(routeId).path) }

    func delete(_ routeId: Int64) {
        lock.withLock {
            deletedRoutes.insert(routeId)
            try? FileManager.default.removeItem(at: file(routeId))
        }
        DispatchQueue.main.async { self.revision += 1 }
    }

    private func file(_ routeId: Int64) -> URL { folder.appendingPathComponent("\(routeId).json") }
}

/// Mountain forecasts for routes from Open-Meteo, saved per route so the trip-readiness check and Beacon can read
/// them offline (OpenMeteo.kt's fetch, saved and delete). The file is the Android app's: Application Support/forecasts.
enum RouteForecasts {
    private static let folder = RouteFiles.folder("forecasts")

    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func file(_ routeId: Int64) -> URL { folder.appendingPathComponent("\(routeId).json") }

    /// Fetches the forecast for `at`, `eleM` high, and saves it for the route. Calls back on the main queue.
    static func fetch(_ routeId: Int64, at: LatLon, eleM: Double, completion: @escaping (Result<PointForecast, Error>) -> Void) {
        guard let request = RouteHTTP.get(RouteWeather.forecastURL(at, eleM: eleM), timeout: 30) else {
            return completion(.failure(Failure(message: "Forecast unavailable")))
        }
        RouteHTTP.shared.start(request, maxBytes: RouteWeather.maxBytes, tooLarge: "The forecast was unexpectedly large.") { result in
            let outcome = Result { () -> PointForecast in
                let response = try result.get()
                if response.status != 200 { throw Failure(message: "Open-Meteo answered HTTP \(response.status).") }
                let json = try RoutesJSON.parse(response.data)
                let fetchedMs = nowMs()
                let forecast = try RouteWeather.parse(json, fetchedMs: fetchedMs)
                try RouteFiles.write(RouteWeather.savedFile(json, fetchedMs: fetchedMs), to: file(routeId))
                return forecast
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    static func saved(_ routeId: Int64) -> PointForecast? { RouteFiles.read(file(routeId)).flatMap(RouteWeather.readSaved) }

    static func delete(_ routeId: Int64) { try? FileManager.default.removeItem(at: file(routeId)) }
}
