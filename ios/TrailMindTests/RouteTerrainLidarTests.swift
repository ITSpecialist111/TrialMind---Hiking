import XCTest
@testable import TrailMind

final class RouteTerrainLidarTests: XCTestCase {
    func testTerrainTilesAndSlopeColours() {
        XCTAssertEqual(TerrainSource.url(TileKey(13, 4021, 2614)), "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/13/4021/2614.png")
        XCTAssertTrue(TerrainSource.isTerrainTile(TileKey(13, 0, 8191)))
        XCTAssertFalse(TerrainSource.isTerrainTile(TileKey(13, 8192, 0)))
        XCTAssertFalse(TerrainSource.isTerrainTile(TileKey(13, -1, 0)))
        XCTAssertFalse(TerrainSource.isTerrainTile(TileKey(12, 1, 1)))
        XCTAssertEqual(TerrainSource.slopeArgb([0, 1, 2, 3, 4]), [0x0000_0000, 0x58FF_D500, 0x60FF_8000, 0x68DC_2323, 0x7078_2DAA])
        XCTAssertTrue(TerrainSource.requiredAttribution.hasPrefix("* ArcticDEM terrain data DEM(s) were created from DigitalGlobe, Inc., imagery and\n    funded"))
    }

    func testPackTilesFollowTheRouteOrCoverTheArea() {
        let route = [LatLon(54.45, -3.2), LatLon(54.46, -3.18)]
        XCTAssertEqual(Array(TerrainSource.packTiles(route, nil, 50)), TileCoverage.corridor(route, 100, 13))
        XCTAssertEqual(Array(TerrainSource.packTiles(route, nil, 300)), TileCoverage.corridor(route, 300, 13))
        let box = BoundingBox(54.4, -3.2, 54.5, -3.0)
        XCTAssertEqual(Array(TerrainSource.packTiles(nil, box, 0)), Array(TileCoverage.box(box.expandedByMetres(100), 13, 13)))
        XCTAssertTrue(Array(TerrainSource.packTiles([], nil, 0)).isEmpty)
    }

    func testLidarSquaresAndTheirFiles() {
        let square = Lidar.Square(1305, 1985)
        XCTAssertEqual(LidarSource.url(square),
                       "https://environment.data.gov.uk/spatialdata/lidar-composite-digital-terrain-model-dtm-1m/wcs?service=WCS&version=2.0.1" +
                        "&request=GetCoverage&coverageId=13787b9a-26a4-4775-8523-806d13af58fc__Lidar_Composite_Elevation_DTM_1m" +
                        "&format=image/tiff&geotiff:compression=Deflate&subset=E(334080,334336)&subset=N(508160,508416)")
        XCTAssertEqual(LidarSource.fileName(square), "1305_1985.tif")
        XCTAssertEqual(LidarSource.squareOf("1305_1985.tif"), square)
        XCTAssertEqual(LidarSource.squareOf("-1_2.tif"), Lidar.Square(-1, 2))
        XCTAssertNil(LidarSource.squareOf("1305_1985.png"))
        XCTAssertNil(LidarSource.squareOf("_1985.tif"))
        XCTAssertNil(LidarSource.squareOf("1_2_3.tif"))
        XCTAssertEqual(LidarSource.megabytes(10), "1.5 MB")
        XCTAssertEqual(LidarSource.megabytes(7, decimalSeparator: ","), "1,0 MB")
        let points = [LatLon(54.527, -3.0165), LatLon(54.53, -3.01)]
        XCTAssertEqual(LidarCheckPlan.squares(points), Lidar.corridor(points.map { OsGrid.project($0) }, 20.0))
    }

    func testSavedChecksReadBack() {
        let report = LidarRouteReport(lengthM: 1234.5, coveredM: 1200, steep: [LidarSection(10, 25.5, 41.2, LatLon(54.5, -3.0))],
                                      crags: [LidarSection(400, 400, 0, LatLon(54.51, -3.01)), LidarSection(500, 506, 3.6, LatLon(54.52, -3.02))])
        let saved = SavedLidarCheck(checkedMs: 1_700_000_000_000, report: report)
        let text = saved.json()
        XCTAssertTrue(text.hasPrefix(#"{"checkedMs":1700000000000,"lengthM":1234.5,"coveredM":1200,"steep":[{"s":10,"e":25.5,"v":41.2,"lat":54.5,"lon":-3}],"#))
        XCTAssertEqual(SavedLidarCheck.from(text), saved)
        XCTAssertNil(SavedLidarCheck.from(#"{"checkedMs": 1}"#))
        XCTAssertNil(SavedLidarCheck.from("not json"))
    }

    func testCoverageIsNeverRoundedUpToTheWholeRoute() {
        func report(_ length: Double, _ covered: Double) -> LidarRouteReport { LidarRouteReport(lengthM: length, coveredM: covered, steep: [], crags: []) }
        func coverage(_ length: Double, _ covered: Double) -> [Int] {
            let c = LidarCheckPlan.coverage(report(length, covered))
            return [c.full ? 1 : 0, c.percent]
        }
        XCTAssertEqual(coverage(1000, 999.6), [1, 100])
        XCTAssertEqual(coverage(1000, 999.4), [0, 99])
        XCTAssertEqual(coverage(1000, 456.7), [0, 45])
        XCTAssertEqual(coverage(0, 0), [0, 0])
        XCTAssertEqual(LidarCheckPlan.clearText(report(1000, 1000)),
                       "No stretch of the line is 35° or steeper over 10 m, and no crag is within 10 m of it.")
        XCTAssertEqual(LidarCheckPlan.clearText(report(1000, 10))?.hasPrefix("Where LiDAR covers the route, no stretch"), true)
        XCTAssertEqual(LidarCheckPlan.clearText(report(0, 0)), "The route is too short to check.")
        XCTAssertEqual(LidarCheckPlan.clearText(report(1000, 0))?.hasPrefix("LiDAR has no heights along this route"), true)
        XCTAssertNil(LidarCheckPlan.clearText(LidarRouteReport(lengthM: 10, coveredM: 10, steep: [LidarSection(0, 10, 40, LatLon(54, -3))], crags: [])))
    }

    func testStretchFollowsTheLine() {
        let line = [LatLon(54.0, -3.0), LatLon(54.0, -2.99), LatLon(54.01, -2.99)]
        let first = Geo.distanceM(line[0], line[1])
        let s = LidarCheckPlan.stretch(line, first - 10, first + 10)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[1], line[1])
        XCTAssertEqual(Geo.distanceM(s[0], line[1]), 10, accuracy: 0.01)
        XCTAssertEqual(Geo.distanceM(s[2], line[1]), 10, accuracy: 0.01)
        XCTAssertEqual(LidarCheckPlan.stretch(line, 5, 5).count, 2)
    }
}

final class RouteTextTests: XCTestCase {
    private let pace = try! PaceSettings(flatSpeedKmh: 4.5, conditionsFactor: 1.0)
    private let utc = TimeZone(identifier: "UTC")!

    func testQuickTimeAndListLine() {
        XCTAssertEqual(RouteText.naismithQuickMinutes(distanceM: 9000, ascentM: 600, pace: pace), 180.0, accuracy: 1e-9)
        XCTAssertEqual(RouteText.listSubtitle(distanceM: 12_400, ascentM: 640, maxEleM: 950, pace: pace, imperial: false),
                       "12.4\u{00A0}km · ↑640\u{00A0}m · max\u{00A0}950\u{00A0}m · ~3h\u{00A0}49m")
        XCTAssertEqual(RouteText.listSubtitle(distanceM: 800, ascentM: 0, maxEleM: nil, pace: pace, imperial: false), "800\u{00A0}m · ↑0\u{00A0}m · ~11m")
    }

    func testPlanningCaptionMatchesAndroid() {
        let est = HikeEstimate(naismithMinutes: 150, toblerMinutes: 160, distanceM: 10_000, ascentM: 500, descentM: 500)
        XCTAssertEqual(RouteText.planningCaption(est, flatSpeedKmh: 4.5, conditionsFactor: 1.2, imperial: false),
                       "Planning time 2h 40m (slower of Naismith+Langmuir and Tobler at 4.5 km/h, ×1.2 for conditions). Excludes breaks.")
        XCTAssertTrue(RouteText.planningCaption(est, flatSpeedKmh: 5, conditionsFactor: 1, imperial: true).contains("at 3.1 mph, ×1.0 for conditions"))
    }

    func testStartByText() throws {
        let day = CivilDate.epochDay(2026, 6, 21)
        let morning = day * 86_400_000 + 8 * 3_600_000
        let points = [TrackPoint(lat: 54.527, lon: -3.0165), TrackPoint(lat: 54.53, lon: -3.01)]
        let clock: (Int64) -> String = { "c\($0 / 60_000)" }
        let finish: (Int64) -> String = { "f\($0 / 60_000)" }
        let sun = Sun.times(epochDay: day, points[0].latLon())
        let sunset = try XCTUnwrap(sun.sunsetMs)
        let text = RouteText.startBy(points, pace: pace, marginMinutes: 30, forMs: morning, zone: utc, clock: clock, finish: finish)
        XCTAssertTrue(text.hasPrefix("Start by c"), text)
        XCTAssertTrue(text.hasSuffix("to finish before sunset (c\(sunset / 60_000)) with 30 min to spare."), text)
        XCTAssertTrue(RouteText.daylightReady(text))

        let night = day * 86_400_000 + 3_600_000
        let dark = RouteText.startBy(points, pace: pace, marginMinutes: 30, forMs: night, zone: utc, clock: clock, finish: finish)
        XCTAssertEqual(dark, "It's dark now. Sunrise f\(try XCTUnwrap(sun.sunriseMs) / 60_000).")
        XCTAssertFalse(RouteText.daylightReady(dark))

        let arctic = [TrackPoint(lat: 70.0, lon: 20.0), TrackPoint(lat: 70.01, lon: 20.0)]
        XCTAssertEqual(RouteText.startBy(arctic, pace: pace, marginMinutes: 30, forMs: morning, zone: utc, clock: clock, finish: finish),
                       "No sunset today at this location.")
        let long = [TrackPoint(lat: 54.0, lon: -3.0), TrackPoint(lat: 56.0, lon: -3.0)]
        XCTAssertEqual(RouteText.startBy(long, pace: pace, marginMinutes: 30, forMs: morning, zone: utc, clock: clock, finish: finish),
                       "No start time today: route is too long to finish before sunset.")
        XCTAssertEqual(RouteText.startBy([points[0]], pace: pace, marginMinutes: 30, forMs: morning, clock: clock, finish: finish),
                       "No route timing available.")
        let late = day * 86_400_000 + 20 * 3_600_000 + 30 * 60_000
        let passed = RouteText.startBy(points, pace: pace, marginMinutes: 30, forMs: late, zone: utc, clock: clock, finish: finish)
        XCTAssertTrue(passed.hasSuffix(" (start-by time has passed)."), passed)
        XCTAssertFalse(RouteText.daylightReady(passed))
    }

    func testBatteryAndWeatherChecks() {
        XCTAssertEqual(RouteText.batteryThreshold(planningMinutes: 60), 30)
        XCTAssertEqual(RouteText.batteryThreshold(planningMinutes: 300), 70)
        XCTAssertEqual(RouteText.batteryDetail(level: 80, charging: true, threshold: 70), "80%, charging; aim for at least 70% for this walk")
        XCTAssertEqual(RouteText.batteryDetail(level: -1, charging: false, threshold: 30), "Battery level unavailable")

        let now: Int64 = 1_700_000_000_000
        let high = HighPoint(position: LatLon(54.5, -3.0), eleM: 900, minutesFromStart: 100)
        func hour(_ t: Int64, gust: Double = 20) -> ForecastHour {
            ForecastHour(timeMs: t, temperatureC: 8, feelsLikeC: 5, windKmh: 10, gustKmh: gust, windFromDeg: 270, rainChancePct: 10,
                         rainMm: 0, lowCloudPct: 20, visibilityM: 20_000, freezingLevelM: 2000)
        }
        let at = now + 120 * 60_000
        XCTAssertEqual(RouteText.weatherCheck(high: nil, forecast: nil, nowMs: now, imperial: false).detail,
                       "No high point forecast; check conditions yourself")
        XCTAssertEqual(RouteText.weatherCheck(high: high, forecast: nil, nowMs: now, imperial: false).detail, "No forecast saved")
        XCTAssertEqual(RouteText.weatherCheck(high: high, forecast: PointForecast(fetchedMs: now - 7 * 3_600_000, hours: [hour(at)]),
                                              nowMs: now, imperial: false).detail, "Saved forecast is over 6 hours old")
        XCTAssertEqual(RouteText.weatherCheck(high: high, forecast: PointForecast(fetchedMs: now, hours: [hour(now)]), nowMs: now,
                                              imperial: false).detail, "Forecast does not cover the planned high point time")
        let windy = RouteText.weatherCheck(high: high, forecast: PointForecast(fetchedMs: now, hours: [hour(at, gust: 85)]), nowMs: now, imperial: false)
        XCTAssertEqual(windy.detail, "Gusts of 85 km/h: dangerous on exposed ground. Consider a lower route.")
        XCTAssertFalse(windy.ready)
        let fine = RouteText.weatherCheck(high: high, forecast: PointForecast(fetchedMs: now - 3_600_000, hours: [hour(at)]), nowMs: now, imperial: false)
        XCTAssertEqual(fine.detail, "Saved forecast is fresh")
        XCTAssertTrue(fine.ready)
    }

    func testMapCheckWording() throws {
        let sources = TileSources.builtIns()
        let os = try XCTUnwrap(sources.first { $0.id == TileSources.osOutdoor })
        let leisure = try XCTUnwrap(sources.first { $0.id == TileSources.osLeisure })
        let osm = try XCTUnwrap(sources.first { $0.id == TileSources.osm })
        let stamp: (Int64) -> String = { "t\($0)" }
        func check(_ s: TileSource, _ signal: Bool, _ coverage: Int?, _ until: Int64?) -> (String, Bool) {
            let c = RouteText.mapCheck(source: s, needsSignal: signal, coverage: coverage, untilMs: until, nowMs: 10, dateTime: stamp)
            return (c.detail, c.ready)
        }
        XCTAssertEqual(check(os, false, nil, nil).0, "Checking saved tiles…")
        XCTAssertEqual(check(os, false, 100, nil).0, "Covered at pack detail")
        XCTAssertTrue(check(os, false, 100, nil).1)
        XCTAssertEqual(check(os, false, 40, nil).0, "Partly covered (40%)")
        XCTAssertFalse(check(os, false, 40, nil).1)
        XCTAssertEqual(check(os, false, 0, nil).0, "Not covered")
        XCTAssertEqual(check(leisure, false, 100, 20).0, "OS detail covered until t20")
        XCTAssertTrue(check(leisure, false, 100, 20).1)
        XCTAssertEqual(check(leisure, false, 100, 5).0, "OS detail expired; reload for today's walk")
        XCTAssertFalse(check(leisure, false, 100, 5).1)
        XCTAssertEqual(check(osm, true, nil, nil).0, "OpenStreetMap (online) needs signal")
        XCTAssertFalse(check(osm, true, 100, nil).1)
    }

    func testCheckInAndLocationLines() {
        let clock: (Int64) -> String = { "at\($0)" }
        let a = RouteText.checkInDetail(dueMs: 100, nowMs: 50, contact: true, alerts: true, clock: clock)
        XCTAssertEqual(a.detail, "Check-in at100 · contact saved")
        XCTAssertTrue(a.ready)
        let b = RouteText.checkInDetail(dueMs: 40, nowMs: 50, contact: false, alerts: false, clock: clock)
        XCTAssertEqual(b.detail, "Check-in overdue · contact missing · notifications off")
        XCTAssertFalse(b.ready)
        XCTAssertEqual(RouteText.checkInDetail(dueMs: 0, nowMs: 50, contact: true, alerts: true, clock: clock).detail, "No check-in set · contact saved")
        XCTAssertEqual(RouteText.locationDetail(location: true, alerts: true), "Location and notifications ready")
        XCTAssertEqual(RouteText.locationDetail(location: false, alerts: true), "Location permission or services off; alerts allowed")
        XCTAssertEqual(RouteText.locationDetail(location: true, alerts: false), "Location ready; allow notifications")
    }

    func testBngTilesMatchTheOsGrid() {
        // New Fancy View is in Leisure_27700 zoom 9 tile 1342/2604 (as in TileCoverageTests).
        let g = OsGrid.project(LatLon(51.78340, -2.53921))
        XCTAssertEqual(RouteText.bngTile(g, 9), TileKey(9, 1342, 2604))
        XCTAssertEqual(RouteText.bngTile(g, 5), TileKey(5, 1342 >> 4, 2604 >> 4))
    }
}
