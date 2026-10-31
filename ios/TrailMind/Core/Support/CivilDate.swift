import Foundation

/// java.time's calendar arithmetic (proleptic Gregorian dates, UTC epoch days and ISO-8601 instants) done with plain
/// integers rather than Foundation's `Calendar`, so dates and times come out exactly as on Android.
enum CivilDate {
    static let msPerDay: Int64 = 86_400_000

    /// `LocalDate.of(year, month, day).toEpochDay()`.
    static func epochDay(_ year: Int64, _ month: Int, _ day: Int) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let m = Int64(month)
        let dayOfYear = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// `LocalDate.ofEpochDay(epochDay)` as its year, month and day.
    static func fromEpochDay(_ epochDay: Int64) -> (year: Int64, month: Int, day: Int) {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), Int(month), Int(day))
    }

    static func lengthOfMonth(_ year: Int64, _ month: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// `Instant.ofEpochMilli(ms).atZone(zone).toLocalDate().toEpochDay()`.
    static func localEpochDay(_ ms: Int64, _ zone: TimeZone) -> Int64 {
        let offsetS = zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000.0))
        return floorDiv(ms + Int64(offsetS) * 1000, msPerDay)
    }

    /// `Instant.ofEpochMilli(ms).toString()`: `2023-11-14T22:13:20Z`, with `.123` when there are milliseconds.
    static func isoInstant(_ ms: Int64) -> String {
        let day = floorDiv(ms, msPerDay)
        let msOfDay = ms - day * msPerDay
        let date = fromEpochDay(day)
        var text = isoYear(date.year) + "-" + two(Int64(date.month)) + "-" + two(Int64(date.day)) + "T" +
            two(msOfDay / 3_600_000) + ":" + two(msOfDay / 60_000 % 60) + ":" + two(msOfDay / 1000 % 60)
        let millis = msOfDay % 1000
        if millis != 0 { text += "." + String(millis).padStart(3, "0") }
        return text + "Z"
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return a % b != 0 && (a < 0) != (b < 0) ? q - 1 : q
    }

    private static func two(_ v: Int64) -> String { String(v).padStart(2, "0") }

    private static func isoYear(_ year: Int64) -> String {
        if year > 9999 { return "+" + String(year) }
        if year < 0 { return "-" + String(-year).padStart(4, "0") }
        return String(year).padStart(4, "0")
    }
}
