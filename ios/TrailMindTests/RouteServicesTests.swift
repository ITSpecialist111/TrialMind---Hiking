import XCTest
@testable import TrailMind

final class OverpassTests: XCTestCase {
    private let route = [LatLon(51.78, -2.54), LatLon(51.78, -2.53), LatLon(51.79, -2.53)]

    private func parse(_ reply: String, truncated: Bool = false) throws -> (items: [Facility], partial: Bool) {
        try Overpass.parse(Array(reply.utf8), truncated: truncated, points: route)
    }

    func testQueryAsksForFacilitiesAlongTheRouteAndTransportAtItsEnds() {
        let q = Overpass.query(route)
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:120];("))
        XCTAssertTrue(q.hasSuffix(");out center tags 900;"))
        let around = "around:250,51.78,-2.54,51.78,-2.53,51.79,-2.53"
        XCTAssertTrue(q.contains("nwr(\(around))[amenity~\"^(drinking_water|water_point|toilets|pub|cafe|restaurant|parking|shelter)$\"];"))
        XCTAssertTrue(q.contains("nwr(\(around))[man_made=water_tap][drinking_water=yes];"))
        XCTAssertTrue(q.contains("nwr(\(around))[natural=peak][name];"))
        XCTAssertTrue(q.contains("nwr(around:800,51.78,-2.54)[amenity=parking];"))
        XCTAssertTrue(q.contains("nwr(around:800,51.79,-2.53)[railway~\"^(station|halt)$\"];"))
        XCTAssertEqual(q.components(separatedBy: "nwr(").count - 1, 8 + 6)
    }

    func testALoopAsksForTransportOnceAndAPointUsesAround() {
        XCTAssertEqual(Overpass.query(route + [route[0]]).components(separatedBy: "nwr(").count - 1, 8 + 3)
        XCTAssertTrue(Overpass.query([LatLon(51.78, -2.54)]).contains("nwr(around:250,51.78,-2.54)[highway=bus_stop];"))
        XCTAssertEqual(Overpass.body("nwr(around:250,1,2);"), "data=nwr%28around%3A250%2C1%2C2%29%3B")
    }

    func testReadsElementsWithCentresAndTags() throws {
        let (items, partial) = try parse(#"""
        {"version": 0.6, "generator": "Overpass API", "osm3s": {"copyright": "ODbL"}, "elements": [
          {"type": "node", "id": 1, "lat": 51.7801, "lon": -2.5395, "tags": {"amenity": "drinking_water"}},
          {"type": "way", "id": 2, "center": {"lat": 51.7802, "lon": -2.5350}, "tags": {"amenity": "cafe", "name": "Café", "opening_hours": "9-5", "ele": 120}},
          {"type": "node", "id": 3, "lat": 51.7800, "lon": -2.5300, "tags": {"amenity": "bench"}},
          {"type": "node", "id": 4, "lat": 51.7900, "lon": -2.5300, "tags": {"amenity": "parking", "access": "private"}},
          {"type": "node", "id": 5, "tags": {"amenity": "toilets"}}
        ]}
        """#)
        XCTAssertFalse(partial)
        XCTAssertEqual(items.map(\.category), [.water, .cafe])
        XCTAssertEqual(items[1].name, "Café")
        XCTAssertEqual(items[1].openingHours, "9-5")
        XCTAssertEqual(items[1].ele, "120")
        XCTAssertEqual(items[1].position, LatLon(51.7802, -2.5350))
        XCTAssertTrue(items[0].alongM < items[1].alongM)
        XCTAssertTrue(items[1].offM < 30)
    }

    func testARuntimeErrorRemarkMarksTheResultsPartial() throws {
        let (items, partial) = try parse(#"{"elements": [{"lat": 51.78, "lon": -2.539, "tags": {"amenity": "toilets"}}], "remark": "runtime error: Query timed out"}"#)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(partial)
        XCTAssertFalse(try parse(#"{"elements": [], "remark": "fine"}"#).partial)
    }

    func testACutReplyKeepsWhatCameBeforeTheCut() throws {
        let cut = #"{"elements": [{"lat": 51.78, "lon": -2.539, "tags": {"amenity": "toilets"}}, {"lat": 51.78, "lon": -2.538, "tags": {"amenity": "pub", "name": "The Ro"#
        let (items, partial) = try parse(cut, truncated: true)
        XCTAssertEqual(items.map(\.category), [.toilets])
        XCTAssertTrue(partial)
        XCTAssertThrowsError(try parse(cut))
        XCTAssertThrowsError(try parse(#"{"elements": [{"lat": 51."#, truncated: true)) {
            XCTAssertEqual($0.localizedDescription, "Overpass returned no facilities before its limit.")
        }
        XCTAssertThrowsError(try parse(#"["elements"]"#))
    }

    func testTheElementLimitMarksTheResultsPartial() throws {
        let element = #"{"lat": 51.78, "lon": -2.539, "tags": {"amenity": "toilets"}}"#
        let (items, partial) = try parse("{\"elements\": [" + Array(repeating: element, count: 900).joined(separator: ",") + "]}")
        XCTAssertTrue(partial)
        // The same toilets listed 900 times are one.
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(try parse("{\"elements\": [" + Array(repeating: element, count: 899).joined(separator: ",") + "]}").partial)
    }

    func testSavedFacilitiesReadBack() throws {
        let saved = SavedFacilities(fetchedMs: 1_700_000_000_123, items: [
            Facility(category: .pub, position: LatLon(51.78, -2.5), name: "The \"Rose\"", ele: "", openingHours: "Mo-Su 12:00-23:00",
                     fee: "", access: "", website: "https://example.org/a", alongM: 1234.5, offM: 12.0),
            Facility(category: .peak, position: LatLon(51.79, -2.51), name: "May Hill", ele: "296", alongM: 2000.25, offM: 0.5),
        ], partial: true)
        let text = saved.json()
        XCTAssertTrue(text.hasPrefix(#"{"fetchedMs":1700000000123,"partial":true,"items":[{"category":"PUB","lat":51.78,"lon":-2.5,"name":"The \"Rose\"","#))
        XCTAssertEqual(SavedFacilities.from(text), saved)
        XCTAssertNil(SavedFacilities.from(text.replacingOccurrences(of: "\"PUB\"", with: "\"SPA\"")))
        XCTAssertNil(SavedFacilities.from("{\"fetchedMs\": 1"))
        XCTAssertEqual(SavedFacilities.from(#"{"fetchedMs": 5, "items": []}"#), SavedFacilities(fetchedMs: 5, items: [], partial: false))
    }

    func testBacksOffAsTheOperatorsAsk() {
        XCTAssertNil(Overpass.backoffUntil(status: 200, retryAfter: "60", nowMs: 1000))
        XCTAssertEqual(Overpass.backoffUntil(status: 429, retryAfter: nil, nowMs: 1000), 31_000)
        XCTAssertEqual(Overpass.backoffUntil(status: 406, retryAfter: " 90 ", nowMs: 1000), 91_000)
        XCTAssertEqual(Overpass.backoffUntil(status: 429, retryAfter: "soon", nowMs: 0), 30_000)
        XCTAssertEqual(Overpass.busyMessage(waitMs: 12_001), "Overpass is busy. Try again in 13 s.")
    }
}

final class BRouterTests: XCTestCase {
    func testRequestMatchesTheAndroidApp() {
        let s = BRouter.urlString(LatLon(54.4521, -3.0123456), LatLon(54.46, -3.01))
        XCTAssertEqual(s, "https://brouter.de/brouter?lonlats=-3.012346,54.452100|-3.010000,54.460000&profile=hiking-mountain&alternativeidx=0&format=geojson")
        XCTAssertEqual(BRouter.url(LatLon(54.4521, -3.0123456), LatLon(54.46, -3.01))?.absoluteString,
                       s.replacingOccurrences(of: "|", with: "%7C"))
    }

    func testReadsALineWithHeights() throws {
        let reply = try RoutesJSON.parse(#"{"type": "FeatureCollection", "features": [{"type": "Feature", "properties": {}, "geometry": {"type": "LineString", "coordinates": [[-3.0, 54.0, 120.5], [-3.001, 54.001], [-3.002, 54.002, null]]}}]}"#)
        XCTAssertEqual(try BRouter.parse(reply), [TrackPoint(lat: 54.0, lon: -3.0, ele: 120.5), TrackPoint(lat: 54.001, lon: -3.001),
                                                  TrackPoint(lat: 54.002, lon: -3.002)])
    }

    func testTellsNoPathFromAFailingService() throws {
        XCTAssertTrue(BRouter.failure(status: 400, body: "operation killed: no track found at pass=0") is BRouter.NoPath)
        XCTAssertTrue(BRouter.failure(status: 400, body: "Position 1 is not mapped") is BRouter.NoPath)
        XCTAssertTrue(BRouter.failure(status: 400, body: "target island detected for section 0") is BRouter.NoPath)
        XCTAssertFalse(BRouter.failure(status: 400, body: "bad request") is BRouter.NoPath)
        let other = BRouter.failure(status: 500, body: String(repeating: "x", count: 300))
        XCTAssertFalse(other is BRouter.NoPath)
        XCTAssertEqual(other.localizedDescription, "BRouter HTTP 500: " + String(repeating: "x", count: 160))
        for empty in [#"{"features": []}"#, #"{"features": [{"geometry": {"type": "Point", "coordinates": [0, 0]}}]}"#,
                      #"{"features": [{"geometry": {"type": "LineString", "coordinates": [[0, 0]]}}]}"#] {
            XCTAssertThrowsError(try BRouter.parse(RoutesJSON.parse(empty))) { XCTAssertTrue($0 is BRouter.NoPath) }
        }
        XCTAssertThrowsError(try BRouter.parse(RoutesJSON.parse("{}"))) { XCTAssertFalse($0 is BRouter.NoPath) }
    }
}

final class RouteWeatherTests: XCTestCase {
    func testAsksForTheForecastAtTheHighPointsHeight() {
        XCTAssertEqual(RouteWeather.forecastURL(LatLon(54.527, -3.0165), eleM: 949.6),
                       "https://api.open-meteo.com/v1/forecast?latitude=54.527&longitude=-3.0165&elevation=950&hourly=temperature_2m," +
                        "apparent_temperature,wind_speed_10m,wind_gusts_10m,wind_direction_10m,precipitation_probability,precipitation," +
                        "cloud_cover_low,visibility,freezing_level_height&timeformat=unixtime&forecast_days=5")
        XCTAssertTrue(RouteWeather.forecastURL(LatLon(51.5, -0.0001), eleM: 10).contains("&longitude=-1.0E-4&"))
    }

    func testReadsHourlyColumnsWithGaps() throws {
        let reply = try RoutesJSON.parse(#"{"hourly": {"time": [1700000000, 1700003600], "temperature_2m": [5.5, null], "wind_gusts_10m": [70, 81.2], "visibility": ["900"]}}"#)
        let f = try RouteWeather.parse(reply, fetchedMs: 42)
        XCTAssertEqual(f.fetchedMs, 42)
        XCTAssertEqual(f.hours.map(\.timeMs), [1_700_000_000_000, 1_700_003_600_000])
        XCTAssertEqual(f.hours[0].temperatureC, 5.5)
        XCTAssertTrue(f.hours[1].temperatureC.isNaN)
        XCTAssertEqual(f.hours[1].gustKmh, 81.2)
        XCTAssertEqual(f.hours[0].visibilityM, 900)
        XCTAssertTrue(f.hours[1].visibilityM.isNaN)
        XCTAssertTrue(f.hours[0].freezingLevelM.isNaN)
        XCTAssertThrowsError(try RouteWeather.parse(RoutesJSON.parse("{}"), fetchedMs: 0))
    }

    func testSavedForecastsReadBackAndDamagedOnesDoNot() throws {
        let reply = try RoutesJSON.parse(#"{"latitude": 54.5, "hourly": {"time": [1700000000], "temperature_2m": [3]}}"#)
        let file = RouteWeather.savedFile(reply, fetchedMs: 1_700_000_100_000)
        XCTAssertEqual(file, #"{"fetchedMs":1700000100000,"data":{"latitude":54.5,"hourly":{"time":[1700000000],"temperature_2m":[3]}}}"#)
        let saved = try XCTUnwrap(RouteWeather.readSaved(file))
        XCTAssertEqual(saved.fetchedMs, 1_700_000_100_000)
        XCTAssertEqual(saved.hours.first?.temperatureC, 3)
        XCTAssertNil(RouteWeather.readSaved(String(file.dropLast(5))))
        XCTAssertNil(RouteWeather.readSaved(#"{"fetchedMs": 1}"#))
    }
}
