import Foundation

/// The Safety feature's wording, kept identical to Android's so both apps say the same thing.
enum SafetyText {
    /// A fix or heartbeat age: seconds under 90 s ("12s"), then whole minutes ("3 min").
    static func age(seconds: Int64) -> String { seconds < 90 ? "\(seconds)s" : "\(seconds / 60) min" }

    /// The Kotlin name of an emergency status ("FALL_DETECTED").
    static func kotlinName(_ status: EmergencyStatus) -> String {
        switch status {
        case .ok: return "OK"
        case .manualCheckIn: return "MANUAL_CHECK_IN"
        case .delayed: return "DELAYED"
        case .injuredStationary: return "INJURED_STATIONARY"
        case .injuredMoving: return "INJURED_MOVING"
        case .fallDetected: return "FALL_DETECTED"
        case .criticalSos: return "CRITICAL_SOS"
        }
    }

    /// Frontier's emergency line (FrontierCoordinator.emergencyText): "No active emergency" or "Fall detected".
    static func emergency(_ status: EmergencyStatus) -> String {
        if status == .ok { return noEmergency }
        let words = kotlinName(status).replacingOccurrences(of: "_", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static let noEmergency = "No active emergency"

    /// Frontier's heartbeat line (FrontierCoordinator.heartbeatText).
    static func heartbeat(enabled: Bool, heartbeats: Bool, lastHeartbeatMs: Int64, nowMs: Int64) -> String {
        if !enabled { return "Disabled" }
        if !heartbeats { return "Location heartbeats off" }
        if lastHeartbeatMs == 0 { return "Waiting for a location fix" }
        return "Last local heartbeat " + age(seconds: max(nowMs - lastHeartbeatMs, 0) / 1_000) + " ago"
    }

    /// "Pressure 1003 hPa · steady" (sensor/Barometer.summary).
    static func pressure(_ pressureHpa: Double, change: Double?, tendency: PressureTrend.Tendency) -> String {
        let hpa = fmt("%.1f hPa", abs(change ?? 0.0))
        let trend: String
        switch tendency {
        case .unknown: trend = "trend after about 2½ hours of readings"
        case .steady: trend = "steady"
        case .rising: trend = "rising \(hpa) in 3 h"
        case .falling: trend = "falling \(hpa) in 3 h"
        case .fallingFast: trend = "falling fast, \(hpa) in 3 h: the weather may be turning"
        }
        return "Pressure \(kRound(pressureHpa)) hPa · " + trend
    }

    /// The location the Safety page copies, shares and texts (SafetyPage.locationText). `fixTime` is the fix's date and
    /// time in the phone's format; `words` a what3words address still valid for this fix.
    static func location(lat: Double, lon: Double, accuracyM: Double, altitudeM: Double?, imperial: Bool, fixTime: String,
                         words: String?) -> String {
        var text = ""
        if let grid = OsGrid.fromWgs84(LatLon(lat, lon))?.format(10) { text += "OS grid ref: " + grid + "\n" }
        text += "Lat/Lon: " + Units.latLon(lat, lon) + " (±" + Units.distance(accuracyM, imperial: imperial) + ")\n"
        if let altitudeM { text += "Altitude: " + Units.elevation(altitudeM, imperial: imperial) + "\n" }
        text += "Fix time: " + fixTime + "\n"
        if let words { text += "what3words: ///" + words + "\n" }
        text += fmt("https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f#map=16/%.5f/%.5f", lat, lon, lat, lon)
        return text
    }

    /// The text when there is no fix to send.
    static let noFixHelp = "I need help – no GPS fix available."

    /// The all-clear for everyone the SOS text went to (FallAlert.allClear).
    static func allClear(sentTime: String) -> String { "TrailMind: I'm OK now. Please ignore my SOS text from \(sentTime)." }

    /// The Safety page's check-in line.
    static func checkIn(dueTime: String?, route: String) -> String {
        guard let dueTime else { return "No check-in set" }
        return "Check-in \(dueTime) · \(route)"
    }

    /// The Safety page's line under the grid reference (SafetyPage.update): position, accuracy, height, fix age and the
    /// barometer's summary on a second line.
    static func fixDetail(lat: Double, lon: Double, accuracyM: Double, altitudeM: Double?, barometric: Bool, ageS: Int64,
                          imperial: Bool, pressure: String?) -> String {
        var text = Units.latLon(lat, lon) + " · ±" + Units.distance(accuracyM, imperial: imperial)
        if let altitudeM {
            text += " · " + Units.elevation(altitudeM, imperial: imperial)
            if barometric { text += " (barometric)" }
        }
        text += " · " + age(seconds: ageS) + " ago"
        if let pressure { text += "\n" + pressure }
        return text
    }

    /// The grid reference at 6, 8 and 10 figures (100 m, 10 m and 1 m squares), for reading out at the precision asked for.
    static func gridFigures(_ at: LatLon) -> (six: String, eight: String, ten: String)? {
        guard let ref = OsGrid.fromWgs84(at), let six = ref.format(6), let eight = ref.format(8), let ten = ref.format(10) else {
            return nil
        }
        return (six, eight, ten)
    }

    // MARK: Compass (ui/Pages2.kt CompassPage)

    /// "True 123° · magnetic 121° · declination 1.9°" (CompassPage.updateHeading).
    static func heading(trueDeg: Double?, declinationDeg: Double) -> String {
        guard let trueDeg else { return "Waiting for compass…" }
        return "True " + Units.bearing(trueDeg) + " · magnetic " + Units.bearing(Geo.normalizeDeg(trueDeg - declinationDeg)) +
            " · declination " + fmt("%.1f", declinationDeg) + "°"
    }

    /// The dial's centre: the bearing, then the cardinal point (CompassView).
    static func dialCentre(_ headingDeg: Double?, unreliable: Bool) -> (bearing: String, sub: String) {
        guard let headingDeg else { return ("—", "No compass") }
        return (Units.bearing(headingDeg), Geo.cardinal(headingDeg) + (unreliable ? " · calibrate" : ""))
    }

    /// What the compass's "Bearing to" card says, and the bearing its dial marks: the map target, else the next
    /// waypoint of the followed route, else the way the route heads here.
    static func compassTarget(here: LatLon?, target: LatLon?, guide: RouteFix?, offRoute: Bool,
                              imperial: Bool) -> (text: String, bearingDeg: Double?) {
        guard let here else { return ("Needs a GPS fix.", nil) }
        if let target {
            let b = Geo.bearingDeg(here, target)
            return ("Map target: " + Units.bearing(b) + " " + Geo.cardinal(b) + " · " +
                    Units.distance(Geo.distanceM(here, target), imperial: imperial) + " (straight line)", b)
        }
        if let next = guide?.nextWaypoint {
            return (next.waypoint.name + ": " + Units.bearing(next.bearingDeg) + " " + Geo.cardinal(next.bearingDeg) + " · " +
                    Units.distance(next.directM, imperial: imperial) + " direct", next.bearingDeg)
        }
        if let fx = guide {
            return ("Route heads " + Units.bearing(fx.routeBearingDeg) + " " + Geo.cardinal(fx.routeBearingDeg) + " here" +
                    (offRoute ? " · you are " + Units.distance(fx.offRouteM, imperial: imperial) + " off route" : ""),
                    fx.routeBearingDeg)
        }
        return ("Long-press the map to set a target, or follow a route.", nil)
    }

    /// The compass's "Your position" caption; `fixTime` is the fix's clock time.
    static func compassPosition(lat: Double, lon: Double, accuracyM: Double, altitudeM: Double?, barometric: Bool,
                                fixTime: String, imperial: Bool) -> String {
        var text = Units.latLon(lat, lon) + " · ±" + Units.distance(accuracyM, imperial: imperial)
        if let altitudeM {
            text += " · alt " + Units.elevation(altitudeM, imperial: imperial)
            if barometric { text += " (barometric)" }
        }
        return text + " · fix " + fixTime
    }

    /// The compass's daylight line; `time` writes a clock time, "—" for none.
    static func daylight(_ sun: SunTimes, nowMs: Int64, time: (Int64?) -> String) -> String {
        if sun.polarDay { return "Sun up all day" }
        if sun.polarNight { return "Sun down all day" }
        var text = "Sunrise " + time(sun.sunriseMs) + " · sunset " + time(sun.sunsetMs)
        if let sunset = sun.sunsetMs {
            let left = sunset - nowMs
            text += left > 0 ? " · " + Units.duration(left) + " of daylight left" : " · after sunset"
        }
        return text
    }

    // MARK: Satellites & telemetry (ui/SatellitePage.kt)

    /// How the compass is doing, as the telemetry page reports it.
    enum CompassReading: String {
        case interference, noRecentReading = "no recent reading", lowAccuracy = "low accuracy", available

        static func of(disturbed: Bool, headingAtMs: Int64, nowMs: Int64, unreliable: Bool) -> CompassReading {
            if disturbed { return .interference }
            if headingAtMs <= 0 || nowMs - headingAtMs > 2_000 { return .noRecentReading }
            return unreliable ? .lowAccuracy : .available
        }
    }

    /// One position fix as the telemetry page lists it.
    struct TelemetryFix: Hashable {
        var provider: String
        var ageS: Int64
        var accuracyM: Double
        var verticalAccuracyM: Double?
        var altitudeM: Double?
        var speedMps: Double?
        var courseDeg: Double?
    }

    /// The telemetry lines (SatellitePage.update), without the satellite counts iOS doesn't give apps.
    static func telemetry(_ fix: TelemetryFix?, pressureHpa: Double?, compass: CompassReading, imperial: Bool) -> String {
        var text: String
        if let fix {
            text = "Provider: " + fix.provider
            text += "\nFix age: \(max(fix.ageS, 0)) s"
            text += "\nHorizontal accuracy: ±" + Units.distance(fix.accuracyM, imperial: imperial)
            if let v = fix.verticalAccuracyM { text += "\nVertical accuracy: ±" + Units.elevation(v, imperial: imperial) }
            if let a = fix.altitudeM { text += "\nAltitude: " + Units.elevation(a, imperial: imperial) }
            if let s = fix.speedMps { text += "\nSpeed: " + Units.speedKmh(s, imperial: imperial) }
            if let c = fix.courseDeg { text += "\nCourse: " + Units.bearing(c) }
        } else {
            text = "No position fix yet."
        }
        if let pressureHpa { text += fmt("\nPressure: %.1f hPa", pressureHpa) }
        return text + "\nCompass: " + compass.rawValue
    }

    // MARK: Dashboard

    /// The safety line for the dashboard (FeatureHooks.safetySummary), or nil when there is nothing to say.
    static func summary(alarm: FallAlarmStage, checkInDueMs: Int64, nowMs: Int64, dueTime: String,
                        fallDetectionOn: Bool) -> String? {
        var parts: [String] = []
        switch alarm {
        case .countdown: parts.append("Fall alarm: are you OK?")
        case .textReady, .sending: parts.append("SOS text ready to send")
        case .sent: parts.append("SOS text sent")
        case .none: break
        }
        if checkInDueMs > nowMs { parts.append("Check-in due " + dueTime) } else if checkInDueMs > 0 { parts.append("Check-in overdue") }
        if fallDetectionOn && alarm == .none { parts.append("Fall alarm on") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: SOS card (SafetyPage.sosCard)

    static func sosIntro(_ name: String) -> String {
        "After a possible fall TrailMind sounds an alarm and asks if you're OK for \(FallAlarmState.countdownMs / 1000) seconds. " +
            "Then it gets a text to \(name) ready with your grid reference, a map link and your battery. One plain text, so it " +
            "can go wherever a text can, including by satellite where your network carries texts that way."
    }

    /// The caption under "Open the SOS text straight away".
    static func sosAutoCaption(contact: String, opensText: Bool) -> String {
        if KotlinText.isBlank(contact) { return "Set an emergency contact to use this." }
        if SosText.isEmergencyNumber(contact) {
            return "Your emergency contact is an emergency number. TrailMind never opens a text to it by itself: use Text 999 below."
        }
        return opensText
            ? "On: if you don't answer the alarm, TrailMind opens the SOS text in Messages at once. iOS lets no app send a text by itself, so it still needs a tap on Send."
            : "Off: TrailMind gets the text ready and you tap Send in Messages."
    }

    /// "Text location to 07700 900123" or, without a contact, "Text my location…".
    static func textLocationButton(_ contact: String) -> String {
        KotlinText.isBlank(contact) ? "Text my location…" : "Text location to \(contact)"
    }

    /// The SOS preview's length line: one plain SMS holds 160 characters.
    static func sosLength(_ text: String) -> String {
        "\(FrontierCompat.length(text)) of \(SosText.maxChars) characters" + (SosText.isGsm7(text) ? " · one plain text" : "")
    }

    // MARK: Frontier card (FrontierCoordinator.statusText)

    static func frontierStatus(enabled: Bool) -> String { enabled ? "Frontier active" : "Frontier safety is off" }

    /// What iPhone can't do that Android's Frontier does with satellite links, and what it does instead.
    static let satelliteNote = "Satellite data links and watching for satellite networks such as O2 Satellite work only on " +
        "Android: iOS doesn't let apps see or use a satellite connection. iPhone 14 and later have Emergency SOS via satellite " +
        "built in, including in the UK: with no signal, call 999 and follow the prompts."

    /// Said wherever TrailMind gets a text ready.
    static let cannotSendNote = "iPhone lets no app send a text by itself: Messages opens with the text ready, and you tap Send."

    // MARK: Emergency guidance (SafetyPage)

    /// "In an emergency (UK)". The page makes the first 999 and 112 into links that call them.
    static let emergencyGuidance =
        "• Call 999 or 112 and ask for Police, then Mountain Rescue.\n" +
        "• Give your grid reference, what happened, number of people and injuries.\n" +
        "• No signal for calls? Register in advance for emergencySMS by texting 'register' to 999.\n" +
        "• No signal at all? iPhone 14 or later can reach 999 by satellite: call 999 and follow the prompts for Emergency SOS via satellite.\n" +
        "• Stay put, keep warm, and save battery once help is on the way.\n" +
        "iPhone also sends your location to UK 999 automatically when you call (Emergency Location Service), where supported."
}
