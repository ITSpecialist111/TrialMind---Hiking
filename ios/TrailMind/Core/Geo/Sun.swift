import Foundation

struct SunTimes: Hashable {
    var sunriseMs: Int64?
    var sunsetMs: Int64?
    var polarDay: Bool
    var polarNight: Bool
    var civilDuskMs: Int64? = nil
}

/// Solar transit and -0.833 degree apparent sunrise/sunset, with -6 degree civil dusk.
enum Sun {
    /// Times for a calendar day: `date` holds its Gregorian year, month and day (the Kotlin `LocalDate`).
    static func times(_ date: DateComponents, _ at: LatLon) -> SunTimes {
        guard let year = date.year, let month = date.month, let day = date.day else {
            preconditionFailure("Sun.times needs a year, month and day")
        }
        return times(epochDay: CivilDate.epochDay(Int64(year), month, day), at)
    }

    /// Times for the day `epochDay` days after 1 January 1970 (`LocalDate.toEpochDay()`).
    static func times(epochDay: Int64, _ at: LatLon) -> SunTimes {
        let midnight = epochDay * 86_400_000
        let julian = Double(epochDay) + 2440587.5
        let phi = toRadians(at.lat)
        func solar(_ jd: Double) -> (equation: Double, declination: Double) {
            let t = (jd - 2451545.0) / 36525.0
            let meanLong = toRadians(Geo.normalizeDeg(280.46646 + t * (36000.76983 + 0.0003032 * t)))
            let anomaly = toRadians(Geo.normalizeDeg(357.52911 + t * (35999.05029 - 0.0001537 * t)))
            let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
            let center = sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
                sin(2 * anomaly) * (0.019993 - 0.000101 * t) + sin(3 * anomaly) * 0.000289
            let omega = toRadians(125.04 - 1934.136 * t)
            let longitude = meanLong + toRadians(center - 0.00569 - 0.00478 * sin(omega))
            let obliquity = toRadians(23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60 + 0.00256 * cos(omega))
            let declination = asin(sin(obliquity) * sin(longitude))
            let y = tan(obliquity / 2) * tan(obliquity / 2)
            let equation = 4 * toDegrees(y * sin(2 * meanLong) - 2 * eccentricity * sin(anomaly) +
                4 * eccentricity * y * sin(anomaly) * cos(2 * meanLong) - y * y * sin(4 * meanLong) / 2 -
                1.25 * eccentricity * eccentricity * sin(2 * anomaly))
            return (equation, declination)
        }
        func crossing(_ altitude: Double, setting: Bool) -> Int64? {
            var minutes = 720.0 - 4 * at.lon
            for _ in 0..<3 {
                let (equation, declination) = solar(julian + minutes / 1440.0)
                let cosH = (sin(toRadians(altitude)) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination))
                if !(cosH >= -1.0 && cosH <= 1.0) { return nil }
                let hourAngle = toDegrees(acos(cosH))
                minutes = 720 - 4 * at.lon - equation + (setting ? 4 * hourAngle : -4 * hourAngle)
            }
            return midnight + kTruncateL(minutes * 60_000)
        }
        let rise = crossing(-0.833, setting: false)
        let set = crossing(-0.833, setting: true)
        guard let rise, let set else {
            let declination = solar(julian + 0.5).declination
            let below = (sin(toRadians(-0.833)) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination)) > 1
            return SunTimes(sunriseMs: nil, sunsetMs: nil, polarDay: !below, polarNight: below)
        }
        return SunTimes(sunriseMs: rise, sunsetMs: set, polarDay: false, polarNight: false, civilDuskMs: crossing(-6.0, setting: true))
    }

    static func today(_ at: LatLon) -> SunTimes { times(epochDay: CivilDate.localEpochDay(nowMs(), .current), at) }
}
