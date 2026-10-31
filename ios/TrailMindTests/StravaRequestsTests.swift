import XCTest
@testable import TrailMind

final class StravaRequestsTests: XCTestCase {
    private let track: [[TrackPoint]] = [[
        TrackPoint(lat: 54.4542, lon: -3.2115, ele: 978.04, timeMs: 1_761_901_200_000),
        TrackPoint(lat: 54.455, lon: -3.21, ele: 960.0, timeMs: 1_761_901_260_000),
    ]]

    // MARK: Upload

    func testTheUploadFormCarriesEveryFieldStravaReadsAndTheFile() {
        let gpx = Array("<gpx/>".utf8)
        let form = StravaRequests.uploadForm(gpx: gpx, fileName: StravaRequests.uploadFileName(7), name: "Scafell Pike",
                                             kind: .walk, externalId: StravaPolicy.externalId(1_761_901_200_000, 7), boundary: "B")
        XCTAssertEqual("multipart/form-data; boundary=B", form.contentType)
        func field(_ name: String, _ value: String) -> String {
            "--B\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        let expected = field("data_type", "gpx") + field("name", "Scafell Pike") + field("description", "Recorded with TrailMind") +
            field("activity_type", "walk") + field("external_id", "trailmind-7-1761901200000") +
            "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"trailmind-7.gpx\"\r\n" +
            "Content-Type: application/gpx+xml\r\n\r\n<gpx/>\r\n--B--\r\n"
        XCTAssertEqual(expected, String(decoding: form.build(), as: UTF8.self))
        XCTAssertEqual("hike", String(decoding: StravaRequests.uploadForm(gpx: gpx, fileName: "f.gpx", name: "n", kind: .hike,
                                                                          externalId: "x", boundary: "B").build(), as: UTF8.self)
            .components(separatedBy: "name=\"activity_type\"\r\n\r\n")[1].components(separatedBy: "\r\n")[0])
    }

    func testTheHikeIsPostedAsTheChosenKindWithTrailMindsDescription() {
        let walk = String(decoding: StravaRequests.hikeGpx(name: "Morning <walk>", segments: track, kind: .walk), as: UTF8.self)
        XCTAssertTrue(walk.contains("    <name>Morning &lt;walk&gt;</name>\n    <desc>Recorded with TrailMind</desc>\n    <type>walking</type>\n"))
        XCTAssertTrue(walk.contains("<trkpt lat=\"54.4542000\" lon=\"-3.2115000\"><ele>978.0</ele><time>2025-10-31T09:00:00Z</time></trkpt>"))
        let hike = String(decoding: StravaRequests.hikeGpx(name: "Hike", segments: track, kind: .hike), as: UTF8.self)
        XCTAssertTrue(hike.contains("<type>hiking</type>"))
        XCTAssertEqual(GpxWriter.trackToString("Hike", track).replacingOccurrences(of: "<type>hiking</type>",
                                                                                  with: "<desc>Recorded with TrailMind</desc>\n    <type>hiking</type>"),
                       hike)
    }

    func testTheGpxForUploadingByHandIsAlwaysAHike() {
        let gpx = StravaRequests.handUploadGpx(name: "Evening stroll", segments: track)
        XCTAssertTrue(gpx.contains("<desc>Recorded with TrailMind</desc>\n    <type>hiking</type>"))
        XCTAssertEqual(2, gpx.components(separatedBy: "<trkpt ").count - 1)
    }

    func testTheSignInStateIsLowerCaseHex() {
        XCTAssertEqual("00010a0fff7f", StravaRequests.stateText([0, 1, 10, 15, 255, 127]))
        XCTAssertEqual(32, StravaRequests.stateText([UInt8](repeating: 0xAB, count: 16)).count)
        XCTAssertEqual("", StravaRequests.stateText([]))
    }

    // MARK: Connecting

    func testTheClientIdMustBeANumber() {
        let wrong = StravaConnect.Check.invalid("The Client ID is the number at the top of your Strava application's page.")
        XCTAssertEqual(wrong, StravaConnect.check(clientId: "", clientSecret: "s", savedClientId: "", hasSavedSecret: false))
        XCTAssertEqual(wrong, StravaConnect.check(clientId: "  \t", clientSecret: "s", savedClientId: "", hasSavedSecret: false))
        XCTAssertEqual(wrong, StravaConnect.check(clientId: "12a4", clientSecret: "s", savedClientId: "", hasSavedSecret: false))
        XCTAssertEqual(wrong, StravaConnect.check(clientId: "12 34", clientSecret: "s", savedClientId: "", hasSavedSecret: false))
        XCTAssertEqual(wrong, StravaConnect.check(clientId: "-1234", clientSecret: "s", savedClientId: "", hasSavedSecret: false))
        // Surrounding spaces are trimmed; any decimal digit counts, as Kotlin's isDigit does.
        XCTAssertEqual(.ready(clientId: "12345", clientSecret: "abc", otherApp: true),
                       StravaConnect.check(clientId: " 12345\n", clientSecret: " abc ", savedClientId: "", hasSavedSecret: false))
        XCTAssertEqual(.ready(clientId: "١٢٣", clientSecret: "abc", otherApp: true),
                       StravaConnect.check(clientId: "١٢٣", clientSecret: "abc", savedClientId: "", hasSavedSecret: false))
    }

    func testABlankSecretKeepsTheSavedOneOnlyForTheSameApplication() {
        let paste = StravaConnect.Check.invalid("Paste the Client Secret from your Strava application's page.")
        XCTAssertEqual(paste, StravaConnect.check(clientId: "123", clientSecret: "  ", savedClientId: "", hasSavedSecret: false))
        XCTAssertEqual(paste, StravaConnect.check(clientId: "123", clientSecret: "", savedClientId: "123", hasSavedSecret: false))
        XCTAssertEqual(paste, StravaConnect.check(clientId: "456", clientSecret: "", savedClientId: "123", hasSavedSecret: true))
        XCTAssertEqual(.ready(clientId: "123", clientSecret: "", otherApp: false),
                       StravaConnect.check(clientId: "123", clientSecret: "", savedClientId: "123", hasSavedSecret: true))
        XCTAssertEqual(.ready(clientId: "123", clientSecret: "new", otherApp: false),
                       StravaConnect.check(clientId: "123", clientSecret: "new", savedClientId: "123", hasSavedSecret: true))
        XCTAssertEqual(.ready(clientId: "456", clientSecret: "new", otherApp: true),
                       StravaConnect.check(clientId: "456", clientSecret: "new", savedClientId: "123", hasSavedSecret: true))
    }

    func testLinkingSaysWhatHappened() {
        XCTAssertEqual("Linked to Strava as Graham · @forest_walker.",
                       StravaText.linked(StravaAthlete(id: 1, username: "forest_walker", firstName: "Graham", lastName: nil)))
        XCTAssertEqual("Linked to Strava as your account.", StravaText.linked(nil))
        XCTAssertNil(StravaText.linkFailure(.ok([:])))
        XCTAssertEqual("Strava didn't accept the Client ID and secret. Check them on your application's page at " +
                       "strava.com/settings/api. (Bad Request: Application client_id invalid)",
                       StravaText.linkFailure(.http(code: 400, message: "Bad Request: Application client_id invalid", retryAfterS: nil)))
        XCTAssertEqual("Strava didn't accept the Client ID and secret. Check them on your application's page at strava.com/settings/api. ()",
                       StravaText.linkFailure(.http(code: 401, message: "", retryAfterS: nil)))
        XCTAssertEqual("Strava said no (HTTP 503): Service Unavailable",
                       StravaText.linkFailure(.http(code: 503, message: "Service Unavailable", retryAfterS: nil)))
        XCTAssertEqual("Couldn't reach Strava: The request timed out.", StravaText.linkFailure(.offline(message: "The request timed out.")))
    }

    func testTheSavedAthleteLeavesOutBlankNames() {
        XCTAssertNil(StravaAthlete.saved(id: 0, username: "x", firstName: "y", lastName: "z"))
        XCTAssertEqual(StravaAthlete(id: 5, username: nil, firstName: "Ann", lastName: nil),
                       StravaAthlete.saved(id: 5, username: " ", firstName: "Ann", lastName: ""))
        XCTAssertEqual("Strava athlete 9", StravaAthlete.saved(id: 9, username: "", firstName: "", lastName: "")?.display)
    }

    func testThePageCountsWaitingHikesAndExplainsPosting() {
        XCTAssertEqual("1 hike is waiting to be posted. They go as soon as the phone has signal.", StravaText.waiting(1))
        XCTAssertEqual("3 hikes are waiting to be posted. They go as soon as the phone has signal.", StravaText.waiting(3))
        XCTAssertEqual("A hike is posted when you finish it, with its name, track, times and heights, as \"Recorded with TrailMind\". " +
                       "Recordings under 250 m are skipped. Your Strava privacy settings decide who sees it. " +
                       "Without signal it's posted later. Each hike can be posted by hand from its page too.", StravaText.postingHelp)
    }

    // MARK: Tokens

    func testTheSavedAccessTokenIsUsedUntilItIsAboutToLapse() {
        let now: Int64 = 1_000_000
        let fresh = StravaTokens(accessToken: "A", refreshToken: "R", expiresAtS: now + 3_600)
        XCTAssertEqual("A", StravaQueuePolicy.currentAccessToken(fresh, nowS: now))
        XCTAssertNil(StravaQueuePolicy.currentAccessToken(fresh, nowS: now, force: true))
        XCTAssertNil(StravaQueuePolicy.currentAccessToken(StravaTokens(accessToken: "A", refreshToken: "R", expiresAtS: now + 600), nowS: now))
        XCTAssertEqual("A", StravaQueuePolicy.currentAccessToken(StravaTokens(accessToken: "A", refreshToken: "R", expiresAtS: now + 601), nowS: now))
        XCTAssertNil(StravaQueuePolicy.currentAccessToken(StravaTokens(accessToken: " ", refreshToken: "R", expiresAtS: now + 3_600), nowS: now))
    }

    func testUnlinkingRenewsAnExpiredTokenOnlyWhenItCan() {
        let now: Int64 = 1_000_000
        XCTAssertFalse(StravaQueuePolicy.revokeNeedsRefresh(StravaTokens(accessToken: "A", refreshToken: "R", expiresAtS: now + 3_600), nowS: now))
        XCTAssertTrue(StravaQueuePolicy.revokeNeedsRefresh(StravaTokens(accessToken: "A", refreshToken: "R", expiresAtS: now - 1), nowS: now))
        XCTAssertTrue(StravaQueuePolicy.revokeNeedsRefresh(StravaTokens(accessToken: "", refreshToken: "R", expiresAtS: now + 3_600), nowS: now))
        XCTAssertFalse(StravaQueuePolicy.revokeNeedsRefresh(StravaTokens(accessToken: "A", refreshToken: "", expiresAtS: now - 1), nowS: now))
    }
}
