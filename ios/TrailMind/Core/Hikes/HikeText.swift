import Foundation

/// The phone's clock and date formats, passed in so the wording below can be checked on Linux with fixed formats.
struct HikeClock {
    /// A time of day in the phone's format ("17:30"; Android's DateFormat.getTimeFormat).
    let time: (Int64) -> String
    /// A short date in the phone's format ("31/10/2026"; Android's DateFormat.getDateFormat).
    let date: (Int64) -> String
    let zone: TimeZone

    init(zone: TimeZone = .current, time: @escaping (Int64) -> String, date: @escaping (Int64) -> String) {
        self.zone = zone
        self.time = time
        self.date = date
    }
}

/// What the hike recorder and route guidance say, word for word as on Android (MapScreen.updateNav, updateTarget,
/// NavigationController's alerts, TrackingService's notifications and DaylightText).
enum HikeText {
    // MARK: Times

    /// "17:30", "tomorrow 08:59" or "02/11/2026 10:01" (DaylightText.finishTime).
    static func finishTime(_ ms: Int64, nowMs: Int64, clock: HikeClock) -> String {
        let day = CivilDate.localEpochDay(ms, clock.zone)
        let today = CivilDate.localEpochDay(nowMs, clock.zone)
        let prefix = day == today ? "" : day == today + 1 ? "tomorrow " : clock.date(ms) + " "
        return prefix + clock.time(ms)
    }

    /// When to set off to finish before the sunset margin (DaylightText.startByText).
    static func startBy(_ points: [TrackPoint], pace: PaceSettings, marginMinutes: Int, forMs: Int64, clock: HikeClock) -> String {
        if points.count < 2 { return "No route timing available." }
        let sun = Sun.times(epochDay: CivilDate.localEpochDay(forMs, clock.zone), points[0].latLon())
        let estimate = Daylight.estimate(nowMs: forMs, remaining: points, walked: [], movingMinutes: nil, pace: pace, sun: sun,
                                         marginMinutes: marginMinutes, zone: clock.zone)
        if estimate.darkNow == true {
            return "It's dark now. " +
                (estimate.nextSunriseMs.map { "Sunrise \(finishTime($0, nowMs: forMs, clock: clock))." } ?? "No sunrise time available.")
        }
        guard let sunset = sun.sunsetMs else {
            return sun.polarDay ? "No sunset today at this location." : "Daylight times unavailable here."
        }
        guard let startBy = estimate.startByMs else { return "No start time today: route is too long to finish before sunset." }
        return "Start by \(clock.time(startBy)) to finish before sunset (\(clock.time(sunset))) with \(marginMinutes) min to spare" +
            (startBy < forMs ? " (start-by time has passed)." : ".")
    }

    // MARK: Guidance card

    static let guidanceStatLabels = ["To go", "Time", "Climb", "Done"]

    /// Before the first fix on the route.
    static func waiting(totalM: Double, planningMinutes: Double, imperial: Bool) -> String {
        "\(Units.distance(totalM, imperial: imperial)) · planning time \(Units.minutes(planningMinutes)) · waiting for GPS"
    }

    /// Distance, time and climb to go, and the share done, under `guidanceStatLabels`.
    static func guidanceStats(_ fix: RouteFix, remainingMinutes: Double?, imperial: Bool) -> [String] {
        [Units.distance(fix.remainingM, imperial: imperial), remainingMinutes.map { Units.minutes($0) } ?? "—",
         "↑" + Units.elevation(fix.remainingAscentM, imperial: imperial), "\(kTruncate(fix.progress * 100))%"]
    }

    /// Off route (with the way back from `here`) or at the end, else nil.
    static func guidanceStatus(_ fix: RouteFix, offRoute: Bool, here: LatLon?, imperial: Bool) -> String? {
        if offRoute {
            let back = here.map { Geo.bearingDeg($0, fix.snapped) }
            return "Off route by \(Units.distance(fix.offRouteM, imperial: imperial))" +
                (back.map { " – route is \(Units.bearing($0)) \(Geo.cardinal($0))" } ?? "")
        }
        if fix.atEnd { return "You have reached the end of the route." }
        return nil
    }

    static func nextWaypoint(_ fix: RouteFix, imperial: Bool) -> String? {
        fix.nextWaypoint.map { w in
            "Next: \(w.waypoint.name) in \(Units.distance(w.alongRouteM, imperial: imperial)) (\(Units.bearing(w.bearingDeg)))"
        }
    }

    /// The daylight line once the walk is under way (before that the card shows `startBy`).
    static func daylightLine(_ daylight: DaylightEstimate?, sun: SunTimes?, marginMinutes: Int, nowMs: Int64, clock: HikeClock) -> String? {
        guard let daylight else { return nil }
        if daylight.darkNow == true {
            return "It's dark now. " +
                (daylight.nextSunriseMs.map { "Sunrise \(finishTime($0, nowMs: nowMs, clock: clock))" } ?? "No sunrise time available.")
        }
        guard let sunset = sun?.sunsetMs else {
            return daylight.darkNow == false ? "No sunset today at this location." : "Daylight times unavailable here."
        }
        let finish = finishTime(daylight.finishMs, nowMs: nowMs, clock: clock)
        if daylight.afterSafeSunset == true && daylight.finishMs > sunset {
            return "Finish ≈ \(finish), after sunset (\(clock.time(sunset)))"
        }
        if daylight.afterSafeSunset == true {
            return "Finish ≈ \(finish), inside \(marginMinutes) min sunset margin (\(clock.time(sunset)))"
        }
        return "Finish ≈ \(finish) · sunset \(clock.time(sunset))"
    }

    /// The "Daylight check" explanation behind the daylight line.
    static func daylightCheck(_ daylight: DaylightEstimate, sunsetMs: Int64, civilDuskMs: Int64?, marginMinutes: Int, nowMs: Int64,
                              clock: HikeClock) -> String {
        let back = daylight.walkBackMinutes.map { "Going back to the start now takes about \(Units.minutes($0)).\n" } ?? ""
        let turn = daylight.turnBackByMs.map {
            "Turn back by \(finishTime($0, nowMs: nowMs, clock: clock)) to be down before sunset with \(marginMinutes) min to spare.\n"
        } ?? ""
        let dusk = civilDuskMs.map { "Civil dusk (dark by) \(finishTime($0, nowMs: nowMs, clock: clock)).\n" } ?? ""
        let left: String
        if daylight.darkNow == true {
            left = "It's dark now"
        } else if let ms = daylight.daylightLeftMs, ms > 0 {
            left = "\(Units.duration(ms)) of daylight left"
        } else {
            left = "Sunset has passed"
        }
        return "Estimated finish \(finishTime(daylight.finishMs, nowMs: nowMs, clock: clock)). Sunset \(clock.time(sunsetMs)); \(left).\n" +
            back + turn + dusk + "Estimate uses route climb, your pace and conditions; allow extra for breaks and poor weather."
    }

    // MARK: Go to

    /// The target's grid reference, or its coordinates outside Great Britain.
    static func place(_ p: LatLon) -> String { OsGrid.fromWgs84(p)?.format(8) ?? Units.latLon(p.lat, p.lon) }

    static func goToDetail(here: LatLon?, target: LatLon, imperial: Bool) -> String {
        guard let here else { return "Waiting for GPS to give bearing and distance" }
        let b = Geo.bearingDeg(here, target)
        return "\(Units.distance(Geo.distanceM(here, target), imperial: imperial)) · \(Units.bearing(b)) \(Geo.cardinal(b)) (straight line, not a path)"
    }

    // MARK: Alerts

    static let offRouteTitle = "Off route"
    static let daylightTitle = "Daylight warning"
    static let darkByFinishTitle = "Dark by finish"
    static let darkByFinishText = "Estimated finish is after civil dusk. Plan a safe way down."
    static let weatherTitle = "Weather warning"
    static let autoPauseTitle = "Hike paused: looks like you're in a vehicle"
    static let autoPauseText = "You were moving faster than walking pace, so TrailMind paused your hike and switched the GPS off. " +
        "Tap Resume when you are back on foot, or Finish to save it."

    static func offRouteAlert(offRouteM: Double, backBearingDeg back: Double, imperial: Bool) -> String {
        "\(Units.distance(offRouteM, imperial: imperial)) from the route. Nearest route point is \(Units.bearing(back)) (\(Geo.cardinal(back)))."
    }

    static func daylightWarning(_ forecast: DaylightEstimate, finishDayOffset: Int64, marginMinutes: Int, clock: HikeClock) -> String {
        if forecast.darkNow == true {
            return "It's dark now. " + (forecast.nextSunriseMs.map { "Sunrise \(clock.time($0))." } ?? "No sunrise time available.")
        }
        let day = finishDayOffset == 1 ? "tomorrow " : finishDayOffset > 1 ? clock.date(forecast.finishMs) + " " : ""
        return "Estimated finish \(day)\(clock.time(forecast.finishMs)) is after the sunset safety margin (\(marginMinutes) min)."
    }

    static func weatherWarning(changeHpa: Double) -> String {
        fmt("Air pressure has fallen %.1f hPa in 3 hours, so the weather may be turning. ", -changeHpa) +
            "Check the forecast and your way off the hill."
    }

    // MARK: Recording

    /// A new hike's name: the one given, else the trip group's with the date, else "Hike" and the date.
    static func hikeTitle(name: String?, groupName: String?, stamp: String) -> String {
        if let name, !name.isBlank { return name }
        if let groupName { return "\(groupName) · \(stamp)" }
        return "Hike \(stamp)"
    }

    /// Average speed over the active time, or "—" until there is enough to go on.
    static func averagePace(distanceM: Double, activeMs: Int64, imperial: Bool) -> String {
        if activeMs < 60_000 || distanceM < 50 { return "—" }
        return Units.speedKmh(distanceM / (Double(activeMs) / 1000.0), imperial: imperial)
    }
}
