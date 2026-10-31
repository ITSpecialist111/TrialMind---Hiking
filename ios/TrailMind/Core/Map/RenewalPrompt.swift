import Foundation

/// When to ask whether to renew 24-hour Premium detail: 2 hours before it expires, moved to 20:00 the evening before rather than overnight.
enum RenewalPrompt {
    static let leadMs: Int64 = 2 * 3_600_000
    // Local times of day, in milliseconds after midnight.
    private static let quietStart: Int64 = 21 * 3_600_000
    private static let quietEnd: Int64 = 7 * 3_600_000
    private static let evening: Int64 = 20 * 3_600_000
    private static let dayMs: Int64 = 86_400_000

    static func at(_ expiresAtMs: Int64, _ zone: TimeZone) -> Int64 {
        let candidate = expiresAtMs - leadMs
        let local = candidate + offsetMs(zone, candidate)
        let date = floorDiv(local, dayMs)
        let time = local - date * dayMs
        if time >= quietEnd && time < quietStart { return candidate }
        let day = time >= quietStart ? date : date - 1
        return instant(zone, day * dayMs + evening)
    }

    /// The instant a local date-time (milliseconds after 1970-01-01T00:00 local) is in `zone`, chosen as java.time's
    /// `atZone` does: the earlier offset where clocks go back, and later by the length of the gap where they go forward.
    private static func instant(_ zone: TimeZone, _ local: Int64) -> Int64 {
        let before = offsetMs(zone, local - dayMs)
        let after = offsetMs(zone, local + dayMs)
        if offsetMs(zone, local - before) == before { return local - before }
        if offsetMs(zone, local - after) == after { return local - after }
        return local - before
    }

    private static func offsetMs(_ zone: TimeZone, _ instantMs: Int64) -> Int64 {
        Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(instantMs) / 1000))) * 1000
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return a % b != 0 && (a < 0) != (b < 0) ? q - 1 : q
    }
}
