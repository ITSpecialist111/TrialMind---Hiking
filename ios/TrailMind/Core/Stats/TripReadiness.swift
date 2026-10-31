import Foundation

enum TripReadiness {
    static func followUpMs(_ dueMs: Int64) -> Int64 { dueMs + 30 * 60_000 }

    static func defaultReturnMs(_ nowMs: Int64, planningMinutes: Double) -> Int64 {
        let quarter: Int64 = 15 * 60_000
        let end = nowMs + kTruncateL(ceil(max(planningMinutes, 0.0) * 1.5)) * 60_000
        return ((end + quarter - 1) / quarter) * quarter
    }

    static func summary(ready: Int, total: Int) -> String { "\(ready) of \(total) ready" }

    static func coverage(hits: Int, samples: Int) -> Int { samples == 0 ? 0 : (hits * 100 / samples).clamped(0, 100) }

    static func sampleRoute(_ points: [LatLon], spacingM: Double = 100.0) -> [LatLon] {
        if points.count < 2 { return points }
        precondition(spacingM > 0)
        let lengths = zip(points, points.dropFirst()).map { first, second in Geo.distanceM(first.lat, first.lon, second.lat, second.lon) }
        let total = lengths.reduce(0.0, +)
        let count = kTruncate(ceil(total / spacingM)).clamped(1, 500)
        let step = total / Double(count)
        var result: [LatLon] = []
        result.reserveCapacity(count + 1)
        var leg = 0
        var passed = 0.0
        for index in 0...count {
            let target = Double(index) * step
            while leg < lengths.count - 1 && passed + lengths[leg] < target {
                passed += lengths[leg]
                leg += 1
            }
            let fraction = lengths[leg] == 0.0 ? 0.0 : ((target - passed) / lengths[leg]).clamped(0.0, 1.0)
            result.append(LatLon(points[leg].lat + (points[leg + 1].lat - points[leg].lat) * fraction,
                                 points[leg].lon + (points[leg + 1].lon - points[leg].lon) * fraction))
        }
        return result
    }

    static func sms(routeName: String, location: LatLon?, time: String, batteryPercent: Int) -> String {
        var text = "I'm running late on " + (routeName.isBlank ? "my walk" : routeName) + ". "
        if let location {
            text += "Grid " + (OsGrid.fromWgs84(location)?.format(8) ?? "unavailable") + ". "
            text += "Map https://www.openstreetmap.org/?mlat=" + fmt("%.5f", location.lat) + "&mlon=" + fmt("%.5f", location.lon) + ". "
        } else {
            text += "No location fix. "
        }
        text += "Time " + time + ". Battery "
        text += batteryPercent < 0 ? "unavailable." : "\(batteryPercent)%."
        return text
    }
}
