import XCTest
@testable import TrailMind

/// The what3words request building and response checks (data/What3words.kt has no Android unit tests; these pin its
/// behaviour: URLs, error messages and the order of checks).
final class SafetyWhat3wordsTests: XCTestCase {
    private let sample = """
        {"country":"GB","square":{"southwest":{"lng":-0.195543,"lat":51.520833},"northeast":{"lng":-0.195499,"lat":51.52086}},
         "nearestPlace":"Bayswater, London","coordinates":{"lng":-0.195521,"lat":51.520847},"words":"filled.count.soap",
         "language":"en","map":"https://w3w.co/filled.count.soap"}
        """

    private func error(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as What3wordsError { return e.message } catch { return "\(error)" }
    }

    func testLocateUrlAsksForThePositionInEnglish() {
        XCTAssertEqual("https://api.what3words.com/v3/convert-to-3wa?coordinates=54.4609%2C-3.0886&language=en",
                       What3wordsApi.locateURL(54.4609, -3.0886))
    }

    func testCoordinatesBesideTheMeridianStayPlainDecimals() {
        XCTAssertEqual("-0.0005", What3wordsApi.decimal(-0.0005))
        XCTAssertEqual("0.00001", What3wordsApi.decimal(0.00001))
        XCTAssertEqual("54.0", What3wordsApi.decimal(54.0))
        XCTAssertEqual("51.520847", What3wordsApi.decimal(51.520847))
        XCTAssertTrue(What3wordsApi.locateURL(51.4779, -0.00005).contains("coordinates=51.4779%2C-0.00005&"))
    }

    func testSearchUrlUsesTheNormalisedWords() throws {
        let request = try What3wordsApi.searchURL("  ///Filled.Count.Soap ")
        XCTAssertEqual("filled.count.soap", request.words)
        XCTAssertEqual("https://api.what3words.com/v3/convert-to-coordinates?words=filled.count.soap", request.url)
        XCTAssertEqual("https://api.what3words.com/v3/convert-to-coordinates?words=%C3%A9cole.d%27art.fen%C3%AAtre",
                       try What3wordsApi.searchURL("école.d'art.fenêtre").url)
        XCTAssertEqual(What3wordsApi.needThreeWords, error { _ = try What3wordsApi.searchURL("filled count soap") })
    }

    func testFormEncodingMatchesJavasUrlEncoder() {
        XCTAssertEqual("a+b%2Bc%2F%C3%A9%27*_-.%7E%2C", What3wordsApi.formEncode("a b+c/é'*_-.~,"))
    }

    func testReadsAnAddressWithItsSquare() throws {
        let a = try What3wordsApi.parseResponse(sample)
        XCTAssertEqual("filled.count.soap", a.words)
        XCTAssertEqual(LatLon(51.520847, -0.195521), a.position)
        XCTAssertEqual(LatLon(51.520833, -0.195543), a.southwest)
        XCTAssertEqual(LatLon(51.52086, -0.195499), a.northeast)
        XCTAssertEqual("Bayswater, London", a.nearby)
        XCTAssertTrue(a.contains(LatLon(51.52084, -0.19552)))
        XCTAssertFalse(a.contains(LatLon(51.52086, -0.19552)), "the north edge belongs to the next square")
        XCTAssertNoThrow(try What3wordsApi.checkLocated(a, 51.52084, -0.19552))
        XCTAssertEqual(What3wordsApi.wrongLocation, error { try What3wordsApi.checkLocated(a, 51.53, -0.19552) })
        XCTAssertNoThrow(try What3wordsApi.checkSearched(a, "filled.count.soap"))
        XCTAssertEqual(What3wordsApi.wrongAddress, error { try What3wordsApi.checkSearched(a, "index.home.raft") })
    }

    func testNumbersSentAsTextAreRead() throws {
        let body = sample.replacingOccurrences(of: "\"lat\":51.520847", with: "\"lat\":\"51.520847\"")
        XCTAssertEqual(51.520847, try What3wordsApi.parseResponse(body).position.lat)
    }

    func testMissingNearestPlaceIsEmpty() throws {
        let body = sample.replacingOccurrences(of: "\"nearestPlace\":\"Bayswater, London\",", with: "")
        XCTAssertEqual("", try What3wordsApi.parseResponse(body).nearby)
    }

    func testErrorsAreReportedInAndroidsWordsAndOrder() {
        XCTAssertEqual(What3wordsApi.conversionFailed,
                       error { _ = try What3wordsApi.parseResponse(#"{"error":{"code":"BadWords","message":"x"}}"#) })
        XCTAssertEqual(What3wordsApi.unreadable, error { _ = try What3wordsApi.parseResponse("<html>busy</html>") })
        XCTAssertEqual(What3wordsApi.unreadable, error { _ = try What3wordsApi.parseResponse("[1,2]") })
        XCTAssertEqual(What3wordsApi.unreadable, error { _ = try What3wordsApi.parseResponse(#"{"square":{}}"#) })
        XCTAssertEqual(What3wordsApi.invalidAddress, error {
            _ = try What3wordsApi.parseResponse(sample.replacingOccurrences(of: "\"words\":\"filled.count.soap\"", with: "\"words\":\"filled\""))
        })
        XCTAssertEqual(What3wordsApi.invalidAddress, error {
            _ = try What3wordsApi.parseResponse(sample.replacingOccurrences(of: "\"words\":\"filled.count.soap\"", with: "\"words\":12"))
        })
        XCTAssertEqual(What3wordsApi.unreadable, error {
            _ = try What3wordsApi.parseResponse(sample.replacingOccurrences(of: "\"lat\":51.520847", with: "\"lat\":true"))
        })
        XCTAssertEqual(What3wordsApi.invalidCoordinates, error {
            _ = try What3wordsApi.parseResponse(sample.replacingOccurrences(of: "\"lat\":51.520847", with: "\"lat\":91"))
        })
        XCTAssertEqual(What3wordsApi.invalidSquare, error {
            _ = try What3wordsApi.parseResponse(sample.replacingOccurrences(of: "\"lat\":51.520847", with: "\"lat\":51.6"))
        })
        // Words are checked before the square, as on Android.
        XCTAssertEqual(What3wordsApi.invalidAddress, error {
            _ = try What3wordsApi.parseResponse(#"{"words":"nope","coordinates":{"lat":200,"lng":0}}"#)
        })
    }

    func testHttpStatusMessages() {
        XCTAssertNil(What3wordsApi.statusMessage(200))
        XCTAssertEqual("what3words: address not found. Check all three words; spelling changes can point to a different country.",
                       What3wordsApi.statusMessage(404))
        XCTAssertEqual(What3wordsApi.statusMessage(400), What3wordsApi.statusMessage(404))
        XCTAssertEqual("what3words: check your API key, plan and conversion permissions in Settings.", What3wordsApi.statusMessage(402))
        XCTAssertEqual("what3words: request limit reached. Try again later.", What3wordsApi.statusMessage(429))
        XCTAssertEqual("what3words: service returned HTTP 302. Use coordinates or a grid reference instead.", What3wordsApi.statusMessage(302))
    }

    func testOnlyAFixFromTheLastMinuteIsLookedUp() {
        let now: Int64 = 1_800_000_000_000
        XCTAssertNil(error { try What3wordsApi.checkFresh(fixMs: now - 60_000, nowMs: now) })
        XCTAssertEqual(What3wordsApi.needFreshFix, error { try What3wordsApi.checkFresh(fixMs: now - 60_001, nowMs: now) })
        XCTAssertEqual(What3wordsApi.needFreshFix, error { try What3wordsApi.checkFresh(fixMs: now + 1, nowMs: now) })
        XCTAssertEqual(What3wordsApi.needKey, error { try What3wordsApi.checkKey(" \t") })
        XCTAssertNil(error { try What3wordsApi.checkKey("ABC123") })
    }

    func testAnAnswerIsSharedOnlyInTheSameSquareForAMinute() throws {
        let a = try What3wordsApi.parseResponse(sample)
        let now: Int64 = 1_800_000_000_000
        let here = LatLon(51.52084, -0.19552)
        XCTAssertTrue(ThreeWordAddress.canShare(now - 30_000, now - 1_000, now, a.contains(here)))
        XCTAssertFalse(ThreeWordAddress.canShare(now - 61_000, now - 1_000, now, a.contains(here)))
        XCTAssertFalse(ThreeWordAddress.canShare(now - 30_000, now - 1_000, now, a.contains(LatLon(51.5209, -0.19552))))
    }
}

/// The World Magnetic Model against NOAA's official WMM2025 test values (WMM2025_TestValues.txt).
final class WorldMagneticModelTests: XCTestCase {
    // year, height km, lat, lon, declination, inclination, X, Y, Z, F
    private let rows: [[Double]] = [
        [2025.0, 28, 89, -121, -99.77, 88.47, -255.388723, -1482.460628, 56194.288771, 56214.419888],
        [2025.0, 65, 43, 93, 0.50, 64.10, 24299.852822, 210.517066, 50037.923998, 55626.621348],
        [2025.0, 51, -33, 109, -5.49, -67.50, 21737.778822, -2090.274098, -52710.003920, 57054.752538],
        [2025.5, 63, 26, 81, 0.51, 41.07, 34802.613433, 308.431881, 30332.056989, 46166.554053],
        [2026.5, 14, 0, 80, -3.10, -17.15, 39431.415992, -2133.456168, -12188.838466, 41327.424134],
        [2027.0, 54, 54, 178, 0.63, 65.46, 20615.871559, 225.041793, 45149.631876, 49634.202547],
        [2027.5, 0, -13, -59, -17.49, -15.26, 21365.849306, -6732.560620, -6112.313520, 23220.406233],
        [2028.0, 71, 5, -13, -6.47, -17.66, 28142.647915, -3192.970202, -9017.928693, 29724.177504],
        [2028.5, 11, 34, 0, 1.57, 46.77, 29078.234597, 798.434048, 30945.577813, 42471.284539],
        [2029.0, 57, 34, -13, -1.89, 45.74, 28241.863242, -933.225495, 28997.458189, 40488.595068],
        [2029.5, 63, 88, 26, 36.52, 87.37, 2041.140972, 1511.567287, 55286.620082, 55344.931586],
    ]

    func testMatchesTheOfficialTestValues() {
        for r in rows {
            let f = WorldMagneticModel.field(latDeg: r[2], lonDeg: r[3], heightKm: r[1], decimalYear: r[0])
            let at = "\(r[0]) \(r[2]),\(r[3])"
            XCTAssertEqual(r[4], f.declinationDeg, accuracy: 0.0051, at)
            XCTAssertEqual(r[5], f.inclinationDeg, accuracy: 0.0051, at)
            XCTAssertEqual(r[6], f.northNt, accuracy: 0.01, at)
            XCTAssertEqual(r[7], f.eastNt, accuracy: 0.01, at)
            XCTAssertEqual(r[8], f.downNt, accuracy: 0.01, at)
            XCTAssertEqual(r[9], f.totalNt, accuracy: 0.01, at)
        }
    }

    func testDecimalYearCountsThroughTheYear() {
        let jan1 = CivilDate.epochDay(2025, 1, 1) * CivilDate.msPerDay
        XCTAssertEqual(2025.0, WorldMagneticModel.decimalYear(jan1))
        let midsummer = CivilDate.epochDay(2026, 7, 2) * CivilDate.msPerDay + 12 * 3_600_000
        XCTAssertEqual(2026.5, WorldMagneticModel.decimalYear(midsummer), accuracy: 1e-12)
    }

    func testGreatBritainHasASmallDeclinationAndSteepDip() {
        // Keswick, autumn 2026: the field dips about 70° and is close to 50 µT; declination within a couple of degrees.
        let f = WorldMagneticModel.field(LatLon(54.6, -3.13), altitudeM: 100, timeMs: CivilDate.epochDay(2026, 10, 31) * CivilDate.msPerDay)
        XCTAssertEqual(0, f.declinationDeg, accuracy: 2.5)
        XCTAssertEqual(70, f.inclinationDeg, accuracy: 2)
        XCTAssertEqual(49_500, f.totalNt, accuracy: 1_500)
    }
}

/// The fall alarm's stages and check-in timing (frontier/FallAlert.kt, location/CheckIn.kt), and the Safety texts.
final class SafetyStateTests: XCTestCase {
    private let t0: Int64 = 1_800_000_000_000

    func testStageNumbersMatchAndroid() {
        XCTAssertEqual([0, 1, 2, 3, 4], [FallAlarmStage.none, .countdown, .textReady, .sending, .sent].map(\.rawValue))
    }

    func testCountdownStartsOnceWhileAnAlarmRuns() {
        var s = FallAlarmState()
        XCTAssertTrue(s.start(t0))
        XCTAssertEqual(.countdown, s.stage)
        XCTAssertEqual(t0 + 60_000, s.deadlineMs)
        XCTAssertEqual(FallAlarmState.noResponse, s.situation)
        XCTAssertFalse(s.start(t0 + 5_000))
        XCTAssertEqual(t0, s.alertMs)
    }

    func testNoAnswerGetsTheTextReady() {
        var s = FallAlarmState()
        _ = s.start(t0)
        XCTAssertTrue(s.countdownEnded())
        XCTAssertEqual(.textReady, s.stage)
        XCTAssertEqual("No answer to the fall alarm", s.readyTitle)
        XCTAssertFalse(s.countdownEnded())
        XCTAssertFalse(s.start(t0 + 70_000), "a second fall does not restart a running alarm")
    }

    func testAskingForHelpBeginsAnAlarmWithThatSituation() {
        var s = FallAlarmState()
        s.sendNow(t0, situation: FallAlarmState.help)
        XCTAssertEqual(.textReady, s.stage)
        XCTAssertEqual(t0, s.alertMs)
        XCTAssertEqual("I need help", s.situation)
        XCTAssertEqual("Send your SOS text", s.readyTitle)

        var c = FallAlarmState()
        _ = c.start(t0)
        c.sendNow(t0 + 10_000)
        XCTAssertEqual(t0, c.alertMs, "sending from the countdown keeps the same alarm")
        XCTAssertEqual("Fall, I need help", c.situation)
    }

    func testSentThenOkClearsEverything() {
        var s = FallAlarmState()
        _ = s.start(t0)
        _ = s.countdownEnded()
        s.textFailed()
        XCTAssertEqual("Your SOS text didn't send", s.readyTitle)
        s.textSent(to: "07700900123", textMs: t0 + 65_000)
        XCTAssertEqual(.sent, s.stage)
        XCTAssertEqual("07700900123", s.recipient)
        XCTAssertEqual(t0 + 65_000, s.sentMs)
        XCTAssertFalse(s.running)
        XCTAssertTrue(s.start(t0 + 100_000), "a new fall after the text went starts a new alarm")
        XCTAssertEqual("", s.recipient)
        s.ok()
        XCTAssertEqual(FallAlarmState(), s)
    }

    func testCountdownText() {
        var s = FallAlarmState()
        _ = s.start(t0)
        XCTAssertEqual("1:00", s.countdownText(t0))
        XCTAssertEqual("0:59", s.countdownText(t0 + 500))
        XCTAssertEqual("0:01", s.countdownText(t0 + 59_000))
        XCTAssertEqual("0:00", s.countdownText(t0 + 61_000))
    }

    func testCheckInRemindsAtReturnTimeThenWhenOverdue() {
        let due = t0
        XCTAssertNil(CheckInSchedule.check(dueMs: due, stage: 0, nowMs: due - 1))
        XCTAssertEqual(1, CheckInSchedule.check(dueMs: due, stage: 0, nowMs: due))
        XCTAssertNil(CheckInSchedule.check(dueMs: due, stage: 1, nowMs: due + 29 * 60_000))
        XCTAssertEqual(2, CheckInSchedule.check(dueMs: due, stage: 1, nowMs: due + 30 * 60_000))
        XCTAssertEqual(2, CheckInSchedule.check(dueMs: due, stage: 0, nowMs: due + 31 * 60_000), "both missed: overdue")
        XCTAssertNil(CheckInSchedule.check(dueMs: due, stage: 2, nowMs: due + 99 * 60_000))
        XCTAssertNil(CheckInSchedule.check(dueMs: 0, stage: 0, nowMs: due))
    }

    func testSuggestedReturnTime() {
        XCTAssertEqual(t0 + 5_000, CheckInSchedule.suggestedMs(activeDueMs: t0 + 5_000, nowMs: t0, planningMinutes: 60))
        XCTAssertEqual(TripReadiness.defaultReturnMs(t0, planningMinutes: 60),
                       CheckInSchedule.suggestedMs(activeDueMs: t0 - 5_000, nowMs: t0, planningMinutes: 60))
    }

    func testPickedClockTimeRollsOnToTomorrowOnceItHasPassed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = CivilDate.epochDay(2026, 10, 31) * CivilDate.msPerDay
        let suggested = day + 10 * 3_600_000
        let now = day + 12 * 3_600_000
        XCTAssertEqual(day + 13 * 3_600_000, CheckInSchedule.pickedMs(hour: 13, minute: 0, suggestedMs: suggested, nowMs: now, calendar: calendar))
        XCTAssertEqual(day + CivilDate.msPerDay + 11 * 3_600_000 + 30 * 60_000,
                       CheckInSchedule.pickedMs(hour: 11, minute: 30, suggestedMs: suggested, nowMs: now, calendar: calendar))
    }

    func testAges() {
        XCTAssertEqual("0s", SafetyText.age(seconds: 0))
        XCTAssertEqual("89s", SafetyText.age(seconds: 89))
        XCTAssertEqual("1 min", SafetyText.age(seconds: 90))
        XCTAssertEqual("60 min", SafetyText.age(seconds: 3_600))
    }

    func testEmergencyAndHeartbeatLines() {
        XCTAssertEqual("No active emergency", SafetyText.emergency(.ok))
        XCTAssertEqual("Fall detected", SafetyText.emergency(.fallDetected))
        XCTAssertEqual("Critical sos", SafetyText.emergency(.criticalSos))
        XCTAssertEqual("Manual check in", SafetyText.emergency(.manualCheckIn))
        XCTAssertEqual("Disabled", SafetyText.heartbeat(enabled: false, heartbeats: true, lastHeartbeatMs: 0, nowMs: t0))
        XCTAssertEqual("Location heartbeats off", SafetyText.heartbeat(enabled: true, heartbeats: false, lastHeartbeatMs: 0, nowMs: t0))
        XCTAssertEqual("Waiting for a location fix", SafetyText.heartbeat(enabled: true, heartbeats: true, lastHeartbeatMs: 0, nowMs: t0))
        XCTAssertEqual("Last local heartbeat 42s ago", SafetyText.heartbeat(enabled: true, heartbeats: true, lastHeartbeatMs: t0 - 42_500, nowMs: t0))
        XCTAssertEqual("Last local heartbeat 2 min ago", SafetyText.heartbeat(enabled: true, heartbeats: true, lastHeartbeatMs: t0 - 150_000, nowMs: t0))
        XCTAssertEqual("Last local heartbeat 0s ago", SafetyText.heartbeat(enabled: true, heartbeats: true, lastHeartbeatMs: t0 + 5_000, nowMs: t0))
    }

    func testPressureSummary() {
        XCTAssertEqual("Pressure 1003 hPa · trend after about 2½ hours of readings", SafetyText.pressure(1003.4, change: nil, tendency: .unknown))
        XCTAssertEqual("Pressure 1004 hPa · falling fast, 4.3 hPa in 3 h: the weather may be turning",
                       SafetyText.pressure(1003.5, change: -4.25, tendency: .fallingFast))
        XCTAssertEqual("Pressure 990 hPa · rising 2.0 hPa in 3 h", SafetyText.pressure(990.2, change: 2.0, tendency: .rising))
        XCTAssertEqual("Pressure 990 hPa · steady", SafetyText.pressure(990.2, change: 0.3, tendency: .steady))
    }

    func testLocationTextAsAndroidSharesIt() {
        let text = SafetyText.location(lat: 54.6, lon: -3.13, accuracyM: Double(Float(4.7)), altitudeM: 123.4, imperial: false,
                                       fixTime: "31 Oct 2026, 09:28:12", words: "filled.count.soap")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(6, lines.count, text)
        XCTAssertTrue(lines[0].hasPrefix("OS grid ref: NY "), text)
        XCTAssertEqual("Lat/Lon: 54.60000°N 3.13000°W (±5 m)", lines[1])
        XCTAssertEqual("Altitude: 123 m", lines[2])
        XCTAssertEqual("Fix time: 31 Oct 2026, 09:28:12", lines[3])
        XCTAssertEqual("what3words: ///filled.count.soap", lines[4])
        XCTAssertEqual("https://www.openstreetmap.org/?mlat=54.60000&mlon=-3.13000#map=16/54.60000/-3.13000", lines[5])

        let abroad = SafetyText.location(lat: 48.8584, lon: 2.2945, accuracyM: 12, altitudeM: nil, imperial: true, fixTime: "now", words: nil)
        XCTAssertEqual("Lat/Lon: 48.85840°N 2.29450°E (±39 ft)\nFix time: now\nhttps://www.openstreetmap.org/?mlat=48.85840&mlon=2.29450#map=16/48.85840/2.29450", abroad)
    }

    func testOtherTexts() {
        XCTAssertEqual("TrailMind: I'm OK now. Please ignore my SOS text from 14:05.", SafetyText.allClear(sentTime: "14:05"))
        XCTAssertEqual("No check-in set", SafetyText.checkIn(dueTime: nil, route: "x"))
        XCTAssertEqual("Check-in 17:30 · my walk", SafetyText.checkIn(dueTime: "17:30", route: "my walk"))
    }
}
