import XCTest
@testable import TrailMind

final class BarometryTests: XCTestCase {
    func testStandardAtmosphereRoundTrips() {
        XCTAssertEqual(0.0, Barometry.altitudeM(Barometry.standardSeaLevelHpa), accuracy: 1e-6)
        XCTAssertEqual(898.7, Barometry.pressureHpa(1000.0), accuracy: 0.1)
        XCTAssertEqual(950.0, Barometry.altitudeM(Barometry.pressureHpa(950.0, 1001.3), 1001.3), accuracy: 1e-6)
        XCTAssertEqual(1001.3, Barometry.seaLevelHpa(Barometry.pressureHpa(950.0, 1001.3), 950.0), accuracy: 1e-9)
    }

    func testAltimeterFollowsTheClimbWithoutGpsNoiseOrWeatherDrift() throws {
        let alt = BaroAltimeter()
        var gpsAscent = 0.0
        var baroAscent = 0.0
        var gpsRef: Double? = nil
        var baroRef: Double? = nil
        var worst = 0.0
        // 800 m climb over an hour of 2 s fixes, while the weather drops sea-level pressure by 3 hPa.
        for i in 0...1800 {
            let truth = 150.0 + 800.0 * Double(i) / 1800
            let qnh = 1015.0 - 3.0 * Double(i) / 1800
            let gps = truth + 15.0 * sin(Double(i) * 1.7) // deterministic ±15 m GPS noise
            let p = Barometry.pressureHpa(truth, qnh)
            alt.onGps(p, gps, 8.0)
            let baro = try XCTUnwrap(alt.altitudeM(p))
            if i > 300 { worst = max(worst, abs(baro - truth)) }
            gpsRef = hysteresis(gps, gpsRef) { gpsAscent += $0 }
            baroRef = hysteresis(baro, baroRef) { baroAscent += $0 }
        }
        XCTAssertTrue(worst < 5.0, "barometric altitude within 5 m of truth (worst " + fmt("%.1f", worst) + " m)")
        XCTAssertEqual(800.0, baroAscent, accuracy: 20.0)
        XCTAssertTrue(gpsAscent > 1200.0, "GPS noise inflates ascent (\(Int(gpsAscent)) m)")
    }

    private func hysteresis(_ e: Double, _ ref: Double?, _ up: (Double) -> Void) -> Double {
        guard let ref = ref else { return e }
        if e - ref >= 4.0 { up(e - ref); return e }
        if ref - e >= 4.0 { return e }
        return ref
    }

    func testPoorFixesDoNotCalibrate() {
        let alt = BaroAltimeter()
        alt.onGps(1000.0, 100.0, 60.0)
        XCTAssertNil(alt.altitudeM(1000.0))
    }

    func testTrendNeedsHistoryThenReportsAFallingStorm() throws {
        let trend = PressureTrend()
        let minute: Int64 = 60_000
        for m in stride(from: 0, through: 120, by: 5) { trend.add(Int64(m) * minute, 1012.0 - 1.5 * Double(m) / 60.0) }
        XCTAssertEqual(PressureTrend.Tendency.unknown, trend.tendency())
        for m in stride(from: 125, through: 180, by: 5) { trend.add(Int64(m) * minute, 1012.0 - 1.5 * Double(m) / 60.0) }
        XCTAssertEqual(-4.5, try XCTUnwrap(trend.change()), accuracy: 0.01)
        XCTAssertEqual(PressureTrend.Tendency.fallingFast, trend.tendency())

        let steady = PressureTrend()
        for m in stride(from: 0, through: 240, by: 5) { steady.add(Int64(m) * minute, 1012.0 + 0.2 * sin(Double(m))) }
        XCTAssertEqual(PressureTrend.Tendency.steady, steady.tendency())
    }

    func testTracBackReversesAndThinsTheTrack() throws {
        #if CORE_PORTS_MERGED
        let recorded = (0..<10_000).map { TrackPoint(lat: 54.0 + Double($0) * 1e-5, lon: -3.0, ele: 100.0 + Double($0)) }
        let back = try XCTUnwrap(TracBack.line(recorded, maxPoints: 1000))
        XCTAssertTrue(back.count <= 1001)
        XCTAssertEqual(recorded.last!.lat, back.first!.lat)
        XCTAssertEqual(recorded.first!.lat, back.last!.lat)
        XCTAssertNil(TracBack.line(Array(recorded.prefix(1))))
        #else
        throw XCTSkip("Needs TracBack (nav/TracBack.kt), which the port/core-stats branch ports: drop this #if once merged")
        #endif
    }
}
