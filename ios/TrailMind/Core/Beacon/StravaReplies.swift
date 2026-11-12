import Foundation

/// What Strava's web API answered (StravaApi.Reply): its JSON body on success, or why not. Every call returns one of
/// these rather than throwing.
enum StravaReply {
    case ok([String: Any])
    /// Strava answered, but not with success. `message` is its own explanation when it gave one.
    case http(code: Int, message: String, retryAfterS: Int64?)
    case offline(message: String)
}

/// Reading Strava's answers as the Android app's StravaApi and StravaManager do.
enum StravaReplies {
    /// An HTTP answer: a 2xx body as JSON (an unreadable one as an empty object), anything else with Strava's explanation.
    static func reply(code: Int, body: Data, retryAfter: String?) -> StravaReply {
        let text = String(decoding: body, as: UTF8.self)
        if (200...299).contains(code) { return .ok(BeaconJSON.optObject(Data(text.utf8)) ?? [:]) }
        return .http(code: code, message: explain(text), retryAfterS: retryAfter.flatMap { Int64($0) })
    }

    /// Strava's own words for a failure: `{"message": "...", "errors": [{"resource": "...", "field": "...", "code": "..."}]}`.
    static func explain(_ text: String) -> String {
        guard let json = BeaconJSON.optObject(Data(text.utf8)) else { return take(text, 200) }
        let message = BeaconJSON.optString(json, "message")
        let errors = json["errors"] as? [Any] ?? []
        let detail = errors.compactMap { item -> String? in
            guard let e = item as? [String: Any] else { return nil }
            return ["resource", "field", "code"].map { BeaconJSON.optString(e, $0) }.filter { !KotlinText.isBlank($0) }
                .joined(separator: " ")
        }.filter { !KotlinText.isBlank($0) }
        let joined = ([message] + detail).filter { !KotlinText.isBlank($0) }.joined(separator: ": ")
        return KotlinText.isBlank(joined) ? take(text, 200) : joined
    }

    /// The tokens a sign-in or refresh hands out. A refresh token is only replaced by a new one that isn't blank.
    struct TokenUpdate: Hashable {
        var accessToken: String
        var refreshToken: String?
        /// Seconds since 1970: Strava's `expires_at`, else now plus `expires_in`, else six hours.
        var expiresAtS: Int64
    }

    static func tokens(_ body: [String: Any], nowS: Int64) -> TokenUpdate {
        let refresh = BeaconJSON.optString(body, "refresh_token")
        return TokenUpdate(
            accessToken: BeaconJSON.optString(body, "access_token"),
            refreshToken: KotlinText.isBlank(refresh) ? nil : refresh,
            expiresAtS: BeaconJSON.optLong(body, "expires_at", nowS + BeaconJSON.optLong(body, "expires_in", 21_600))
        )
    }

    /// Who signed in, as it's saved: blank text where Strava gives none.
    struct AthleteFields: Hashable {
        var id: Int64
        var username: String
        var firstName: String
        var lastName: String
    }

    /// The `athlete` object of a sign-in answer, if it has one.
    static func athlete(_ body: [String: Any]) -> AthleteFields? {
        guard let a = body["athlete"] as? [String: Any] else { return nil }
        func text(_ key: String) -> String { BeaconJSON.isNull(a[key]) ? "" : BeaconJSON.optString(a, key) }
        return AthleteFields(id: BeaconJSON.optLong(a, "id"), username: text("username"), firstName: text("firstname"),
                             lastName: text("lastname"))
    }

    /// The new upload's id, or nil when Strava didn't give a usable one.
    static func uploadId(_ body: [String: Any]) -> Int64? {
        let id = BeaconJSON.optLong(body, "id")
        return id > 0 ? id : nil
    }

    /// What an upload object (`status`, `error`, `activity_id`) says has become of the upload.
    static func uploadResult(_ body: [String: Any]) -> StravaUploadResult {
        StravaPolicy.classify(
            BeaconJSON.isNull(body["status"]) ? nil : BeaconJSON.optString(body, "status"),
            BeaconJSON.isNull(body["error"]) ? nil : BeaconJSON.optString(body, "error"),
            BeaconJSON.isNull(body["activity_id"]) ? nil : BeaconJSON.optLong(body, "activity_id")
        )
    }

    /// Kotlin's `take`: the first `n` UTF-16 units.
    private static func take(_ s: String, _ n: Int) -> String {
        s.utf16.count <= n ? s : String(decoding: s.utf16.prefix(n), as: UTF16.self)
    }
}

/// What becomes of a post after a call to Strava didn't succeed (StravaManager.later).
enum StravaRetry: Hashable {
    /// Save the post with this state, note, attempt count and next try (its upload id is kept).
    case save(state: StravaPostState, message: String?, attempts: Int, nextTryMs: Int64)
    /// Strava refused the link: the user must connect again, and the post waits as it is.
    case reconnect
}

/// The posting queue's rules that don't need a phone (StravaManager).
enum StravaQueuePolicy {
    /// Without signal, look again in five minutes.
    static let offlineWaitMs: Int64 = 5 * 60_000
    static let minWaitMs: Int64 = 5_000
    /// Strava still processing after the polls: ask again in a minute, without counting it as a failure.
    static let processingRecheckMs: Int64 = 60_000

    static var tooShortMessage: String { "Too short to be a hike (under \(kTruncate(StravaPolicy.minDistanceM)) m)." }

    /// A call that didn't succeed: wait and try again, or give up, depending on why. `attempts` is the post's count so far.
    static func later(attempts: Int, reply: StravaReply, now: Int64) -> StravaRetry {
        if case .http(let code, let message, _) = reply {
            if code == 429 {
                return .save(state: .queued, message: "Strava's limit was reached; trying again later.", attempts: attempts,
                             nextTryMs: now + StravaPolicy.rateLimitWaitMs)
            }
            if code == 403 { return .reconnect }
            if (400...499).contains(code) && code != 408 {
                return .save(state: .failed, message: "Strava refused it (HTTP \(code)): \(message)", attempts: attempts, nextTryMs: 0)
            }
        }
        let tries = attempts + 1
        let why: String
        switch reply {
        case .offline(let message): why = "No connection to Strava: \(message)"
        case .http(let code, _, _): why = "Strava had a problem (HTTP \(code))."
        case .ok: why = "Strava's answer wasn't understood."
        }
        if tries >= StravaPolicy.maxAttempts {
            return .save(state: .failed, message: "\(why) Gave up after \(tries) tries.", attempts: tries, nextTryMs: 0)
        }
        return .save(state: .queued, message: why, attempts: tries, nextTryMs: now + StravaPolicy.retryDelayMs(tries))
    }

    /// Renewing the access token failed with `reply`: true when Strava refused the link itself (HTTP 400 to 403), so the
    /// user has to connect again; otherwise the posts wait and try later.
    static func refreshNeedsReconnect(_ reply: StravaReply) -> Bool {
        if case .http(let code, _, _) = reply { return (400...403).contains(code) }
        return false
    }

    /// How long until the next waiting post is due (at least five seconds), or nil when none is waiting.
    static func nextWaitMs(nextTryMs: Int64?, now: Int64) -> Int64? {
        guard let next = nextTryMs else { return nil }
        return max(next - now, minWaitMs)
    }

    /// Where one hike is with Strava, in the words of its hike page; nil when there's nothing to say (not linked, never
    /// posted).
    static func status(state: StravaPostState?, message: String?, activityId: Int64?, linked: Bool, needsReconnect: Bool,
                       live: Bool) -> String? {
        if needsReconnect { return "Strava stopped accepting TrailMind, so this hike can't be posted by itself." }
        if !linked {
            guard state == .posted else { return nil }
            return activityId != nil ? "Posted to Strava ✓" : (message ?? "On Strava ✓")
        }
        guard let state else { return live ? "You can post it once it's finished." : "Not posted to Strava." }
        switch state {
        case .queued: return "Waiting to post. \(message ?? "It goes as soon as the phone has signal.")"
        case .processing: return "Strava is processing this hike…"
        case .posted: return activityId != nil ? "Posted to Strava ✓" : (message ?? "On Strava ✓")
        case .failed: return "Couldn't post this hike. \(message ?? "")"
        case .skipped: return message ?? "Not posted to Strava."
        }
    }
}
