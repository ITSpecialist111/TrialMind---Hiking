import Foundation

/// Where one hike's post to Strava has got to. Kept per hike, so a retry never posts it twice.
enum StravaPostState: String, CaseIterable {
    /// Waiting for signal, or for the next try.
    case queued = "QUEUED"
    /// Strava has the file and is working on it.
    case processing = "PROCESSING"
    /// On Strava.
    case posted = "POSTED"
    /// Gave up for now; the hike page offers Try again.
    case failed = "FAILED"
    /// Not worth posting (too short), or the user didn't want it.
    case skipped = "SKIPPED"
}

/// What kind of Strava activity a hike is posted as. The code is the `activity_type` Strava's upload takes.
enum StravaActivityKind: CaseIterable {
    case hike
    case walk

    var code: String {
        switch self {
        case .hike: return "hike"
        case .walk: return "walk"
        }
    }

    var label: String {
        switch self {
        case .hike: return "Hike"
        case .walk: return "Walk"
        }
    }

    static func of(_ code: String?) -> StravaActivityKind { allCases.first { $0.code == code } ?? .hike }
}

/// How Strava answered an upload or a later check on it.
enum StravaUploadResult: Hashable {
    case ready(activityId: Int64)
    case processing
    /// Strava already has this activity: fine, there's nothing more to post.
    case duplicate(message: String)
    case failed(message: String)
}

/// The rules around posting hikes that are worth testing without a phone or Strava.
enum StravaPolicy {
    /// A recording shorter than this is a stray tap on Start, not a hike.
    static let minDistanceM = 250.0
    static let minPoints = 10
    static let description = "Recorded with TrailMind"
    /// Strava's own page for uploading a GPX by hand: the way in that needs neither a subscription nor an API application.
    static let uploadPageUrl = "https://www.strava.com/upload/select"
    static let maxAttempts = 8
    /// Strava's limit for a new application is 100 requests per 15 minutes.
    static let rateLimitWaitMs: Int64 = 15 * 60_000
    static let pollMs: Int64 = 2_000
    static let pollTries = 15

    static func worthPosting(_ distanceM: Double, _ pointCount: Int) -> Bool { distanceM >= minDistanceM && pointCount >= minPoints }

    /// Stable per hike, so Strava can tell a retry from a second hike.
    static func externalId(_ startMs: Int64, _ hikeId: Int64) -> String { "trailmind-\(hikeId)-\(startMs)" }

    /// Strava names are limited to 255 characters.
    static func activityName(_ hikeName: String, fallback: String = "Hike") -> String {
        let name = take(KotlinText.trim(hikeName), 255)
        return KotlinText.isBlank(name) ? fallback : name
    }

    /// 1 minute, 5, 15, 1 hour, then 6 hours, for the attempt that just failed (1 is the first).
    static func retryDelayMs(_ attempt: Int) -> Int64 {
        if attempt <= 1 { return 60_000 }
        if attempt == 2 { return 5 * 60_000 }
        if attempt == 3 { return 15 * 60_000 }
        if attempt == 4 { return 3_600_000 }
        return 6 * 3_600_000
    }

    /// Reads Strava's upload object: `status` and `error` are its text fields, `activityId` its `activity_id` (nil, or
    /// 0, until processing ends).
    static func classify(_ status: String?, _ error: String?, _ activityId: Int64?) -> StravaUploadResult {
        let err = error.map { KotlinText.trim($0) } ?? ""
        let st = status.map { KotlinText.trim($0) } ?? ""
        if !err.isEmpty {
            return containsIgnoringCase(err, "duplicate") ? .duplicate(message: err) : .failed(message: err)
        }
        if let activityId = activityId, activityId > 0 { return .ready(activityId: activityId) }
        if containsIgnoringCase(st, "error") { return .failed(message: st) }
        if containsIgnoringCase(st, "deleted") { return .failed(message: "The activity was deleted on Strava.") }
        return .processing
    }

    /// The link to an activity on Strava.
    static func activityUrl(_ activityId: Int64) -> String { "https://www.strava.com/activities/\(activityId)" }

    private static func containsIgnoringCase(_ s: String, _ part: String) -> Bool { s.range(of: part, options: .caseInsensitive) != nil }

    /// Kotlin's `take`: the first `n` UTF-16 units, as a Kotlin string counts them.
    private static func take(_ s: String, _ n: Int) -> String {
        s.utf16.count <= n ? s : String(decoding: s.utf16.prefix(n), as: UTF16.self)
    }
}
