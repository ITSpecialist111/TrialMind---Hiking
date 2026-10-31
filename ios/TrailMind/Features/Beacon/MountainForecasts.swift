import Foundation

/// Open-Meteo mountain forecasts over the network, saved per route in Application Support/forecasts/<route id>.json
/// (data/OpenMeteo.kt), so Beacon's briefing still has them without signal. The file is the Android app's
/// `{"fetchedMs": …, "data": <Open-Meteo's answer>}`, the same one the route page saves and deletes with the route.
enum MountainForecasts {
    struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("forecasts", isDirectory: true)
    }

    static func file(_ routeId: Int64) -> URL { directory.appendingPathComponent("\(routeId).json") }

    /// Fetches the forecast for `at`, `eleM` high, saves it for `routeId`, and calls back on the main queue.
    static func fetch(routeId: Int64, at: LatLon, eleM: Double,
                      done: @escaping @Sendable (Result<PointForecast, Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            let result: Result<PointForecast, Error>
            do {
                result = .success(try await download(routeId: routeId, at: at, eleM: eleM))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// What went wrong, in a few words for "Couldn't get the forecast: …".
    static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.isEmpty ? "no connection" : text
    }

    /// Fetches the forecast for `at`, `eleM` high, and saves it for `routeId`. Throws with a message for the user.
    static func download(routeId: Int64, at: LatLon, eleM: Double) async throws -> PointForecast {
        guard let url = URL(string: OpenMeteo.forecastUrl(at, eleM)) else { throw Failure("The forecast address wasn't valid.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(TileLoader.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { throw Failure("Open-Meteo answered HTTP \(code).") }
        var answer = Data()
        for try await byte in bytes {
            answer.append(byte)
            if answer.count > OpenMeteo.maxBytes { throw Failure("The forecast was unexpectedly large.") }
        }
        let fetchedMs = nowMs()
        let forecast = try OpenMeteo.parse(answer, fetchedMs: fetchedMs)
        try save(OpenMeteo.savedFile(answer, fetchedMs: fetchedMs), routeId)
        return forecast
    }

    /// The forecast saved for `routeId`, or nil if there's none (or it's damaged).
    static func saved(_ routeId: Int64) -> PointForecast? {
        guard let data = try? Data(contentsOf: file(routeId)) else { return nil }
        return OpenMeteo.readSaved(data)
    }

    private static func save(_ data: Data, _ routeId: Int64) throws {
        var dir = directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            try data.write(to: file(routeId), options: .atomic)
        } catch {
            throw Failure("Couldn't save the forecast on the phone.")
        }
    }
}
