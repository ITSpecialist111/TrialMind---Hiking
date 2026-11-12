import Foundation

/// Hourly point forecasts from Open-Meteo (free, no key) for a route's high point, saved per route so they can be read
/// offline (OpenMeteo.kt): the request, the reply, and the saved file `{"fetchedMs": ..., "data": <reply>}`.
enum RouteWeather {
    // CC BY 4.0: the credit links to Open-Meteo, and says TrailMind adds its own warnings to their data.
    static let attribution = "Weather data by Open-Meteo.com (CC BY 4.0); warnings worked out by TrailMind"
    static let url = "https://open-meteo.com/"
    static let licenceURL = "https://creativecommons.org/licenses/by/4.0/"
    static let hourly = "temperature_2m,apparent_temperature,wind_speed_10m,wind_gusts_10m,wind_direction_10m," +
        "precipitation_probability,precipitation,cloud_cover_low,visibility,freezing_level_height"
    static let maxBytes = 512 * 1024
    /// A saved forecast older than this is not trusted for the trip-readiness check.
    static let freshMs: Int64 = 6 * 3_600_000

    /// The forecast for `at`, `eleM` high (Open-Meteo corrects its temperatures to that height).
    static func forecastURL(_ at: LatLon, eleM: Double) -> String {
        "https://api.open-meteo.com/v1/forecast?latitude=\(RoutesJSON.javaDoubleString(at.lat))" +
            "&longitude=\(RoutesJSON.javaDoubleString(at.lon))&elevation=\(kRound(eleM))" +
            "&hourly=\(hourly)&timeformat=unixtime&forecast_days=5"
    }

    static func parse(_ json: RoutesJSON.Value, fetchedMs: Int64) throws -> PointForecast {
        let hourly = try json.getJSONObject("hourly")
        let time = try hourly.getJSONArray("time")
        func column(_ name: String) -> (Int) -> Double {
            let a = hourly.optJSONArray(name)
            return { i in
                guard let a, !RoutesJSON.isNull(a, i) else { return .nan }
                return RoutesJSON.optDouble(a, i)
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
        let hours = try time.indices.map { i in
            ForecastHour(timeMs: try RoutesJSON.getLong(time, i) &* 1000, temperatureC: temp(i), feelsLikeC: feels(i),
                         windKmh: wind(i), gustKmh: gust(i), windFromDeg: from(i), rainChancePct: chance(i), rainMm: rain(i),
                         lowCloudPct: lowCloud(i), visibilityM: visibility(i), freezingLevelM: freezing(i))
        }
        return PointForecast(fetchedMs: fetchedMs, hours: hours)
    }

    /// The file a forecast is saved in.
    static func savedFile(_ reply: RoutesJSON.Value, fetchedMs: Int64) -> String {
        RoutesJSON.Value.object(RoutesJSON.Object([("fetchedMs", .long(fetchedMs)), ("data", reply)])).serialized()
    }

    /// A saved forecast; a damaged file (say, cut short by a full disk) counts as no forecast.
    static func readSaved(_ text: String) -> PointForecast? {
        guard let json = try? RoutesJSON.parse(text),
              let data = try? json.getJSONObject("data"),
              let fetched = try? json.getLong("fetchedMs") else { return nil }
        return try? parse(data, fetchedMs: fetched)
    }
}
