import Foundation

struct DaylightEstimate: Hashable {
    var finishMs: Int64
    var remainingMinutes: Double
    var daylightLeftMs: Int64?
    var afterSafeSunset: Bool?
    var walkBackMinutes: Double?
    var turnBackByMs: Int64?
    var startByMs: Int64?
    var afterCivilDusk: Bool?
    var darkNow: Bool?
    var nextSunriseMs: Int64?
}

enum Daylight {
    static func alertDue(sunsetDue: Bool, duskDue: Bool, sunsetAlerted: Bool, duskAlerted: Bool) -> Int {
        if sunsetDue && !sunsetAlerted { return 1 }
        if duskDue && !duskAlerted { return 2 }
        return 0
    }

    static func watchAlert(darkNow: Bool) -> String {
        darkNow ? "It's dark now. Plan a safe way down." : "Finish after sunset. Plan a safe way down."
    }

    static func estimate(nowMs: Int64, remaining: [TrackPoint], walked: [TrackPoint], movingMinutes: Double?,
                         pace: PaceSettings, sun: SunTimes, marginMinutes: Int, zone: TimeZone = .current) -> DaylightEstimate {
        precondition(marginMinutes >= 0)
        let walkedPlan = HikeEstimator.estimate(walked, pace: pace).planningMinutes
        var scale = 1.0
        if walkedPlan >= 15.0, let moving = movingMinutes, moving >= 10.0 { scale = (moving / walkedPlan).clamped(0.5, 3.0) }
        let remainingMinutes = HikeEstimator.estimate(remaining, pace: pace).planningMinutes * scale
        let backMinutes = walked.count >= 2 ? HikeEstimator.estimate(walked.reversed(), pace: pace).planningMinutes * scale : nil
        let meaningfulBack = backMinutes.flatMap { $0 >= 1.0 ? $0 : nil }
        let cutoff = sun.sunsetMs.map { $0 - Int64(marginMinutes) * 60_000 }
        let finish = nowMs + kTruncateL(remainingMinutes * 60_000)
        let fullPlan = HikeEstimator.estimate(remaining, pace: pace).planningMinutes
        let startBy = cutoff.map { $0 - kTruncateL(fullPlan * 60_000) }.flatMap { by -> Int64? in
            guard let sunrise = sun.sunriseMs else { return by }
            return by >= sunrise ? by : nil
        }
        let beforeSunrise = sun.sunriseMs.map { nowMs < $0 } == true
        let afterDusk = sun.civilDuskMs.map { nowMs >= $0 } == true
        let dark: Bool?
        if sun.polarNight {
            dark = true
        } else if sun.polarDay {
            dark = false
        } else if sun.sunriseMs == nil || sun.civilDuskMs == nil {
            dark = nil
        } else {
            dark = beforeSunrise || afterDusk
        }
        var tomorrow: Int64? = nil
        if afterDusk && !remaining.isEmpty {
            let date = CivilDate.localEpochDay(nowMs, zone) + 1
            tomorrow = Sun.times(epochDay: date, remaining[0].latLon()).sunriseMs
        }
        let sunrise = beforeSunrise ? sun.sunriseMs : tomorrow
        return DaylightEstimate(
            finishMs: finish,
            remainingMinutes: remainingMinutes,
            daylightLeftMs: sun.sunsetMs.map { $0 - nowMs }.flatMap { !beforeSunrise && !afterDusk ? $0 : nil },
            afterSafeSunset: dark.flatMap { $0 ? true : cutoff.map { finish > $0 } },
            walkBackMinutes: meaningfulBack,
            turnBackByMs: meaningfulBack.flatMap { back in cutoff.map { $0 - kTruncateL(back * 60_000) } },
            startByMs: startBy,
            afterCivilDusk: dark.flatMap { $0 ? true : sun.civilDuskMs.map { finish > $0 } },
            darkNow: dark,
            nextSunriseMs: sunrise
        )
    }
}
