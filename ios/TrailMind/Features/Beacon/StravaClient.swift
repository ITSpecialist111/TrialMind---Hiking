import Foundation

/// Strava's web API over HTTPS (strava/StravaApi.kt). Every call returns what happened rather than throwing. Calls wait
/// for their answer, as on Android, so they're only made from the posting queue and other background threads.
enum StravaClient {
    /// Strava's address.
    static let baseUrl = "https://www.strava.com"

    static func exchangeCode(_ clientId: String, _ clientSecret: String, _ code: String) -> StravaReply {
        postForm(StravaOAuth.tokenPath, StravaOAuth.tokenRequestBody(clientId, clientSecret, code))
    }

    static func refresh(_ clientId: String, _ clientSecret: String, _ refreshToken: String) -> StravaReply {
        postForm(StravaOAuth.tokenPath, StravaOAuth.refreshRequestBody(clientId, clientSecret, refreshToken))
    }

    /// Tells Strava the user has unlinked TrailMind, so it disappears from their connected apps. Best effort.
    @discardableResult
    static func deauthorize(_ accessToken: String) -> StravaReply {
        postForm(StravaOAuth.deauthorizePath, "", bearer: accessToken)
    }

    static func upload(_ accessToken: String, gpx: [UInt8], fileName: String, name: String, kind: StravaActivityKind,
                       externalId: String) -> StravaReply {
        let form = StravaRequests.uploadForm(gpx: gpx, fileName: fileName, name: name, kind: kind, externalId: externalId)
        return send("POST", "/api/v3/uploads", Data(form.build()), form.contentType, accessToken)
    }

    static func uploadStatus(_ accessToken: String, _ uploadId: Int64) -> StravaReply {
        send("GET", "/api/v3/uploads/\(uploadId)", nil, nil, accessToken)
    }

    private static func postForm(_ path: String, _ body: String, bearer: String? = nil) -> StravaReply {
        send("POST", path, Data(body.utf8), "application/x-www-form-urlencoded", bearer)
    }

    /// Strava's answers aren't cached, cookies aren't kept, and redirects come back as they are.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private static func send(_ method: String, _ path: String, _ body: Data?, _ contentType: String?, _ bearer: String?) -> StravaReply {
        guard let url = URL(string: baseUrl + path) else { return .offline(message: "The address wasn't valid.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(TileLoader.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        let answered = DispatchSemaphore(value: 0)
        let result = ReplyBox()
        session.dataTask(with: request) { data, response, error in
            if let error {
                result.reply = .offline(message: error.localizedDescription.isEmpty ? "no connection" : error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                result.reply = StravaReplies.reply(code: http.statusCode, body: data ?? Data(),
                                                   retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            }
            answered.signal()
        }.resume()
        answered.wait()
        return result.reply
    }

    /// Written by the task's handler before it signals, read only after the wait.
    private final class ReplyBox: @unchecked Sendable {
        var reply: StravaReply = .offline(message: "no connection")
    }

    /// Android doesn't follow redirects either: one is just an answer that isn't success.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
