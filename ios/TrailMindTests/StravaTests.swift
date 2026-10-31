import XCTest
@testable import TrailMind

private extension StravaOAuth.Redirect {
    var granted: Granted? {
        if case .granted(let g) = self { return g }
        return nil
    }

    var refusedReason: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }

    var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}

private extension StravaUploadResult {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isDuplicate: Bool {
        if case .duplicate = self { return true }
        return false
    }
}

final class StravaTests: XCTestCase {
    private let state = "a1b2c3d4"

    func testAuthorizeUrlAsksForOnlyWhatItNeedsAndCarriesTheState() {
        let url = StravaOAuth.authorizeUrl("https://www.strava.com/", " 12345 ", state)
        XCTAssertTrue(url.hasPrefix("https://www.strava.com/oauth/mobile/authorize?"))
        XCTAssertTrue(url.contains("client_id=12345&"))
        XCTAssertTrue(url.contains("redirect_uri=trailmind%3A%2F%2Flocalhost%2Fstrava"))
        XCTAssertTrue(url.contains("response_type=code"))
        XCTAssertTrue(url.contains("scope=read%2Cactivity%3Awrite"))
        XCTAssertTrue(url.hasSuffix("&state=\(state)"))
        // Nothing that reads the athlete's activities.
        XCTAssertFalse(url.contains("activity%3Aread"))
    }

    func testAGrantedRedirectGivesTheCodeAndScopes() throws {
        let r = StravaOAuth.parseRedirect("trailmind://localhost/strava?state=\(state)&code=abc123&scope=read,activity:write", state)
        let granted = try XCTUnwrap(r.granted)
        XCTAssertEqual("abc123", granted.code)
        XCTAssertEqual(["read", "activity:write"], granted.scopes)
        XCTAssertTrue(granted.canUpload)
    }

    func testScopesMayComeUrlEncodedOrSpaceSeparated() throws {
        let a = try XCTUnwrap(StravaOAuth.parseRedirect(
            "trailmind://localhost/strava?state=\(state)&code=c&scope=read%2Cactivity%3Awrite", state).granted)
        XCTAssertTrue(a.canUpload)
        let b = try XCTUnwrap(StravaOAuth.parseRedirect(
            "trailmind://localhost/strava?state=\(state)&code=c&scope=read%20activity%3Awrite", state).granted)
        XCTAssertTrue(b.canUpload)
    }

    func testTheUserCanOptOutOfUploading() throws {
        let r = try XCTUnwrap(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=\(state)&code=c&scope=read", state).granted)
        XCTAssertFalse(r.canUpload)
    }

    func testAWrongOrMissingStateIsNotAnAnswerToThisSignIn() {
        XCTAssertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=other&code=c&scope=read", state).isInvalid)
        XCTAssertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?code=c&scope=read", state).isInvalid)
        XCTAssertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=\(state)&code=c", nil).isInvalid)
        XCTAssertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=\(state)&code=c", "").isInvalid)
        // The same length but not the same.
        XCTAssertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=a1b2c3d5&code=c", state).isInvalid)
    }

    func testAMalformedLinkIsIgnoredNotACrash() {
        // Any web page or app can open trailmind://localhost/strava, so garbage must come back as "not an answer".
        XCTAssertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?x=%zz", state).isInvalid)
        XCTAssertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=\(state)&code=%", state).isInvalid)
        XCTAssertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?%e0%a4%a=1&state=\(state)", state).isInvalid)
    }

    func testRefusalsAreReportedInPlainWords() throws {
        let denied = StravaOAuth.parseRedirect("trailmind://localhost/strava?state=\(state)&error=access_denied", state)
        XCTAssertTrue(try XCTUnwrap(denied.refusedReason).contains("didn't allow"))
        let other = try XCTUnwrap(StravaOAuth.parseRedirect(
            "trailmind://localhost/strava?state=\(state)&error=redirect_uri_mismatch", state).refusedReason)
        XCTAssertTrue(other.contains("redirect_uri_mismatch"))
        XCTAssertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=\(state)", state).isInvalid)
    }

    func testOnlyTrailMindsOwnRedirectIsRecognised() {
        XCTAssertTrue(StravaOAuth.isRedirect("trailmind://localhost/strava?code=1"))
        XCTAssertTrue(StravaOAuth.isRedirect("TrailMind://LOCALHOST/strava"))
        XCTAssertFalse(StravaOAuth.isRedirect("trailmind://group/join?code=1"))
        XCTAssertFalse(StravaOAuth.isRedirect("https://localhost/strava"))
        XCTAssertFalse(StravaOAuth.isRedirect("trailmind://example.com/strava"))
        XCTAssertFalse(StravaOAuth.isRedirect("not a url"))
        XCTAssertTrue(StravaOAuth.parseRedirect("https://evil.example/strava?state=\(state)&code=c", state).isInvalid)
    }

    func testTokenCallBodiesAreFormEncoded() {
        XCTAssertEqual("client_id=42&client_secret=s%26%3D&code=c+d&grant_type=authorization_code",
                       StravaOAuth.tokenRequestBody(" 42 ", " s&= ", "c d"))
        XCTAssertEqual("client_id=42&client_secret=sec&grant_type=refresh_token&refresh_token=r%2Ft",
                       StravaOAuth.refreshRequestBody("42", "sec", "r/t"))
    }

    func testAnAccessTokenIsRenewedBeforeItLapses() {
        let t = StravaTokens(accessToken: "a", refreshToken: "r", expiresAtS: 100_000, scope: "read,activity:write")
        XCTAssertFalse(t.needsRefresh(100_000 - 3_600))
        XCTAssertTrue(t.needsRefresh(100_000 - 599))
        XCTAssertTrue(t.needsRefresh(100_001))
        XCTAssertTrue(t.canUpload)
        var readOnly = t
        readOnly.scope = "read"
        XCTAssertFalse(readOnly.canUpload)
        var noScope = t
        noScope.scope = ""
        XCTAssertFalse(noScope.canUpload)
    }

    func testTheLinkedAthleteIsShownByNameAndHandle() {
        XCTAssertEqual("Graham Hosking · @graham",
                       StravaAthlete(id: 1, username: "graham", firstName: "Graham", lastName: "Hosking").display)
        XCTAssertEqual("@graham", StravaAthlete(id: 1, username: "graham", firstName: "Graham", lastName: "Hosking").handle)
        // Many athletes have no username.
        XCTAssertEqual("Graham Hosking", StravaAthlete(id: 1, username: nil, firstName: "Graham", lastName: "Hosking").display)
        XCTAssertNil(StravaAthlete(id: 1, username: " ", firstName: "G", lastName: nil).handle)
        XCTAssertEqual("Strava athlete 7", StravaAthlete(id: 7, username: nil, firstName: nil, lastName: nil).display)
        XCTAssertEqual("@only", StravaAthlete(id: 7, username: "only", firstName: "", lastName: "").display)
    }

    func testMultipartHasEachFieldTheFileAndTheClosingBoundary() throws {
        let m = StravaMultipart("XYZ").field("name", "Forest \"loop\"\nhike").field("data_type", "gpx")
            .file("file", "a\"b.gpx", "application/gpx+xml", Array("<gpx/>".utf8))
        let body = String(decoding: m.build(), as: UTF8.self)
        XCTAssertEqual("multipart/form-data; boundary=XYZ", m.contentType)
        XCTAssertTrue(body.hasPrefix("--XYZ\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nForest \"loop\"\nhike\r\n"))
        XCTAssertTrue(body.contains("name=\"data_type\"\r\n\r\ngpx\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"a'b.gpx\"\r\nContent-Type: application/gpx+xml\r\n\r\n<gpx/>\r\n"))
        XCTAssertTrue(body.hasSuffix("--XYZ--\r\n"))
        let boundaries = try NSRegularExpression(pattern: "--XYZ\r\n")
        XCTAssertEqual(3, boundaries.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body)))
    }

    func testUploadAnswersAreReadFromTheirFields() {
        XCTAssertEqual(StravaUploadResult.ready(activityId: 99), StravaPolicy.classify("Your activity is ready.", nil, 99))
        XCTAssertEqual(StravaUploadResult.processing, StravaPolicy.classify("Your activity is still being processed.", nil, nil))
        XCTAssertEqual(StravaUploadResult.processing, StravaPolicy.classify(nil, nil, 0))
        XCTAssertTrue(StravaPolicy.classify("There was an error processing your activity.", nil, nil).isFailed)
        XCTAssertTrue(StravaPolicy.classify("The created activity has been deleted.", nil, nil).isFailed)
        XCTAssertEqual(StravaUploadResult.failed(message: "file is empty"), StravaPolicy.classify("ok", "file is empty", nil))
        // Strava says "duplicate" for a file it already has.
        let dup = StravaPolicy.classify("There was an error processing your activity.", "trailmind.gpx duplicate of activity 5", nil)
        XCTAssertTrue(dup.isDuplicate)
    }

    func testOnlyRealHikesArePosted() {
        XCTAssertTrue(StravaPolicy.worthPosting(3_000.0, 120))
        XCTAssertFalse(StravaPolicy.worthPosting(120.0, 120))
        XCTAssertFalse(StravaPolicy.worthPosting(3_000.0, 4))
    }

    func testRetriesBackOffAndNamesAreSafe() {
        XCTAssertEqual([1, 5, 15, 60, 360, 360], (1...6).map { Int(StravaPolicy.retryDelayMs($0) / 60_000) })
        XCTAssertEqual("trailmind-7-1790000000000", StravaPolicy.externalId(1_790_000_000_000, 7))
        XCTAssertEqual("Hike", StravaPolicy.activityName("   "))
        XCTAssertEqual(255, StravaPolicy.activityName(String(repeating: "x", count: 400)).utf16.count)
        XCTAssertEqual("Forest · Oct 11", StravaPolicy.activityName("  Forest · Oct 11 "))
        XCTAssertEqual("https://www.strava.com/activities/123", StravaPolicy.activityUrl(123))
        XCTAssertEqual(StravaActivityKind.hike, StravaActivityKind.of(nil))
        XCTAssertEqual(StravaActivityKind.walk, StravaActivityKind.of("walk"))
        XCTAssertEqual("hike", StravaActivityKind.hike.code)
    }
}
