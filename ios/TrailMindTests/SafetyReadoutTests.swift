import XCTest
@testable import TrailMind

/// The Safety feature's texts for the compass, telemetry, check-in and fall alarm, the alarm tone and the barometer
/// readings (ui/Pages2.kt CompassPage, ui/SatellitePage.kt, location/CheckIn.kt, frontier/FallAlertActivity.kt and
/// sensor/Barometer.kt).
final class SafetyReadoutTests: XCTestCase {
    private let t0: Int64 = 1_800_000_000_000
    private let keswick = LatLon(54.6, -3.13)

    func testHeadingLine() {
        XCTAssertEqual("Waiting for compass…", SafetyText.heading(trueDeg: nil, declinationDeg: 1.2))
        XCTAssertEqual("True 090° · magnetic 091° · declination -1.2°", SafetyText.heading(trueDeg: 90, declinationDeg: -1.2))
        XCTAssertEqual("True 001° · magnetic 359° · declination 2.0°", SafetyText.heading(trueDeg: 0.6, declinationDeg: 1.96))
    }

    func testDialCentre() {
        XCTAssertEqual("—", SafetyText.dialCentre(nil, unreliable: true).bearing)
        XCTAssertEqual("No compass", SafetyText.dialCentre(nil, unreliable: false).sub)
        XCTAssertEqual("359°", SafetyText.dialCentre(359.4, unreliable: false).bearing)
        XCTAssertEqual("N", SafetyText.dialCentre(359.4, unreliable: false).sub)
        XCTAssertEqual("SW · calibrate", SafetyText.dialCentre(225, unreliable: true).sub)
    }

    func testCompassTargetPrefersTheMapTargetThenTheNextWaypointThenTheRoute() {
        let target = Geo.destination(keswick, bearingDeg: 135, distanceM: 1_234)
        let map = SafetyText.compassTarget(here: keswick, target: target, guide: nil, offRoute: false, imperial: false)
        XCTAssertEqual("Map target: 135° SE · 1.23 km (straight line)", map.text)
        XCTAssertEqual(135, map.bearingDeg!, accuracy: 0.01)

        let ahead = WaypointAhead(waypoint: Waypoint(lat: 54.61, lon: -3.12, name: "Latrigg"), alongRouteM: 900, directM: 640,
                                  bearingDeg: 30.4)
        var fix = RouteFix(segmentIndex: 0, snapped: keswick, offRouteM: 85, alongM: 100, remainingM: 2_000, remainingAscentM: 50,
                           routeBearingDeg: 271, progress: 0.1, nextWaypoint: ahead, atEnd: false)
        XCTAssertEqual("Latrigg: 030° NNE · 640 m direct",
                       SafetyText.compassTarget(here: keswick, target: nil, guide: fix, offRoute: true, imperial: false).text)
        XCTAssertEqual("Map target: 135° SE · 0.77 mi (straight line)",
                       SafetyText.compassTarget(here: keswick, target: target, guide: fix, offRoute: false, imperial: true).text)

        fix.nextWaypoint = nil
        let route = SafetyText.compassTarget(here: keswick, target: nil, guide: fix, offRoute: true, imperial: false)
        XCTAssertEqual("Route heads 271° W here · you are 85 m off route", route.text)
        XCTAssertEqual(271, route.bearingDeg)
        XCTAssertEqual("Route heads 271° W here", SafetyText.compassTarget(here: keswick, target: nil, guide: fix, offRoute: false,
                                                                             imperial: false).text)

        XCTAssertEqual("Long-press the map to set a target, or follow a route.",
                       SafetyText.compassTarget(here: keswick, target: nil, guide: nil, offRoute: false, imperial: false).text)
        let none = SafetyText.compassTarget(here: nil, target: target, guide: fix, offRoute: false, imperial: false)
        XCTAssertEqual("Needs a GPS fix.", none.text)
        XCTAssertNil(none.bearingDeg)
    }

    func testPositionLines() {
        XCTAssertEqual("54.60000°N 3.13000°W · ±5 m · alt 312 m (barometric) · fix 09:28",
                       SafetyText.compassPosition(lat: 54.6, lon: -3.13, accuracyM: 4.6, altitudeM: 311.6, barometric: true,
                                                  fixTime: "09:28", imperial: false))
        XCTAssertEqual("54.60000°N 3.13000°W · ±49 ft · fix 09:28",
                       SafetyText.compassPosition(lat: 54.6, lon: -3.13, accuracyM: 15, altitudeM: nil, barometric: false,
                                                  fixTime: "09:28", imperial: true))
        XCTAssertEqual("54.60000°N 3.13000°W · ±5 m · 312 m (barometric) · 12s ago\nPressure 1003 hPa · steady",
                       SafetyText.fixDetail(lat: 54.6, lon: -3.13, accuracyM: 4.6, altitudeM: 311.6, barometric: true, ageS: 12,
                                            imperial: false, pressure: "Pressure 1003 hPa · steady"))
        XCTAssertEqual("54.60000°N 3.13000°W · ±12 m · 2 min ago",
                       SafetyText.fixDetail(lat: 54.6, lon: -3.13, accuracyM: 12, altitudeM: nil, barometric: false, ageS: 150,
                                            imperial: false, pressure: nil))
    }

    func testGridFiguresAtThreePrecisions() throws {
        let figures = try XCTUnwrap(SafetyText.gridFigures(LatLon(56.796, -5.0035)))
        XCTAssertTrue(figures.ten.hasPrefix("NN "), figures.ten)
        XCTAssertEqual(figures.ten.count, 14)
        XCTAssertEqual(figures.eight.count, 12)
        XCTAssertEqual(figures.six.count, 10)
        let ten = figures.ten.split(separator: " ")
        XCTAssertEqual("NN \(ten[1].prefix(4)) \(ten[2].prefix(4))", figures.eight)
        XCTAssertEqual("NN \(ten[1].prefix(3)) \(ten[2].prefix(3))", figures.six)
        XCTAssertNil(SafetyText.gridFigures(LatLon(48.8584, 2.2945)), "only Great Britain has OS grid references")
    }

    func testDaylightLine() {
        let time: (Int64?) -> String = { ms in ms.map { "\($0 / 3_600_000 % 24):00" } ?? "—" }
        let day = SunTimes(sunriseMs: 7 * 3_600_000, sunsetMs: 17 * 3_600_000, polarDay: false, polarNight: false)
        XCTAssertEqual("Sunrise 7:00 · sunset 17:00 · 2h 05m of daylight left",
                       SafetyText.daylight(day, nowMs: 17 * 3_600_000 - 125 * 60_000, time: time))
        XCTAssertEqual("Sunrise 7:00 · sunset 17:00 · after sunset", SafetyText.daylight(day, nowMs: 18 * 3_600_000, time: time))
        XCTAssertEqual("Sun up all day", SafetyText.daylight(SunTimes(sunriseMs: nil, sunsetMs: nil, polarDay: true, polarNight: false),
                                                             nowMs: 0, time: time))
        XCTAssertEqual("Sun down all day", SafetyText.daylight(SunTimes(sunriseMs: nil, sunsetMs: nil, polarDay: false, polarNight: true),
                                                               nowMs: 0, time: time))
    }

    func testTelemetryLines() {
        let fix = SafetyText.TelemetryFix(provider: "Core Location", ageS: 3, accuracyM: 4.6, verticalAccuracyM: 8.2, altitudeM: 311.6,
                                          speedMps: 1.25, courseDeg: 92.6)
        XCTAssertEqual("""
            Provider: Core Location
            Fix age: 3 s
            Horizontal accuracy: ±5 m
            Vertical accuracy: ±8 m
            Altitude: 312 m
            Speed: 4.5 km/h
            Course: 093°
            Pressure: 1003.3 hPa
            Compass: available
            """, SafetyText.telemetry(fix, pressureHpa: 1003.25, compass: .available, imperial: false))
        XCTAssertEqual("No position fix yet.\nCompass: no recent reading",
                       SafetyText.telemetry(nil, pressureHpa: nil, compass: .noRecentReading, imperial: false))
        let bare = SafetyText.TelemetryFix(provider: "Core Location", ageS: -2, accuracyM: 30, verticalAccuracyM: nil, altitudeM: nil,
                                           speedMps: nil, courseDeg: nil)
        XCTAssertEqual("Provider: Core Location\nFix age: 0 s\nHorizontal accuracy: ±98 ft\nCompass: interference",
                       SafetyText.telemetry(bare, pressureHpa: nil, compass: .interference, imperial: true))
    }

    func testCompassReadingStates() {
        XCTAssertEqual(.interference, SafetyText.CompassReading.of(disturbed: true, headingAtMs: t0, nowMs: t0, unreliable: true))
        XCTAssertEqual(.noRecentReading, SafetyText.CompassReading.of(disturbed: false, headingAtMs: 0, nowMs: t0, unreliable: false))
        XCTAssertEqual(.noRecentReading, SafetyText.CompassReading.of(disturbed: false, headingAtMs: t0 - 2_001, nowMs: t0, unreliable: false))
        XCTAssertEqual(.lowAccuracy, SafetyText.CompassReading.of(disturbed: false, headingAtMs: t0 - 2_000, nowMs: t0, unreliable: true))
        XCTAssertEqual(.available, SafetyText.CompassReading.of(disturbed: false, headingAtMs: t0, nowMs: t0, unreliable: false))
    }

    func testDashboardSummary() {
        XCTAssertNil(SafetyText.summary(alarm: .none, checkInDueMs: 0, nowMs: t0, dueTime: "17:30", fallDetectionOn: false))
        XCTAssertEqual("Check-in due 17:30 · Fall alarm on",
                       SafetyText.summary(alarm: .none, checkInDueMs: t0 + 1, nowMs: t0, dueTime: "17:30", fallDetectionOn: true))
        XCTAssertEqual("Check-in overdue",
                       SafetyText.summary(alarm: .none, checkInDueMs: t0 - 1, nowMs: t0, dueTime: "17:30", fallDetectionOn: false))
        XCTAssertEqual("Fall alarm: are you OK?",
                       SafetyText.summary(alarm: .countdown, checkInDueMs: 0, nowMs: t0, dueTime: "", fallDetectionOn: true))
        XCTAssertEqual("SOS text ready to send · Check-in overdue",
                       SafetyText.summary(alarm: .textReady, checkInDueMs: t0, nowMs: t0, dueTime: "", fallDetectionOn: true))
    }

    func testSosCardTexts() {
        XCTAssertEqual("Set an emergency contact to use this.", SafetyText.sosAutoCaption(contact: "  ", opensText: true))
        XCTAssertTrue(SafetyText.sosAutoCaption(contact: "999", opensText: true).hasPrefix("Your emergency contact is an emergency number."))
        XCTAssertTrue(SafetyText.sosAutoCaption(contact: "07700 900123", opensText: true).hasPrefix("On: "))
        XCTAssertTrue(SafetyText.sosAutoCaption(contact: "07700 900123", opensText: false).hasPrefix("Off: "))
        XCTAssertEqual("Text my location…", SafetyText.textLocationButton(""))
        XCTAssertEqual("Text location to 07700 900123", SafetyText.textLocationButton("07700 900123"))
        XCTAssertTrue(SafetyText.sosIntro("Sam").contains("asks if you're OK for 60 seconds. Then it gets a text to Sam ready"))
        XCTAssertEqual("12 of 160 characters · one plain text", SafetyText.sosLength("SOS at 14:05"))
        XCTAssertEqual("2 of 160 characters", SafetyText.sosLength("€"  + "x"))
        XCTAssertEqual("Frontier active", SafetyText.frontierStatus(enabled: true))
        XCTAssertEqual("Frontier safety is off", SafetyText.frontierStatus(enabled: false))
    }

    func testSosTextStaysOneMessage() {
        let text = SosText.contact(FallAlarmState.noResponse, location: keswick, altitudeM: 312, time: "14:05", batteryPercent: 64)
        XCTAssertLessThanOrEqual(FrontierCompat.length(text), SosText.maxChars)
        XCTAssertTrue(text.hasPrefix("SOS from TrailMind: Possible fall, no response at 14:05."), text)
    }

    func testEmergencyGuidanceCallsPoliceThenMountainRescue() {
        let lines = SafetyText.emergencyGuidance.components(separatedBy: "\n")
        XCTAssertEqual("• Call 999 or 112 and ask for Police, then Mountain Rescue.", lines[0])
        XCTAssertEqual("• Give your grid reference, what happened, number of people and injuries.", lines[1])
        XCTAssertTrue(lines.contains("• Stay put, keep warm, and save battery once help is on the way."))
        // The page links the first 999 and 112 to the phone: both must come in the first line.
        XCTAssertNotNil(lines[0].range(of: "999"))
        XCTAssertNotNil(lines[0].range(of: "112"))
        XCTAssertTrue(SafetyText.satelliteNote.contains("Emergency SOS via satellite"))
        XCTAssertTrue(SafetyText.cannotSendNote.hasSuffix("you tap Send."))
    }

    // MARK: Fall alarm and check-in wording

    func testContactNameFallsBackAsAndroidDoes() {
        XCTAssertEqual("Sam", FallAlarmText.contactName(number: "07700900123", contactNumber: "07700900123", contactName: "Sam"))
        XCTAssertEqual("07700900123", FallAlarmText.contactName(number: "07700900123", contactNumber: "07700900123", contactName: " "))
        XCTAssertEqual("07700900999", FallAlarmText.contactName(number: "07700900999", contactNumber: "07700900123", contactName: "Sam"),
                       "the SOS went to an earlier contact: name the number it went to")
        XCTAssertEqual("your emergency contact", FallAlarmText.contactName(number: "", contactNumber: "", contactName: ""))
    }

    func testAlarmWording() {
        XCTAssertEqual("If you don't answer, TrailMind gets a text to Sam ready for you to send.",
                       FallAlarmText.countdownBody("Sam", opensText: false))
        XCTAssertEqual("If you don't answer, TrailMind opens a text to Sam with your location, ready to send.",
                       FallAlarmText.countdownBody("Sam", opensText: true))
        XCTAssertEqual("I'm OK: tell Sam", FallAlarmText.okButton("Sam", tellContact: true))
        XCTAssertEqual("I'm OK", FallAlarmText.okButton("Sam", tellContact: false))
        XCTAssertEqual("Sent at 14:05 with your location.", FallAlarmText.sentBody("14:05"))
        XCTAssertEqual("Your grid reference: NY 12345 67890", FallAlarmText.gridLine("NY 12345 67890"))
        var state = FallAlarmState()
        _ = state.start(t0)
        XCTAssertEqual("Are you OK?", FallAlarmText.countdownNotification("Sam").title)
        XCTAssertEqual("Possible fall. If you don't answer, TrailMind gets a text to Sam ready for you.",
                       FallAlarmText.countdownNotification("Sam").body)
        _ = state.countdownEnded()
        XCTAssertEqual("No answer to the fall alarm", FallAlarmText.readyNotification(state, "Sam").title)
        XCTAssertEqual("Text Sam your location, or call 999 if you have signal for calls.", FallAlarmText.readyNotification(state, "Sam").body)
    }

    func testCheckInWording() {
        XCTAssertEqual("Check in: are you OK?", CheckInText.title(overdue: false))
        XCTAssertEqual("Overdue check-in: please respond", CheckInText.title(overdue: true))
        XCTAssertEqual("You planned to be back by 17:30. Are you OK?", CheckInText.body(overdue: false, dueTime: "17:30"))
        XCTAssertEqual("Still no check-in since 17:30. Please check in or contact someone.", CheckInText.body(overdue: true, dueTime: "17:30"))
        XCTAssertEqual("Text contact", CheckInText.textAction(contactName: ""))
        XCTAssertEqual("Text Sam", CheckInText.textAction(contactName: "Sam"))
        XCTAssertEqual(["Set for 17:30", "17:30 +30 min", "17:30 +1 hour", "Choose return time"], CheckInText.choices("17:30"))
        XCTAssertEqual("Set check-in for my walk", CheckInText.dialogTitle("my walk"))
    }

    func testLateTextNamesTheRouteAndPosition() {
        let text = TripReadiness.sms(routeName: "Skiddaw", location: keswick, time: "17:45", batteryPercent: 41)
        XCTAssertTrue(text.hasPrefix("I'm running late on Skiddaw. Grid NY "), text)
        XCTAssertTrue(text.hasSuffix("Time 17:45. Battery 41%."), text)
    }

    // MARK: Alarm tone

    func testAlarmToneIsAOneSecondWav() {
        let wav = AlarmTone.wav()
        XCTAssertEqual(44 + AlarmTone.sampleRate * 2, wav.count)
        XCTAssertEqual(Array("RIFF".utf8), Array(wav[0..<4]))
        XCTAssertEqual(Array("WAVE".utf8), Array(wav[8..<12]))
        XCTAssertEqual(Array("data".utf8), Array(wav[36..<40]))
        func u32(_ at: Int) -> Int { Int(wav[at]) | Int(wav[at + 1]) << 8 | Int(wav[at + 2]) << 16 | Int(wav[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(wav[at]) | Int(wav[at + 1]) << 8 }
        XCTAssertEqual(wav.count - 8, u32(4))
        XCTAssertEqual(1, u16(20), "PCM")
        XCTAssertEqual(1, u16(22), "mono")
        XCTAssertEqual(AlarmTone.sampleRate, u32(24))
        XCTAssertEqual(16, u16(34))
        XCTAssertEqual(AlarmTone.sampleRate * 2, u32(40))
    }

    func testAlarmToneBeepsFadeAndStayInRange() {
        XCTAssertEqual(0, AlarmTone.sample(0), accuracy: 1e-12, "each beep fades in from silence")
        let samples = (0..<AlarmTone.sampleRate).map(AlarmTone.sample)
        XCTAssertLessThanOrEqual(samples.map(abs).max()!, AlarmTone.peak)
        XCTAssertGreaterThan(samples.map(abs).max()!, 0.5)
        // Silent between beeps: from 0.18 s to 0.25 s, and so on.
        let gap = Int(0.2 * Double(AlarmTone.sampleRate))
        XCTAssertEqual(0, samples[gap])
        XCTAssertNotEqual(0, samples[Int(0.1 * Double(AlarmTone.sampleRate))])
    }

    func testLongerAlarmRepeatsTheSecond() {
        let one = AlarmTone.wav()
        let three = AlarmTone.wav(seconds: 3)
        XCTAssertEqual(44 + 3 * AlarmTone.sampleRate * 2, three.count)
        let bytesPerSecond = AlarmTone.sampleRate * 2
        XCTAssertEqual(Array(one[44...]), Array(three[(44 + 2 * bytesPerSecond)...]))
        // A notification sound must stay under 30 seconds, or iOS plays its default sound instead.
        XCTAssertLessThan(AlarmTone.wav(seconds: 29).count, 30 * bytesPerSecond + 44)
    }

    // MARK: Barometer

    func testPressureIsSmoothedAsItArrives() {
        let b = BarometerReadings()
        XCTAssertNil(b.summary())
        b.onPressure(1000)
        b.onPressure(1010)
        XCTAssertEqual(1003, b.pressureHpa!, accuracy: 1e-9)
        XCTAssertEqual("Pressure 1003 hPa · trend after about 2½ hours of readings", b.summary())
        b.clear()
        XCTAssertNil(b.pressureHpa)
    }

    func testAltitudeIsAnchoredToGpsOncePerFix() {
        let b = BarometerReadings()
        XCTAssertNil(b.altitudeFor(fixTimeMs: t0, gpsAltitudeM: 300, verticalAccuracyM: 5, horizontalAccuracyM: 5, nowMs: t0))
        let station = Barometry.pressureHpa(300, 1_020)
        b.onPressure(station)
        XCTAssertEqual(300, b.altitudeFor(fixTimeMs: t0, gpsAltitudeM: 300, verticalAccuracyM: 5, horizontalAccuracyM: 5, nowMs: t0)!,
                       accuracy: 1e-6)
        // The same fix reported again doesn't count twice.
        XCTAssertEqual(300, b.altitudeFor(fixTimeMs: t0, gpsAltitudeM: 340, verticalAccuracyM: 5, horizontalAccuracyM: 5, nowMs: t0)!,
                       accuracy: 1e-6)
        // A fix too vague to calibrate with (30 m × 1.5 without vertical accuracy) leaves the anchor alone.
        XCTAssertEqual(300, b.altitudeFor(fixTimeMs: t0 + 1_000, gpsAltitudeM: 340, verticalAccuracyM: nil, horizontalAccuracyM: 30,
                                          nowMs: t0 + 1_000)!, accuracy: 1e-6)
    }

    func testFallingPressureWarnsOfTheWeather() {
        let b = BarometerReadings()
        // Three hours of fixes every 10 seconds at a fixed height while the sea-level pressure falls 5 hPa.
        for i in 0...1_080 {
            let now = t0 + Int64(i) * 10_000
            let hpa = 1_010.0 - 5.0 * Double(i) / 1_080.0
            for _ in 0..<3 { b.onPressure(hpa) }
            _ = b.altitudeFor(fixTimeMs: now, gpsAltitudeM: 0, verticalAccuracyM: 3, horizontalAccuracyM: 3, nowMs: now)
        }
        XCTAssertEqual(.fallingFast, b.tendency())
        XCTAssertEqual(-4.75, b.change3hHpa()!, accuracy: 0.2)
        XCTAssertTrue(b.summary()!.hasPrefix("Pressure 1005 hPa · falling fast, 4."), b.summary()!)
    }
}
