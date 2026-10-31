import Foundation

/// what3words look-ups over the network (data/What3words.kt): only when the user taps, with their own key. The answer for
/// your position is kept and shared only while it is under a minute old and you are still in its 3 m square.
final class What3wordsLookup: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = What3wordsLookup()

    private struct Cached {
        let address: What3wordsAddress
        let fixAtMs: Int64
    }

    @Published private var cached: Cached?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = What3wordsApi.readTimeoutS
        config.timeoutIntervalForResource = What3wordsApi.connectTimeoutS + What3wordsApi.readTimeoutS
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// The looked-up address if it still names where `fix` is (ThreeWordAddress.canShare), else nil.
    func current(_ fix: Fix?, nowMs now: Int64 = nowMs()) -> What3wordsAddress? {
        guard let saved = cached, let fix else { return nil }
        return ThreeWordAddress.canShare(saved.fixAtMs, fix.timeMs, now, saved.address.contains(fix.latLon)) ? saved.address : nil
    }

    /// Looks up the three words for a fix from the last minute. `done` runs on the main queue.
    @discardableResult
    func locate(_ fix: Fix, key: String, done: @escaping (Result<What3wordsAddress, What3wordsError>) -> Void) -> URLSessionTask? {
        do {
            try What3wordsApi.checkFresh(fixMs: fix.timeMs, nowMs: nowMs())
            try What3wordsApi.checkKey(key)
        } catch {
            done(.failure(error as? What3wordsError ?? What3wordsError(What3wordsApi.couldNotConnect)))
            return nil
        }
        return get(What3wordsApi.locateURL(fix.lat, fix.lon), key) { [weak self] result in
            done(result.flatMap { address in
                do {
                    try What3wordsApi.checkLocated(address, fix.lat, fix.lon)
                    self?.cached = Cached(address: address, fixAtMs: fix.timeMs)
                    return .success(address)
                } catch {
                    return .failure(error as? What3wordsError ?? What3wordsError(What3wordsApi.wrongLocation))
                }
            })
        }
    }

    /// Finds where typed three words are (convert-to-coordinates), for search.
    @discardableResult
    func search(_ input: String, key: String, done: @escaping (Result<What3wordsAddress, What3wordsError>) -> Void) -> URLSessionTask? {
        let request: (url: String, words: String)
        do {
            request = try What3wordsApi.searchURL(input)
            try What3wordsApi.checkKey(key)
        } catch {
            done(.failure(error as? What3wordsError ?? What3wordsError(What3wordsApi.needThreeWords)))
            return nil
        }
        return get(request.url, key) { result in
            done(result.flatMap { address in
                do {
                    try What3wordsApi.checkSearched(address, request.words)
                    return .success(address)
                } catch {
                    return .failure(error as? What3wordsError ?? What3wordsError(What3wordsApi.wrongAddress))
                }
            })
        }
    }

    private func get(_ url: String, _ key: String, done: @escaping (Result<What3wordsAddress, What3wordsError>) -> Void) -> URLSessionTask? {
        guard let target = URL(string: url) else {
            done(.failure(What3wordsError(What3wordsApi.couldNotConnect)))
            return nil
        }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: What3wordsApi.readTimeoutS)
        request.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Api-Key")
        request.setValue(TileLoader.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { data, response, error in
            let result: Result<What3wordsAddress, What3wordsError>
            if let error = error as? URLError, error.code == .cancelled {
                result = .failure(What3wordsError(What3wordsApi.cancelled))
            } else if error != nil {
                result = .failure(What3wordsError(What3wordsApi.couldNotConnect))
            } else if let http = response as? HTTPURLResponse, let problem = What3wordsApi.statusMessage(http.statusCode) {
                result = .failure(What3wordsError(problem))
            } else if !(response is HTTPURLResponse) {
                result = .failure(What3wordsError(What3wordsApi.couldNotConnect))
            } else if let data, data.count > What3wordsApi.maxResponseBytes {
                result = .failure(What3wordsError(What3wordsApi.tooLarge))
            } else {
                do {
                    result = .success(try What3wordsApi.parseResponse(String(decoding: data ?? Data(), as: UTF8.self)))
                } catch {
                    result = .failure(error as? What3wordsError ?? What3wordsError(What3wordsApi.unreadable))
                }
            }
            DispatchQueue.main.async { done(result) }
        }
        task.resume()
        return task
    }

    /// Like Android's `instanceFollowRedirects = false`: a redirect is answered as the status it is.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
