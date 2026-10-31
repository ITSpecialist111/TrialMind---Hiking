import Foundation

/// What TrailMind sends Strava and the checks it makes first (strava/StravaApi.kt, StravaManager.kt and the hike page's
/// GPX), kept apart from the network so they're tested without a phone.
enum StravaRequests {
    /// The upload's form (StravaApi.upload): Strava reads the file as GPX and names the activity as given.
    static func uploadForm(gpx: [UInt8], fileName: String, name: String, kind: StravaActivityKind, externalId: String,
                           boundary: String? = nil) -> StravaMultipart {
        let form = boundary.map { StravaMultipart($0) } ?? StravaMultipart()
        return form
            .field("data_type", "gpx")
            .field("name", name)
            .field("description", StravaPolicy.description)
            .field("activity_type", kind.code)
            .field("external_id", externalId)
            .file("file", fileName, "application/gpx+xml", gpx)
    }

    /// The name a hike's file goes up under.
    static func uploadFileName(_ hikeId: Int64) -> String { "trailmind-\(hikeId).gpx" }

    /// The hike as it's posted (StravaManager.process): its track, "Recorded with TrailMind", and walking or hiking as
    /// the user chose.
    static func hikeGpx(name: String, segments: [[TrackPoint]], kind: StravaActivityKind) -> [UInt8] {
        var out = ""
        GpxWriter.writeTrack(&out, name, segments, description: StravaPolicy.description,
                             activityType: kind == .walk ? "walking" : "hiking")
        return Array(out.utf8)
    }

    /// The GPX saved for uploading by hand on Strava's site (HikeDetailPage.gpx): always a hike.
    static func handUploadGpx(name: String, segments: [[TrackPoint]]) -> String {
        var out = ""
        GpxWriter.writeTrack(&out, name, segments, description: StravaPolicy.description, activityType: "hiking")
        return out
    }

    /// The sign-in's one-time state: the random bytes as lower-case hex, two digits each.
    static func stateText(_ bytes: [UInt8]) -> String {
        bytes.map { String($0, radix: 16).padStart(2, "0") }.joined()
    }
}

/// Starting the sign-in (StravaManager.beginConnect): the Client ID and secret the user typed, checked before Strava
/// sees them.
enum StravaConnect {
    enum Check: Hashable {
        /// What to tell the user instead of signing in.
        case invalid(String)
        /// Sign in with this application. A blank secret keeps the saved one; `otherApp` means it isn't the
        /// application linked before, so the old sign-in is no use.
        case ready(clientId: String, clientSecret: String, otherApp: Bool)
    }

    static func check(clientId: String, clientSecret: String, savedClientId: String, hasSavedSecret: Bool) -> Check {
        let id = KotlinText.trim(clientId)
        let secret = KotlinText.trim(clientSecret)
        if KotlinText.isBlank(id) || !id.utf16.allSatisfy(isDigit) {
            return .invalid("The Client ID is the number at the top of your Strava application's page.")
        }
        if secret.isEmpty && !(hasSavedSecret && id == savedClientId) {
            return .invalid("Paste the Client Secret from your Strava application's page.")
        }
        return .ready(clientId: id, clientSecret: secret, otherApp: id != savedClientId)
    }

    /// Kotlin's `Char.isDigit()`: any Unicode decimal digit, one UTF-16 unit at a time.
    private static func isDigit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.generalCategory == .decimalNumber
    }
}

/// What the Strava page and the sign-in say (StravaManager, ui/StravaPage.kt).
enum StravaText {
    static let noUploadPermission = "Strava didn't give TrailMind permission to post activities, so nothing was linked. " +
        "Connect again and leave \"Upload your activities\" ticked."

    static func linked(_ athlete: StravaAthlete?) -> String { "Linked to Strava as \(athlete?.display ?? "your account")." }

    /// Why swapping the sign-in code for tokens failed; nil when it didn't.
    static func linkFailure(_ reply: StravaReply) -> String? {
        switch reply {
        case .ok:
            return nil
        case .http(let code, let message, _):
            if code == 400 || code == 401 {
                return "Strava didn't accept the Client ID and secret. Check them on your application's page at " +
                    "strava.com/settings/api. (\(message))"
            }
            return "Strava said no (HTTP \(code)): \(message)"
        case .offline(let message):
            return "Couldn't reach Strava: \(message)"
        }
    }

    /// "2 hikes are waiting to be posted…".
    static func waiting(_ count: Int) -> String {
        "\(count) hike\(count > 1 ? "s are" : " is") waiting to be posted. They go as soon as the phone has signal."
    }

    static var postingHelp: String {
        "A hike is posted when you finish it, with its name, track, times and heights, as \"\(StravaPolicy.description)\". " +
            "Recordings under \(kTruncate(StravaPolicy.minDistanceM)) m are skipped. Your Strava privacy settings decide who sees it. " +
            "Without signal it's posted later. Each hike can be posted by hand from its page too."
    }
}

extension StravaAthlete {
    /// The athlete saved with the link (StravaManager.athlete): nil until someone has signed in, and blank names left out.
    static func saved(id: Int64, username: String, firstName: String, lastName: String) -> StravaAthlete? {
        guard id != 0 else { return nil }
        func orNil(_ s: String) -> String? { KotlinText.isBlank(s) ? nil : s }
        return StravaAthlete(id: id, username: orNil(username), firstName: orNil(firstName), lastName: orNil(lastName))
    }
}

extension StravaQueuePolicy {
    /// The saved access token while it's still good; nil when it has to be renewed first (or `force` asks for a new one).
    static func currentAccessToken(_ tokens: StravaTokens, nowS: Int64, force: Bool = false) -> String? {
        !force && !KotlinText.isBlank(tokens.accessToken) && !tokens.needsRefresh(nowS) ? tokens.accessToken : nil
    }

    /// Strava can't drop an app on an expired access token, so unlinking renews it first when it can.
    static func revokeNeedsRefresh(_ tokens: StravaTokens, nowS: Int64) -> Bool {
        !(KotlinText.isBlank(tokens.refreshToken) || currentAccessToken(tokens, nowS: nowS) != nil)
    }
}
