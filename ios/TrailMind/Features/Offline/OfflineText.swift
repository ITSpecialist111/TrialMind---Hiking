import Foundation

/// Times in TrailMind's wording, on the phone's clock (ui/DaylightText.kt).
enum OfflineText {
    /// "18:00" (or "6:00 PM"), as the phone shows times.
    static func clock(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// "at 18:00", "tomorrow at 08:59" or "on 28/09/2026 at 10:01", as seen at `reference` (now by default).
    static func atTime(_ ms: Int64, from reference: Int64? = nil) -> String {
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(reference ?? nowMs()) / 1000))
        let day = calendar.startOfDay(for: date)
        let prefix: String
        if day == today {
            prefix = ""
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), day == tomorrow {
            prefix = "tomorrow "
        } else {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .none
            prefix = "on " + f.string(from: date) + " "
        }
        return prefix + "at " + clock(ms)
    }

    /// The date and time a pack's detail lasts until, as Android's short date-time format.
    static func dateTime(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// "Area 31 Oct 2026", the default name of a downloaded area.
    static func areaFallbackName() -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return "Area " + f.string(from: Date())
    }
}
