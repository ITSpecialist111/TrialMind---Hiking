import XCTest
@testable import TrailMind

private extension StravaReply {
    var body: [String: Any]? {
        if case .ok(let body) = self { return body }
        return nil
    }

    var http: (code: Int, message: String, retryAfterS: Int64?)? {
        if case .http(let code, let message, let retryAfterS) = self { return (code, message, retryAfterS) }
        return nil
    }
}

final class StravaRepliesTests: XCTestCase {
    private func object(_ s: String) throws -> [String: Any] { try BeaconJSON.object(Data(s.utf8)) }

    // MARK: Answers

    func testStravasOwnWordsExplainAFailure() {
        XCTAssertEqual("Bad Request: Application client_id invalid", StravaReplies.explain(
            #"{"message": "Bad Request", "errors": [{"resource": "Application", "field": "client_id", "code": "invalid"}]}"#))
        XCTAssertEqual("Authorization Error: Athlete access_token invalid: RefreshToken refresh_token invalid", StravaReplies.explain(
            #"{"message":"Authorization Error","errors":[{"resource":"Athlete","field":"access_token","code":"invalid"},{"resource":"RefreshToken","field":"refresh_token","code":"invalid"}]}"#))
        XCTAssertEqual("Rate Limit Exceeded", StravaReplies.explain(#"{"message":"Rate Limit Exceeded","errors":[{"resource":"","field":" ","code":""},"x"]}"#))
        XCTAssertEqual("{}", StravaReplies.explain("{}"))
        XCTAssertEqual("", StravaReplies.explain(""))
        let page = "<html>" + String(repeating: "x", count: 300) + "</html>"
        XCTAssertEqual(String(page.prefix(200)), StravaReplies.explain(page))
    }

    func testOnlySuccessBodiesAreKept() throws {
        let created = StravaReplies.reply(code: 201, body: Data(#"{"id": 101, "status": "Your activity is still being processed."}"#.utf8), retryAfter: nil)
        XCTAssertEqual(101, BeaconJSON.optLong(try XCTUnwrap(created.body), "id"))
        XCTAssertEqual(0, try XCTUnwrap(StravaReplies.reply(code: 200, body: Data("not json".utf8), retryAfter: nil).body).count)
        let limited = try XCTUnwrap(StravaReplies.reply(code: 429, body: Data(#"{"message":"Rate Limit Exceeded"}"#.utf8), retryAfter: "900").http)
        XCTAssertEqual(429, limited.code)
        XCTAssertEqual("Rate Limit Exceeded", limited.message)
        XCTAssertEqual(900, limited.retryAfterS)
        XCTAssertNil(StravaReplies.reply(code: 503, body: Data(), retryAfter: "soon").http?.retryAfterS)
        XCTAssertEqual(302, StravaReplies.reply(code: 302, body: Data(), retryAfter: nil).http?.code)
    }

    func testASignInGivesTheTokensAndWhoSignedIn() throws {
        let body = try object(#"{"token_type":"Bearer","expires_at":1761900000,"expires_in":120,"refresh_token":"R1","access_token":"ACCESS1","athlete":{"id":987654,"username":"forest_walker","firstname":"Graham","lastname":null}}"#)
        XCTAssertEqual(StravaReplies.TokenUpdate(accessToken: "ACCESS1", refreshToken: "R1", expiresAtS: 1_761_900_000),
                       StravaReplies.tokens(body, nowS: 1_761_000_000))
        XCTAssertEqual(StravaReplies.AthleteFields(id: 987_654, username: "forest_walker", firstName: "Graham", lastName: ""),
                       StravaReplies.athlete(body))
        let athlete = StravaAthlete(id: 987_654, username: "forest_walker", firstName: "Graham", lastName: nil)
        XCTAssertEqual("Graham · @forest_walker", athlete.display)
    }

    func testARefreshKeepsTheOldRefreshTokenUnlessANewOneComes() throws {
        XCTAssertEqual(StravaReplies.TokenUpdate(accessToken: "A2", refreshToken: nil, expiresAtS: 1_000 + 3_600),
                       StravaReplies.tokens(try object(#"{"access_token":"A2","refresh_token":"  ","expires_in":3600}"#), nowS: 1_000))
        XCTAssertEqual(StravaReplies.TokenUpdate(accessToken: "A3", refreshToken: nil, expiresAtS: 1_000 + 21_600),
                       StravaReplies.tokens(try object(#"{"access_token":"A3"}"#), nowS: 1_000))
        XCTAssertNil(StravaReplies.athlete(try object(#"{"access_token":"A3"}"#)))
        XCTAssertEqual(StravaReplies.AthleteFields(id: 0, username: "", firstName: "", lastName: ""),
                       StravaReplies.athlete(try object(#"{"athlete":{}}"#)))
    }

    func testUploadAnswersSayWhatBecameOfTheUpload() throws {
        let processing = try object(#"{"id": 101, "id_str": "101", "external_id": "trailmind-7-1", "error": null, "status": "Your activity is still being processed.", "activity_id": null}"#)
        XCTAssertEqual(101, StravaReplies.uploadId(processing))
        XCTAssertEqual(.processing, StravaReplies.uploadResult(processing))
        let ready = try object(#"{"id": 101, "error": null, "status": "Your activity is ready.", "activity_id": 555101}"#)
        XCTAssertEqual(.ready(activityId: 555_101), StravaReplies.uploadResult(ready))
        let duplicate = try object(#"{"id": 102, "error": "Morning hike.gpx duplicate of activity 4242", "status": "There was an error processing your activity.", "activity_id": null}"#)
        XCTAssertEqual(.duplicate(message: "Morning hike.gpx duplicate of activity 4242"), StravaReplies.uploadResult(duplicate))
        let broken = try object(#"{"id": 103, "error": "Improperly formatted data.", "status": "There was an error processing your activity."}"#)
        XCTAssertEqual(.failed(message: "Improperly formatted data."), StravaReplies.uploadResult(broken))
        XCTAssertNil(StravaReplies.uploadId(try object(#"{"id": 0}"#)))
        XCTAssertNil(StravaReplies.uploadId(try object(#"{"message": "ok"}"#)))
        XCTAssertEqual(17, StravaReplies.uploadId(try object(#"{"id": "17"}"#)))
    }

    // MARK: The posting queue

    func testFailedCallsWaitRetryOrGiveUpAsOnAndroid() {
        let now: Int64 = 1_000_000
        XCTAssertEqual(.save(state: .queued, message: "Strava's limit was reached; trying again later.", attempts: 2, nextTryMs: now + 15 * 60_000),
                       StravaQueuePolicy.later(attempts: 2, reply: .http(code: 429, message: "Rate Limit Exceeded", retryAfterS: nil), now: now))
        XCTAssertEqual(.reconnect, StravaQueuePolicy.later(attempts: 0, reply: .http(code: 403, message: "Forbidden", retryAfterS: nil), now: now))
        XCTAssertEqual(.save(state: .failed, message: "Strava refused it (HTTP 400): Bad Request: Upload file invalid", attempts: 1, nextTryMs: 0),
                       StravaQueuePolicy.later(attempts: 1, reply: .http(code: 400, message: "Bad Request: Upload file invalid", retryAfterS: nil), now: now))
        XCTAssertEqual(.save(state: .queued, message: "Strava had a problem (HTTP 408).", attempts: 1, nextTryMs: now + 60_000),
                       StravaQueuePolicy.later(attempts: 0, reply: .http(code: 408, message: "", retryAfterS: nil), now: now))
        XCTAssertEqual(.save(state: .queued, message: "Strava had a problem (HTTP 503).", attempts: 3, nextTryMs: now + 15 * 60_000),
                       StravaQueuePolicy.later(attempts: 2, reply: .http(code: 503, message: "", retryAfterS: nil), now: now))
        XCTAssertEqual(.save(state: .queued, message: "No connection to Strava: The Internet connection appears to be offline.", attempts: 5,
                             nextTryMs: now + 6 * 3_600_000),
                       StravaQueuePolicy.later(attempts: 4, reply: .offline(message: "The Internet connection appears to be offline."), now: now))
        XCTAssertEqual(.save(state: .failed, message: "No connection to Strava: timed out Gave up after 8 tries.", attempts: 8, nextTryMs: 0),
                       StravaQueuePolicy.later(attempts: 7, reply: .offline(message: "timed out"), now: now))
        XCTAssertEqual(.save(state: .queued, message: "Strava's answer wasn't understood.", attempts: 1, nextTryMs: now + 60_000),
                       StravaQueuePolicy.later(attempts: 0, reply: .ok([:]), now: now))
    }

    func testOnlyARefusedRefreshMeansConnectingAgain() {
        for code in [400, 401, 402, 403] {
            XCTAssertTrue(StravaQueuePolicy.refreshNeedsReconnect(.http(code: code, message: "", retryAfterS: nil)), "\(code)")
        }
        for code in [404, 429, 500, 503] {
            XCTAssertFalse(StravaQueuePolicy.refreshNeedsReconnect(.http(code: code, message: "", retryAfterS: nil)), "\(code)")
        }
        XCTAssertFalse(StravaQueuePolicy.refreshNeedsReconnect(.offline(message: "no connection")))
    }

    func testTheQueueComesBackWhenTheNextPostIsDue() {
        XCTAssertNil(StravaQueuePolicy.nextWaitMs(nextTryMs: nil, now: 10_000))
        XCTAssertEqual(5_000, StravaQueuePolicy.nextWaitMs(nextTryMs: 10_100, now: 10_000))
        XCTAssertEqual(5_000, StravaQueuePolicy.nextWaitMs(nextTryMs: 0, now: 10_000))
        XCTAssertEqual(60_000, StravaQueuePolicy.nextWaitMs(nextTryMs: 70_000, now: 10_000))
        XCTAssertEqual("Too short to be a hike (under 250 m).", StravaQueuePolicy.tooShortMessage)
    }

    func testEachHikeSaysWhereItIsWithStrava() {
        func status(_ state: StravaPostState?, _ message: String? = nil, activity: Int64? = nil, linked: Bool = true,
                    reconnect: Bool = false, live: Bool = false) -> String? {
            StravaQueuePolicy.status(state: state, message: message, activityId: activity, linked: linked, needsReconnect: reconnect, live: live)
        }
        XCTAssertEqual("Strava stopped accepting TrailMind, so this hike can't be posted by itself.", status(.queued, linked: false, reconnect: true))
        XCTAssertNil(status(nil, linked: false))
        XCTAssertNil(status(.failed, "x", linked: false))
        XCTAssertEqual("Posted to Strava ✓", status(.posted, activity: 9, linked: false))
        XCTAssertEqual("Not posted to Strava.", status(nil))
        XCTAssertEqual("You can post it once it's finished.", status(nil, live: true))
        XCTAssertEqual("Waiting to post. It goes as soon as the phone has signal.", status(.queued))
        XCTAssertEqual("Waiting to post. Strava's limit was reached; trying again later.", status(.queued, "Strava's limit was reached; trying again later."))
        XCTAssertEqual("Strava is processing this hike…", status(.processing))
        XCTAssertEqual("Posted to Strava ✓", status(.posted, activity: 555))
        XCTAssertEqual("Already on Strava.", status(.posted, "Already on Strava."))
        XCTAssertEqual("On Strava ✓", status(.posted))
        XCTAssertEqual("Couldn't post this hike. Strava refused it (HTTP 400): Bad Request", status(.failed, "Strava refused it (HTTP 400): Bad Request"))
        XCTAssertEqual("Too short to be a hike (under 250 m).", status(.skipped, "Too short to be a hike (under 250 m)."))
        XCTAssertEqual("Not posted to Strava.", status(.skipped))
    }
}
