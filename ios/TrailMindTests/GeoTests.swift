import XCTest
@testable import TrailMind

final class GeoTests: XCTestCase {
    func testWebMercatorMetresRoundTrip() {
        // Offa's Dyke Path's southern end at Sedbury Cliffs, as Waymarked Trails reports it.
        let p = WebMercator.fromMetres(-294810.17, 6733952.16)
        XCTAssertEqual(51.633, p.lat, accuracy: 0.002)
        XCTAssertEqual(-2.648, p.lon, accuracy: 0.002)
        let (x, y) = WebMercator.toMetres(p)
        XCTAssertEqual(-294810.17, x, accuracy: 0.01)
        XCTAssertEqual(6733952.16, y, accuracy: 0.01)
        XCTAssertEqual(20_037_508.34, WebMercator.toMetres(LatLon(0.0, 180.0)).x, accuracy: 0.01)
    }

    func testPathJoinOrientsAndChainsPieces() {
        func pt(_ lon: Double) -> TrackPoint { TrackPoint(lat: 54.0, lon: lon) }
        let a = [pt(0.000), pt(0.001)]
        let bReversed = [pt(0.003), pt(0.002), pt(0.001)]
        XCTAssertEqual([0.000, 0.001, 0.002, 0.003], PathJoin.join([a, bReversed]).map { $0.lon })
        // A first piece stored backwards is flipped so the line does not start with a jump.
        XCTAssertEqual([0.000, 0.001, 0.002, 0.003], PathJoin.join([a.reversed(), [pt(0.002), pt(0.003)]]).map { $0.lon })
        // Unordered sections are chained nearest end first.
        let far = [pt(0.010), pt(0.011)]
        let near = [pt(0.002), pt(0.003)]
        XCTAssertEqual([0.000, 0.001, 0.002, 0.003, 0.010, 0.011], PathJoin.join([a, far, near], ordered: false).map { $0.lon })
        // Ordered sections keep their order and are only flipped.
        XCTAssertEqual([0.000, 0.001, 0.010, 0.011, 0.003, 0.002], PathJoin.join([a, far, near]).map { $0.lon })
    }

    func testHaversineMatchesKnownDistance() {
        // Snowdon summit to Pen-y-Pass car park ≈ 3.66 km straight line.
        let d = Geo.distanceM(LatLon(53.0685, -4.0763), LatLon(53.0806, -4.0269))
        XCTAssertEqual(3_550.0, d, accuracy: 150.0)
        XCTAssertEqual(0.0, Geo.distanceM(LatLon(1.0, 1.0), LatLon(1.0, 1.0)), accuracy: 1e-9)
    }

    func testBearingsAndCardinals() {
        XCTAssertEqual(0.0, Geo.bearingDeg(LatLon(50.0, 0.0), LatLon(51.0, 0.0)), accuracy: 1e-6)
        XCTAssertEqual(90.0, Geo.bearingDeg(LatLon(0.0, 0.0), LatLon(0.0, 1.0)), accuracy: 1e-6)
        XCTAssertEqual("N", Geo.cardinal(359.0))
        XCTAssertEqual("SW", Geo.cardinal(225.0))
        XCTAssertEqual(-20.0, Geo.angleDiffDeg(10.0, 350.0), accuracy: 1e-9)
    }

    func testDestinationRoundTrip() {
        let start = LatLon(54.45, -3.21)
        let dest = Geo.destination(start, bearingDeg: 45.0, distanceM: 1000.0)
        XCTAssertEqual(1000.0, Geo.distanceM(start, dest), accuracy: 0.5)
        XCTAssertEqual(45.0, Geo.bearingDeg(start, dest), accuracy: 0.1)
    }

    func testSegmentProjection() {
        let a = LatLon(54.0, -3.0)
        let b = Geo.destination(a, bearingDeg: 90.0, distanceM: 1000.0)
        let mid = Geo.destination(Geo.destination(a, bearingDeg: 90.0, distanceM: 500.0), bearingDeg: 0.0, distanceM: 30.0)
        let p = Geo.projectOntoSegment(mid, a, b)
        XCTAssertEqual(0.5, p.fraction, accuracy: 0.01)
        XCTAssertEqual(30.0, p.distanceM, accuracy: 0.5)
    }

    func testWebMercatorRoundTripAndTiles() {
        let z = 14.0
        let x = WebMercator.lonToX(-3.1, z)
        let y = WebMercator.latToY(54.5, z)
        XCTAssertEqual(-3.1, WebMercator.xToLon(x, z), accuracy: 1e-9)
        XCTAssertEqual(54.5, WebMercator.yToLat(y, z), accuracy: 1e-9)
        // London at z10 is tile 511/340 (well-known value).
        XCTAssertEqual(TileKey(10, 511, 340), WebMercator.tileFor(LatLon(51.5074, -0.1278), 10))
        XCTAssertEqual(1, TileKey(1, 0, 0).tmsY)
        let box = BoundingBox(54.4, -3.3, 54.5, -3.1)
        let count = WebMercator.countTiles(box, 10, 14)
        XCTAssertTrue((50...400).contains(count), "count=\(count)")
    }

    func testOsGridProjectionMatchesOrdnanceSurveyWorkedExample() {
        // OS "A guide to coordinate systems in Great Britain", worked example (OSGB36 input).
        let lat = 52.0 + 39.0 / 60 + 27.2531 / 3600
        let lon = 1.0 + 43.0 / 60 + 4.5177 / 3600
        let ref = OsGrid.projectOsgb36(LatLon(lat, lon))
        XCTAssertEqual(651409.903, ref.easting, accuracy: 0.01)
        XCTAssertEqual(313177.270, ref.northing, accuracy: 0.01)
        XCTAssertEqual("TG 51409 13177", ref.format(10))
        XCTAssertEqual("TG 514 131", ref.format(6))
    }

    func testOsGridFromWgs84IsWithinHelmertAccuracy() throws {
        // Ben Nevis summit trig point: NN 16667 71278 (OS), WGS84 ≈ 56.796891, -5.003675.
        let ref = try XCTUnwrap(OsGrid.fromWgs84(LatLon(56.796891, -5.003675)))
        XCTAssertEqual(216667.0, ref.easting, accuracy: 15.0)
        XCTAssertEqual(771278.0, ref.northing, accuracy: 15.0)
        let six = try XCTUnwrap(ref.format(6))
        XCTAssertTrue(six.hasPrefix("NN 166 77") || six.hasPrefix("NN 166 71"), six)
        XCTAssertNil(OsGrid.fromWgs84(LatLon(48.85, 2.35)), "Paris is outside the National Grid")
    }

    func testOsGridInverseMatchesOrdnanceSurveyWorkedExample() {
        let p = OsGrid.unprojectOsgb36(651409.903, 313177.270)
        XCTAssertEqual(52.0 + 39.0 / 60 + 27.2531 / 3600, p.lat, accuracy: 1e-7)
        XCTAssertEqual(1.0 + 43.0 / 60 + 4.5177 / 3600, p.lon, accuracy: 1e-7)
    }

    func testOsGridRoundTripsThroughWgs84() {
        // Forest of Dean, Ben Nevis, Westminster, John o' Groats, Land's End.
        for p in [LatLon(51.7834, -2.5392), LatLon(56.796891, -5.003675), LatLon(51.5007, -0.1246), LatLon(58.64, -3.07),
                  LatLon(50.07, -5.71)] {
            let g = OsGrid.project(p)
            let back = OsGrid.toWgs84(g.easting, g.northing)
            XCTAssertEqual(p.lat, back.lat, accuracy: 1e-7, "lat of \(p)")
            XCTAssertEqual(p.lon, back.lon, accuracy: 1e-7, "lon of \(p)")
        }
    }

    func testGridLetters() {
        XCTAssertEqual("SV", OsGrid.letters(0.0, 0.0))
        XCTAssertEqual("NN", OsGrid.letters(216667.0, 771278.0))
        XCTAssertEqual("SD", OsGrid.letters(350000.0, 450000.0))
        XCTAssertNil(OsGrid.letters(-1.0, 0.0))
    }

    func testParseGridReferences() throws {
        let reference = try XCTUnwrap(OsGrid.parse("SO 628 094"))
        XCTAssertEqual(362850.0, reference.easting)
        XCTAssertEqual(209450.0, reference.northing)
        XCTAssertEqual(100, reference.precisionM)
        XCTAssertEqual(reference, OsGrid.parse("so628094"))
        XCTAssertEqual(1, try XCTUnwrap(OsGrid.parse("SO 62800 09400")).precisionM)
        XCTAssertEqual(1000, try XCTUnwrap(OsGrid.parse("SO6209")).precisionM)
        XCTAssertEqual(100000, try XCTUnwrap(OsGrid.parse("SO")).precisionM)
        for invalid in ["SI 628 094", "SO62809", "SO123456789012", "ZZ", "SO 12 X4"] { XCTAssertNil(OsGrid.parse(invalid)) }
        for east in 0...6 {
            for north in 0...12 {
                let letters = try XCTUnwrap(OsGrid.letters(Double(east) * 100_000.0, Double(north) * 100_000.0))
                let square = try XCTUnwrap(OsGrid.parse(letters))
                XCTAssertEqual(Double(east) * 100_000.0 + 50_000, square.easting)
                XCTAssertEqual(Double(north) * 100_000.0 + 50_000, square.northing)
                XCTAssertFalse(letters.contains("I"))
            }
        }
        for digits in [2, 4, 6, 8, 10] {
            let formatted = try XCTUnwrap(OsGridRef(362800.0, 209400.0).format(digits))
            let parsed = try XCTUnwrap(OsGrid.parse(formatted))
            XCTAssertEqual(formatted, OsGridRef(parsed.easting, parsed.northing).format(digits))
        }
    }

    func testParseDecimalCoordinates() {
        let point = LatLon(51.7834, -2.5392)
        for input in ["51.7834, -2.5392", "51.7834 -2.5392", "51.7834N 2.5392W"] {
            XCTAssertEqual(point, PlaceQuery.coordinates(input))
        }
        for input in ["91, 0", "0 -181", "51.5N -2W", "51.5 2.1 3", "hello", "NaN, 0"] {
            XCTAssertNil(PlaceQuery.coordinates(input))
        }
        XCTAssertTrue(PlaceQuery.looksLikeCoordinates("91, 0"))
        XCTAssertTrue(PlaceQuery.looksLikeGrid("SI 123 456"))
        XCTAssertTrue(PlaceQuery.looksLikeGrid("SO 12345"))
        XCTAssertFalse(PlaceQuery.looksLikeGrid("Speech House"))
        XCTAssertFalse(PlaceQuery.looksLikeCoordinates("GL15 4HS"))
    }

    func testSunsetInLondonMidsummer() throws {
        #if CORE_PORTS_MERGED
        let t = Sun.times(date(2025, 6, 21), LatLon(51.5074, -0.1278))
        let set = at(try XCTUnwrap(t.sunsetMs), utc)
        // Actual: 20:21 UTC (21:21 BST).
        let minutes = set.hour! * 60 + set.minute!
        XCTAssertTrue(abs(minutes - (20 * 60 + 21)) <= 5, "sunset was \(set)")
        let rise = at(try XCTUnwrap(t.sunriseMs), utc)
        XCTAssertTrue(abs(rise.hour! * 60 + rise.minute! - (3 * 60 + 43)) <= 5, "sunrise was \(rise)")
        #else
        throw XCTSkip(Self.needsSun)
        #endif
    }

    func testLondonSeptemberSunsetAndCivilDusk() throws {
        #if CORE_PORTS_MERGED
        let times = Sun.times(date(2026, 9, 26), LatLon(51.5074, -0.1278))
        let sunset = try XCTUnwrap(times.sunsetMs)
        let dusk = try XCTUnwrap(times.civilDuskMs)
        // US Naval Observatory: London 18:50 sunset, 19:23 civil dusk (BST).
        XCTAssertEqual([2026, 9, 26], localDate(sunset))
        XCTAssertEqual([2026, 9, 26], localDate(dusk))
        XCTAssertTrue(abs(minutes(sunset) - (18 * 60 + 50)) <= 1, "sunset \(minutes(sunset))")
        XCTAssertTrue(abs(minutes(dusk) - (19 * 60 + 23)) <= 1, "dusk \(minutes(dusk))")
        #else
        throw XCTSkip(Self.needsSun)
        #endif
    }

    func testForestOfDeanAndLerwickCivilDusk() throws {
        #if CORE_PORTS_MERGED
        let forest = Sun.times(date(2026, 9, 26), LatLon(51.78, -2.54))
        XCTAssertTrue(abs(minutes(try XCTUnwrap(forest.sunsetMs)) - (19 * 60 + 2)) <= 4)
        XCTAssertTrue(abs(minutes(try XCTUnwrap(forest.civilDuskMs)) - (19 * 60 + 33)) <= 3)
        let lydney = Sun.times(date(2026, 9, 26), LatLon(51.73, -2.53))
        // US Naval Observatory at 51.73 N, 2.53 W: sunset 18:59, civil dusk 19:33 BST.
        let lydneySunset = try XCTUnwrap(lydney.sunsetMs)
        let lydneyDusk = try XCTUnwrap(lydney.civilDuskMs)
        XCTAssertTrue(abs(minutes(lydneySunset) - (18 * 60 + 59)) <= 1, "Lydney sunset \(minutes(lydneySunset))")
        XCTAssertTrue(abs(minutes(lydneyDusk) - (19 * 60 + 33)) <= 1, "Lydney dusk \(minutes(lydneyDusk))")
        let lerwick = Sun.times(date(2026, 6, 21), LatLon(60.155, -1.145))
        XCTAssertTrue(abs(minutes(try XCTUnwrap(lerwick.sunsetMs)) - (22 * 60 + 34)) <= 5)
        let lerwickDusk = try XCTUnwrap(lerwick.civilDuskMs)
        XCTAssertEqual([2026, 6, 22], localDate(lerwickDusk))
        XCTAssertTrue(abs(minutes(lerwickDusk) - 26) <= 5)
        #else
        throw XCTSkip(Self.needsSun)
        #endif
    }

    #if CORE_PORTS_MERGED
    private let utc = TimeZone(identifier: "UTC")!
    private let london = TimeZone(identifier: "Europe/London")!

    /// `LocalDate.of(year, month, day)`, as `Sun.times` takes it.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> DateComponents {
        DateComponents(year: year, month: month, day: day)
    }

    /// `Instant.ofEpochMilli(ms).atZone(zone)`.
    private func at(_ ms: Int64, _ zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// Minutes past midnight in London.
    private func minutes(_ ms: Int64) -> Int {
        let local = at(ms, london)
        return local.hour! * 60 + local.minute!
    }

    /// The London date, as year, month and day.
    private func localDate(_ ms: Int64) -> [Int] {
        let local = at(ms, london)
        return [local.year!, local.month!, local.day!]
    }
    #else
    private static let needsSun = "Needs Sun (geo/Sun.kt), which the port/core-stats branch ports: drop the #if once merged"
    #endif

    // Lydney: about 49.2 µT, dipping 66.3°. In east/north/up that is (0, 19.8, -45.1).
    func testMagneticCheckAcceptsTheEarthsFieldFlatOrUpright() {
        let flat = MagneticCheck()
        flat.expect(49.2, 66.3)
        for _ in 0..<10 { flat.add(0.0, 19.8, -45.1, 0.0, 0.0, 1.0) }
        XCTAssertFalse(flat.disturbed)
        // Upright with the back facing north: device y is up and z faces south.
        let upright = MagneticCheck()
        upright.expect(49.2, 66.3)
        for _ in 0..<10 { upright.add(0.0, -45.1, -19.8, 0.0, 1.0, 0.0) }
        XCTAssertFalse(upright.disturbed)
        XCTAssertEqual(66.3, upright.dipDeg, accuracy: 0.5)
    }

    func testMagneticCheckFlagsRealReadingsThatReportedNoProblem() {
        // Fold7 on a desk, reporting itself fully calibrated: a plausible dip, but 86 µT.
        let phone = MagneticCheck()
        phone.expect(49.2, 66.3)
        for _ in 0..<5 { phone.add(32.64, -24.71, -75.32, -0.0366, 0.0202, 0.9991) }
        XCTAssertTrue(phone.disturbed)
        XCTAssertEqual(63.8, phone.dipDeg, accuracy: 0.5)
        // Watch4 face up on its magnetic charger: a plausible strength, but the field points up.
        let watch = MagneticCheck()
        watch.expect(49.2, 66.3)
        for _ in 0..<5 { watch.add(-9.72, 32.10, 46.80, 0.0, 0.0, 1.0) }
        XCTAssertTrue(watch.disturbed)
    }

    func testMagneticCheckWaitsForAPositionAndClearsOnceTheFieldIsClean() {
        let c = MagneticCheck()
        for _ in 0..<5 { c.add(32.64, -24.71, -75.32, 0.0, 0.0, 1.0) }
        XCTAssertFalse(c.disturbed, "nothing to compare with before a GPS fix")
        c.expect(49.2, 66.3)
        c.add(32.64, -24.71, -75.32, 0.0, 0.0, 1.0)
        XCTAssertTrue(c.disturbed)
        for _ in 0..<30 { c.add(0.0, 19.8, -45.1, 0.0, 0.0, 1.0) }
        XCTAssertFalse(c.disturbed)
    }

    // Row-major rotation matrices for a device lying flat whose top points `azimuthDeg` in the rotation vector's frame.
    private func flat(_ azimuthDeg: Double) -> [Float] {
        let a = toRadians(azimuthDeg)
        let s = Float(sin(a))
        let c = Float(cos(a))
        return [c, s, 0, -s, c, 0, 0, 0, 1]
    }

    func testNorthAnchorLeavesACorrectRotationVectorAlone() {
        let n = NorthAnchor()
        XCTAssertEqual(0.0, n.offsetDeg)
        // Flat, pointing magnetic north, and the rotation vector agrees: the field lies along the device's y.
        n.add(flat(0.0), 0.0, 19.8, -45.1)
        XCTAssertEqual(0.0, n.offsetDeg, accuracy: 0.01)
    }

    func testNorthAnchorCorrectsARotationVectorWhoseNorthIsOff() {
        // The watch points magnetic north, but a gyro-only rotation vector started 90 degrees off says east.
        let r = flat(90.0)
        let n = NorthAnchor()
        n.add(r, 0.0, 19.8, -45.1)
        let azimuth = toDegrees(atan2(Double(r[1]), Double(r[4])))
        XCTAssertEqual(90.0, azimuth, accuracy: 0.01)
        XCTAssertEqual(0.0, Geo.normalizeDeg(azimuth - n.offsetDeg), accuracy: 0.01)
        // Smoothing works across 180: readings of 170 and 190 average to 180, not 0.
        let w = NorthAnchor()
        for i in 0..<200 { w.add(flat(i % 2 == 0 ? 170.0 : 190.0), 0.0, 19.8, -45.1) }
        XCTAssertEqual(180.0, abs(w.offsetDeg), accuracy: 3.0)
    }
}
