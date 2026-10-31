import Foundation

/// The daylight wording Beacon shows (ui/DaylightText.kt): clock times in the phone's own 12- or 24-hour style.
enum BeaconDaylight {
    static func clockTime(_ ms: Int64) -> String { timeFormatter.string(from: date(ms)) }

    /// "17:30", "tomorrow 06:41" or "02/11/2026 06:43".
    static func finishTime(_ ms: Int64) -> String {
        let calendar = Calendar.current
        let day = date(ms)
        let prefix: String
        if calendar.isDateInToday(day) {
            prefix = ""
        } else if calendar.isDateInTomorrow(day) {
            prefix = "tomorrow "
        } else {
            prefix = dateFormatter.string(from: day) + " "
        }
        return prefix + clockTime(ms)
    }

    /// When to set off to be down before sunset with the user's margin, for a walk starting at `forMs`.
    static func startByText(_ points: [TrackPoint], pace: PaceSettings, marginMinutes: Int, forMs: Int64) -> String {
        guard points.count >= 2 else { return "No route timing available." }
        let sun = Sun.times(epochDay: CivilDate.localEpochDay(forMs, .current), points[0].latLon())
        let estimate = Daylight.estimate(nowMs: forMs, remaining: points, walked: [], movingMinutes: nil, pace: pace, sun: sun,
                                         marginMinutes: max(marginMinutes, 0))
        if estimate.darkNow == true {
            return "It's dark now. " + (estimate.nextSunriseMs.map { "Sunrise \(finishTime($0))." } ?? "No sunrise time available.")
        }
        guard let sunset = sun.sunsetMs else {
            return sun.polarDay ? "No sunset today at this location." : "Daylight times unavailable here."
        }
        guard let startBy = estimate.startByMs else { return "No start time today: route is too long to finish before sunset." }
        return "Start by \(clockTime(startBy)) to finish before sunset (\(clockTime(sunset))) with \(marginMinutes) min to spare" +
            (startBy < forMs ? " (start-by time has passed)." : ".")
    }

    /// The planned start as Android shows it on its chip: medium date, short time.
    static func plannedStart(_ ms: Int64) -> String { dateTimeFormatter.string(from: date(ms)) }

    /// The next quarter of an hour from now.
    static func nextQuarterHour(_ now: Int64 = nowMs()) -> Int64 {
        let q: Int64 = 15 * 60_000
        return (now / q + 1) * q
    }

    /// Tomorrow at `hour`:00 on the phone's clock.
    static func tomorrowAt(_ hour: Int) -> Int64 {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let at = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return Int64((at.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
