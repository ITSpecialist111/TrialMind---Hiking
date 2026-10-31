import Foundation

/// One hour of a point forecast. Values the source doesn't give are NaN.
struct ForecastHour: Hashable {
    var timeMs: Int64
    var temperatureC: Double
    var feelsLikeC: Double
    var windKmh: Double
    var gustKmh: Double
    var windFromDeg: Double
    var rainChancePct: Double
    var rainMm: Double
    var lowCloudPct: Double
    var visibilityM: Double
    var freezingLevelM: Double
}

/// An hourly forecast for one place, kept as fetched so it can be read offline.
struct PointForecast: Hashable {
    var fetchedMs: Int64
    var hours: [ForecastHour]

    private static let maxGapMs: Int64 = 90 * 60_000

    /// The hour nearest `timeMs`, or nil when the forecast doesn't reach it.
    func at(_ timeMs: Int64) -> ForecastHour? {
        guard let nearest = hours.min(by: { abs($0.timeMs - timeMs) < abs($1.timeMs - timeMs) }) else { return nil }
        return abs(nearest.timeMs - timeMs) <= Self.maxGapMs ? nearest : nil
    }
}

/// Mountain weather in the terms a hill walker plans with.
enum MountainWeather {
    // Gusts of 40 mph make walking hard; 50 mph is dangerous on exposed ground.
    private static let gustHardKmh = 64.0
    private static let gustSevereKmh = 80.0

    static func summary(_ h: ForecastHour, imperial: Bool) -> String {
        var parts: [String] = []
        if !h.temperatureC.isNaN { parts.append(temp(h.temperatureC) + (h.feelsLikeC.isNaN ? "" : ", feels like \(temp(h.feelsLikeC))")) }
        if !h.windKmh.isNaN {
            let from = h.windFromDeg.isNaN ? "" : Geo.cardinal(h.windFromDeg) + " "
            parts.append("wind \(from)\(speed(h.windKmh, imperial))" + (h.gustKmh.isNaN ? "" : " gusting \(speed(h.gustKmh, imperial))"))
        }
        if !h.rainChancePct.isNaN { parts.append("\(kRound(h.rainChancePct))% chance of rain") }
        if !h.lowCloudPct.isNaN {
            parts.append("low cloud \(kRound(h.lowCloudPct))%" + (h.lowCloudPct >= 80 ? " (the tops may be in cloud)" : ""))
        }
        if !h.freezingLevelM.isNaN { parts.append("freezing level \(Units.elevation(h.freezingLevelM, imperial: imperial))") }
        return parts.joined(separator: ", ")
    }

    /// Hazards at a point `eleM` high. NaN values never trigger one.
    static func warnings(_ h: ForecastHour, eleM: Double, imperial: Bool) -> [String] {
        var out: [String] = []
        if h.gustKmh >= gustSevereKmh {
            out.append("Gusts of \(speed(h.gustKmh, imperial)): dangerous on exposed ground. Consider a lower route.")
        } else if h.gustKmh >= gustHardKmh {
            out.append("Gusts of \(speed(h.gustKmh, imperial)): walking will be hard work, and exposed ridges hazardous.")
        }
        if h.feelsLikeC <= 0 { out.append("Feels like \(temp(h.feelsLikeC)) up there: take a hat, gloves and a warm layer.") }
        if h.freezingLevelM < eleM {
            out.append("Freezing level \(Units.elevation(h.freezingLevelM, imperial: imperial)), below the high point: expect ice or snow on the tops.")
        }
        if h.visibilityM < 1000 { out.append("Visibility under \(Units.distance(1000.0, imperial: imperial)): navigate by map and compass.") }
        if h.rainMm >= 4 { out.append("Heavy rain (\(kRound(h.rainMm)) mm in the hour): streams may be hard to cross.") }
        return out
    }

    private static func temp(_ c: Double) -> String { "\(kRound(c))°C" }

    private static func speed(_ kmh: Double, _ imperial: Bool) -> String {
        imperial ? "\(kRound(kmh / 1.609344)) mph" : "\(kRound(kmh)) km/h"
    }
}
