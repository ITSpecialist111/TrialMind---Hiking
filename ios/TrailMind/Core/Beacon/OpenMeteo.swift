import Foundation

/// Hourly point forecasts from Open-Meteo (free, no key), saved per route so they can be read offline (data/OpenMeteo.kt).
/// This is the part that needs no network: the request, reading the answer, and the file kept on the phone.
enum OpenMeteo {
    // CC BY 4.0: the credit links to Open-Meteo, and says TrailMind adds its own warnings to their data.
    static let attribution = "Weather data by Open-Meteo.com (CC BY 4.0); warnings worked out by TrailMind"
    static let url = "https://open-meteo.com/"
    static let licenceUrl = "https://creativecommons.org/licenses/by/4.0/"
    static let hourly = "temperature_2m,apparent_temperature,wind_speed_10m,wind_gusts_10m,wind_direction_10m," +
        "precipitation_probability,precipitation,cloud_cover_low,visibility,freezing_level_height"
    static let maxBytes = 512 * 1024

    /// The forecast for `at`, `eleM` high (Open-Meteo corrects its temperatures to that height), five days ahead.
    static func forecastUrl(_ at: LatLon, _ eleM: Double) -> String {
        "https://api.open-meteo.com/v1/forecast?latitude=\(BeaconJSON.javaDouble(at.lat))&longitude=\(BeaconJSON.javaDouble(at.lon))" +
            "&elevation=\(kRound(eleM))&hourly=\(hourly)&timeformat=unixtime&forecast_days=5"
    }

    /// Reads Open-Meteo's answer. Throws when it has no hourly times; a column it leaves out, or a null hour, is NaN.
    static func parse(_ data: Data, fetchedMs: Int64) throws -> PointForecast {
        try parse(json: BeaconJSON.object(data), fetchedMs: fetchedMs)
    }

    static func parse(json: [String: Any], fetchedMs: Int64) throws -> PointForecast {
        guard let hourly = json["hourly"] as? [String: Any] else { throw BeaconJSON.Malformed("The forecast has no hourly data.") }
        guard let time = hourly["time"] as? [Any] else { throw BeaconJSON.Malformed("The forecast has no hourly times.") }
        func column(_ name: String) -> (Int) -> Double {
            let a = hourly[name] as? [Any]
            return { i in
                guard let a, i < a.count, !BeaconJSON.isNull(a[i]) else { return .nan }
                return BeaconJSON.double(a[i]) ?? .nan
            }
        }
        let temp = column("temperature_2m")
        let feels = column("apparent_temperature")
        let wind = column("wind_speed_10m")
        let gust = column("wind_gusts_10m")
        let from = column("wind_direction_10m")
        let chance = column("precipitation_probability")
        let rain = column("precipitation")
        let lowCloud = column("cloud_cover_low")
        let visibility = column("visibility")
        let freezing = column("freezing_level_height")
        var hours: [ForecastHour] = []
        hours.reserveCapacity(time.count)
        for i in time.indices {
            guard let seconds = BeaconJSON.long(time[i]) else { throw BeaconJSON.Malformed("Hour \(i) of the forecast has no time.") }
            hours.append(ForecastHour(timeMs: seconds &* 1000, temperatureC: temp(i), feelsLikeC: feels(i), windKmh: wind(i),
                                      gustKmh: gust(i), windFromDeg: from(i), rainChancePct: chance(i), rainMm: rain(i),
                                      lowCloudPct: lowCloud(i), visibilityM: visibility(i), freezingLevelM: freezing(i)))
        }
        return PointForecast(fetchedMs: fetchedMs, hours: hours)
    }

    /// The file kept on the phone: `{"fetchedMs": …, "data": <Open-Meteo's answer as it came>}`, as Android writes it.
    static func savedFile(_ answer: Data, fetchedMs: Int64) -> Data {
        var body = answer
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body.removeFirst(3) }
        var out = Data("{\"fetchedMs\":\(fetchedMs),\"data\":".utf8)
        out.append(body)
        out.append(contentsOf: Array("}".utf8))
        return out
    }

    /// The saved forecast, or nil when the file is damaged (say, cut short by a full disk): that counts as no forecast.
    static func readSaved(_ file: Data) -> PointForecast? {
        guard let root = BeaconJSON.optObject(file), let data = root["data"] as? [String: Any],
              let fetchedMs = BeaconJSON.long(root["fetchedMs"]) else { return nil }
        return try? parse(json: data, fetchedMs: fetchedMs)
    }
}
