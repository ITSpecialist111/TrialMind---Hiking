import Foundation

/// The route pages' figures and wording that do not depend on the phone (Pages.kt RoutesPage/RouteDetailPage and
/// DaylightText.kt), kept here so they can be checked against the Android app's.
enum RouteText {
    /// Quick Naismith (with the user's pace) from stored totals; the detail page uses the full profile.
    static func naismithQuickMinutes(distanceM: Double, ascentM: Double, pace: PaceSettings) -> Double {
        (distanceM / 1000.0 / pace.flatSpeedKmh * 60.0 + ascentM / 10.0) * pace.conditionsFactor
    }

    /// The route list's second line: "12.4 km · ↑640 m · max 950 m · ~4h 10m", each figure kept on one line.
    static func listSubtitle(distanceM: Double, ascentM: Double, maxEleM: Double?, pace: PaceSettings, imperial: Bool) -> String {
        "\(nb(Units.distance(distanceM, imperial: imperial))) · \(nb("↑" + Units.elevation(ascentM, imperial: imperial)))" +
            (maxEleM.map { " · \(nb("max " + Units.elevation($0, imperial: imperial)))" } ?? "") +
            " · \(nb("~" + Units.minutes(naismithQuickMinutes(distanceM: distanceM, ascentM: ascentM, pace: pace))))"
    }

    /// Non-breaking spaces, so a figure never wraps in the middle.
    static func nb(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }

    /// The planning-time caption under the route statistics.
    static func planningCaption(_ estimate: HikeEstimate, flatSpeedKmh: Double, conditionsFactor: Double, imperial: Bool) -> String {
        "Planning time \(Units.minutes(estimate.planningMinutes)) (slower of Naismith+Langmuir and Tobler at " +
            "\(Units.speedKmh(flatSpeedKmh / 3.6, imperial: imperial)), ×\(javaDouble(conditionsFactor)) for conditions). Excludes breaks."
    }

    /// Kotlin's `"$double"`.
    static func javaDouble(_ d: Double) -> String { RoutesJSON.javaDoubleString(d) }

    /// When to start to be down before sunset with the margin to spare (DaylightText.startByText). `clock` and
    /// `finish` format times as the phone shows them ("17:45", "tomorrow 07:12").
    static func startBy(_ points: [TrackPoint], pace: PaceSettings, marginMinutes: Int, forMs: Int64, zone: TimeZone = .current,
                        clock: (Int64) -> String, finish: (Int64) -> String) -> String {
        if points.count < 2 { return "No route timing available." }
        let sun = Sun.times(epochDay: CivilDate.localEpochDay(forMs, zone), points[0].latLon())
        let estimate = Daylight.estimate(nowMs: forMs, remaining: points, walked: [], movingMinutes: nil, pace: pace, sun: sun,
                                         marginMinutes: marginMinutes, zone: zone)
        if estimate.darkNow == true {
            return "It's dark now. " + (estimate.nextSunriseMs.map { "Sunrise \(finish($0))." } ?? "No sunrise time available.")
        }
        guard let sunset = sun.sunsetMs else {
            return sun.polarDay ? "No sunset today at this location." : "Daylight times unavailable here."
        }
        guard let startBy = estimate.startByMs else { return "No start time today: route is too long to finish before sunset." }
        return "Start by \(clock(startBy)) to finish before sunset (\(clock(sunset))) with \(marginMinutes) min to spare" +
            (startBy < forMs ? " (start-by time has passed)." : ".")
    }

    /// The daylight check passes when there is a start-by time still to come.
    static func daylightReady(_ text: String) -> Bool { text.hasPrefix("Start by") && !text.contains("has passed") }

    /// Battery to set out with for a walk of this length: at least 30%.
    static func batteryThreshold(planningMinutes: Double) -> Int { max(30, kTruncate(20 + planningMinutes / 6)) }

    static func batteryDetail(level: Int, charging: Bool, threshold: Int) -> String {
        level < 0 ? "Battery level unavailable" : "\(level)%\(charging ? ", charging" : ""); aim for at least \(threshold)% for this walk"
    }

    /// The weather check: the saved forecast at the route's high point, at the time you would get there.
    static func weatherCheck(high: HighPoint?, forecast: PointForecast?, nowMs: Int64, imperial: Bool) -> (detail: String, ready: Bool) {
        let fresh = forecast.map { nowMs - $0.fetchedMs >= 0 && nowMs - $0.fetchedMs < RouteWeather.freshMs } ?? false
        let hour = high.flatMap { h in forecast?.at(nowMs + kTruncateL(h.minutesFromStart * 1.2 * 60_000)) }
        let warnings = hour.flatMap { h in high.map { MountainWeather.warnings(h, eleM: $0.eleM, imperial: imperial) } } ?? []
        let detail: String
        if high == nil {
            detail = "No high point forecast; check conditions yourself"
        } else if forecast == nil {
            detail = "No forecast saved"
        } else if !fresh {
            detail = "Saved forecast is over 6 hours old"
        } else if hour == nil {
            detail = "Forecast does not cover the planned high point time"
        } else if !warnings.isEmpty {
            detail = warnings.joined(separator: "; ")
        } else {
            detail = "Saved forecast is fresh"
        }
        return (detail, fresh && hour != nil && warnings.isEmpty)
    }

    /// The offline-map check for the base map: `coverage` is the percentage of the route the saved packs cover (nil
    /// while counting), `untilMs` when OS Explorer detail pre-loaded with them expires.
    static func mapCheck(source: TileSource, needsSignal: Bool, coverage: Int?, untilMs: Int64?, nowMs: Int64,
                         dateTime: (Int64) -> String) -> (detail: String, ready: Bool) {
        let explorerExpired = source.id == TileSources.osLeisure && (untilMs.map { $0 <= nowMs } ?? false)
        let current = explorerExpired ? 0 : coverage
        let detail: String
        if needsSignal {
            detail = "\(source.name) needs signal"
        } else {
            switch current {
            case nil: detail = "Checking saved tiles…"
            case 100?:
                if source.id == TileSources.osLeisure, let until = untilMs, until > nowMs {
                    detail = "OS detail covered until \(dateTime(until))"
                } else {
                    detail = "Covered at pack detail"
                }
            case 0?: detail = explorerExpired ? "OS detail expired; reload for today's walk" : "Not covered"
            case let percent?: detail = "Partly covered (\(percent)%)"
            }
        }
        return (detail, !needsSignal && current == 100)
    }

    /// The check-in line: when it is due, whether there is a contact, and whether notifications can reach you.
    static func checkInDetail(dueMs: Int64, nowMs: Int64, contact: Bool, alerts: Bool, clock: (Int64) -> String) -> (detail: String, ready: Bool) {
        let when: String
        if dueMs > nowMs { when = "Check-in \(clock(dueMs))" } else if dueMs > 0 { when = "Check-in overdue" } else { when = "No check-in set" }
        let detail = "\(when) · \(contact ? "contact saved" : "contact missing")\(alerts ? "" : " · notifications off")"
        return (detail, dueMs > nowMs && contact && alerts)
    }

    static func locationDetail(location: Bool, alerts: Bool) -> String {
        if location && alerts { return "Location and notifications ready" }
        return "\(location ? "Location ready" : "Location permission or services off"); \(alerts ? "alerts allowed" : "allow notifications")"
    }

    /// The OS Maps API British National Grid tile holding a grid position at `z` (core `BngTiles` column and row).
    static func bngTile(_ grid: OsGridRef, _ z: Int) -> TileKey {
        let span = 256 * (896.0 / Double(1 << z))
        return TileKey(z, kTruncate(floor((grid.easting - -238_375.0) / span)), kTruncate(floor((1_376_256.0 - grid.northing) / span)))
    }
}
