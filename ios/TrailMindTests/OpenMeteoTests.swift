import XCTest
@testable import TrailMind

final class OpenMeteoTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    private let answer = """
        {"latitude":54.46,"longitude":-3.0,"generationtime_ms":0.2,"utc_offset_seconds":0,"timezone":"GMT","elevation":978.0,
         "hourly_units":{"time":"unixtime","temperature_2m":"°C"},
         "hourly":{"time":[1761901200,1761904800,1761908400],
           "temperature_2m":[4.1,null,"2.5"],
           "apparent_temperature":[-1.2,-2.0,-3.4],
           "wind_speed_10m":[38.2,41.0,45.5],
           "wind_gusts_10m":[66.0,72.4,85.3],
           "wind_direction_10m":[270,280,290],
           "precipitation_probability":[40,55,80],
           "precipitation":[0.2,1.1,4.6],
           "cloud_cover_low":[70,85,100],
           "visibility":[24140.0,8000.0,900.0]}}
        """

    func testTheRequestIsTheOneAndroidMakes() {
        XCTAssertEqual(
            "https://api.open-meteo.com/v1/forecast?latitude=54.4542&longitude=-3.2115&elevation=978" +
                "&hourly=temperature_2m,apparent_temperature,wind_speed_10m,wind_gusts_10m,wind_direction_10m," +
                "precipitation_probability,precipitation,cloud_cover_low,visibility,freezing_level_height" +
                "&timeformat=unixtime&forecast_days=5",
            OpenMeteo.forecastUrl(LatLon(54.4542, -3.2115), 977.6))
        // Kotlin prints whole degrees with ".0", tiny ones in E notation, and rounds the height half up.
        XCTAssertTrue(OpenMeteo.forecastUrl(LatLon(52.0, 0.0005), 100.5)
            .hasPrefix("https://api.open-meteo.com/v1/forecast?latitude=52.0&longitude=5.0E-4&elevation=101&"))
        XCTAssertTrue(OpenMeteo.forecastUrl(LatLon(51.5, -0.0001), -2.5).contains("longitude=-1.0E-4&elevation=-2&"))
    }

    func testEachHourAndColumnIsRead() throws {
        let f = try OpenMeteo.parse(data(answer), fetchedMs: 1_761_900_000_000)
        XCTAssertEqual(1_761_900_000_000, f.fetchedMs)
        XCTAssertEqual(3, f.hours.count)
        let h = f.hours[0]
        XCTAssertEqual(1_761_901_200_000, h.timeMs)
        XCTAssertEqual(4.1, h.temperatureC)
        XCTAssertEqual(-1.2, h.feelsLikeC)
        XCTAssertEqual(38.2, h.windKmh)
        XCTAssertEqual(66.0, h.gustKmh)
        XCTAssertEqual(270.0, h.windFromDeg)
        XCTAssertEqual(40.0, h.rainChancePct)
        XCTAssertEqual(0.2, h.rainMm)
        XCTAssertEqual(70.0, h.lowCloudPct)
        XCTAssertEqual(24_140.0, h.visibilityM)
        XCTAssertEqual(1_761_908_400_000, f.hours[2].timeMs)
    }

    func testNullsAndMissingColumnsAreNaNAndNumbersInTextAreRead() throws {
        let f = try OpenMeteo.parse(data(answer), fetchedMs: 0)
        XCTAssertTrue(f.hours[1].temperatureC.isNaN)
        XCTAssertEqual(2.5, f.hours[2].temperatureC)
        // freezing_level_height wasn't sent at all.
        XCTAssertTrue(f.hours.allSatisfy { $0.freezingLevelM.isNaN })
        // A column shorter than the times leaves the rest NaN.
        let short = try OpenMeteo.parse(data(#"{"hourly":{"time":[1,2],"wind_speed_10m":[10]}}"#), fetchedMs: 0)
        XCTAssertEqual(10.0, short.hours[0].windKmh)
        XCTAssertTrue(short.hours[1].windKmh.isNaN)
        XCTAssertEqual(2_000, short.hours[1].timeMs)
    }

    func testAnAnswerWithoutHourlyTimesIsAnError() {
        XCTAssertThrowsError(try OpenMeteo.parse(data(#"{"error":true,"reason":"Latitude must be in range"}"#), fetchedMs: 0))
        XCTAssertThrowsError(try OpenMeteo.parse(data(#"{"hourly":{"temperature_2m":[1]}}"#), fetchedMs: 0))
        XCTAssertThrowsError(try OpenMeteo.parse(data(#"{"hourly":{"time":[1,null]}}"#), fetchedMs: 0))
        XCTAssertThrowsError(try OpenMeteo.parse(data("[1,2]"), fetchedMs: 0))
        XCTAssertThrowsError(try OpenMeteo.parse(data("<html>busy</html>"), fetchedMs: 0))
        XCTAssertEqual(0, try OpenMeteo.parse(data(#"{"hourly":{"time":[]}}"#), fetchedMs: 0).hours.count)
    }

    func testTheSavedFileReadsBackOffline() throws {
        let fetched: Int64 = 1_761_899_000_123
        let file = OpenMeteo.savedFile(data(answer), fetchedMs: fetched)
        XCTAssertTrue(String(decoding: file, as: UTF8.self).hasPrefix("{\"fetchedMs\":1761899000123,\"data\":{"))
        let saved = try XCTUnwrap(OpenMeteo.readSaved(file))
        let fresh = try OpenMeteo.parse(data(answer), fetchedMs: fetched)
        XCTAssertEqual(fetched, saved.fetchedMs)
        XCTAssertEqual(fresh.hours.count, saved.hours.count)
        XCTAssertEqual(fresh.hours[2].gustKmh, saved.hours[2].gustKmh)
        XCTAssertEqual(fresh.hours[2].visibilityM, saved.hours[2].visibilityM)
        // A byte-order mark on the answer doesn't spoil the file.
        let bom = OpenMeteo.savedFile(Data([0xEF, 0xBB, 0xBF]) + data(answer), fetchedMs: 5)
        XCTAssertEqual(5, OpenMeteo.readSaved(bom)?.fetchedMs)
    }

    func testADamagedFileCountsAsNoForecast() {
        let file = OpenMeteo.savedFile(data(answer), fetchedMs: 1)
        XCTAssertNil(OpenMeteo.readSaved(file.prefix(file.count / 2)))
        XCTAssertNil(OpenMeteo.readSaved(Data()))
        XCTAssertNil(OpenMeteo.readSaved(data(#"{"data":{"hourly":{"time":[1]}}}"#)))
        XCTAssertNil(OpenMeteo.readSaved(data(#"{"fetchedMs":1,"data":{"hourly":{}}}"#)))
        XCTAssertEqual(1, OpenMeteo.readSaved(data(#"{"fetchedMs":"1","data":{"hourly":{"time":[1]}}}"#))?.hours.count)
    }

    func testTheSavedHourFeedsTheMountainWarnings() throws {
        let f = try OpenMeteo.parse(data(answer), fetchedMs: 0)
        // Half an hour after the last hour is still within reach; two hours after isn't.
        let hour = try XCTUnwrap(f.at(1_761_908_400_000 + 30 * 60_000))
        XCTAssertEqual(85.3, hour.gustKmh)
        XCTAssertNil(f.at(1_761_908_400_000 + 120 * 60_000))
        let warnings = MountainWeather.warnings(hour, eleM: 978, imperial: false)
        XCTAssertEqual([
            "Gusts of 85 km/h: dangerous on exposed ground. Consider a lower route.",
            "Feels like -3°C up there: take a hat, gloves and a warm layer.",
            "Visibility under 1.00 km: navigate by map and compass.",
            "Heavy rain (5 mm in the hour): streams may be hard to cross.",
        ], warnings)
        XCTAssertEqual("4°C, feels like -1°C, wind W 38 km/h gusting 66 km/h, 40% chance of rain, low cloud 70%",
                       MountainWeather.summary(f.hours[0], imperial: false))
    }
}
