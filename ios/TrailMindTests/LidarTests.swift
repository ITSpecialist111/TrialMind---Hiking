import XCTest
@testable import TrailMind

final class LidarTests: XCTestCase {
    private func resource(_ name: String) throws -> [UInt8] {
        let dot = try XCTUnwrap(name.lastIndex(of: "."))
        let base = String(name[..<dot])
        let ext = String(name[name.index(after: dot)...])
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: LidarTests.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/lidar")
            ?? bundle.url(forResource: base, withExtension: ext), "missing \(name)")
        return [UInt8](try Data(contentsOf: url))
    }

    func testReadsEnvironmentAgencyGeoTiff() throws {
        // A 32 m window on Helvellyn as the service sends it: big-endian, tiled, Deflate, GDAL no-data tag.
        let raster = try GeoTiff.read(try resource("helvellyn-32.tif"))
        XCTAssertEqual(raster.width, 32)
        XCTAssertEqual(raster.height, 32)
        XCTAssertEqual(raster.left, 334400.0, accuracy: 1e-6)
        XCTAssertEqual(raster.top, 515132.0, accuracy: 1e-6)
        XCTAssertEqual(raster.pixelWidth, 1.0, accuracy: 1e-9)
        XCTAssertEqual(raster.pixelHeight, 1.0, accuracy: 1e-9)
        XCTAssertEqual(Double(raster.values[0]), 830.788, accuracy: 0.005)
        XCTAssertEqual(Double(raster.values[31 * 32 + 31]), 849.97, accuracy: 0.005)
        XCTAssertTrue(raster.values.allSatisfy { (818...868).contains($0) })
    }

    func testSquareOutsideCoverageReadsAsNoData() throws {
        // Snowdon is in Wales: the service fills the square with 0.0 and no no-data tag.
        let raster = try GeoTiff.read(try resource("snowdon-empty.tif"))
        XCTAssertEqual(raster.width, 256)
        XCTAssertEqual(raster.left, 260864.0, accuracy: 1e-6)
        XCTAssertEqual(raster.top, 354560.0, accuracy: 1e-6)
        XCTAssertFalse(Lidar.clean(&raster.values))
        XCTAssertTrue(raster.values.allSatisfy { $0.isNaN })
        var helvellyn = try GeoTiff.read(try resource("helvellyn-32.tif")).values
        XCTAssertTrue(Lidar.clean(&helvellyn))
        XCTAssertFalse(helvellyn.contains { $0.isNaN })
    }

    func testReadsLittleEndianStripsUncompressedAndDeflated() throws {
        let values: [Float] = [1, 2, 3, -9999, 5, 6]
        for deflate in [false, true] {
            let raster = try GeoTiff.read(tiff(3, 2, values, .littleEndian, deflate, "-9999"))
            XCTAssertEqual(raster.width, 3)
            XCTAssertEqual(raster.height, 2)
            XCTAssertEqual(raster.left, 1000.0, accuracy: 1e-9)
            XCTAssertEqual(raster.top, 2004.0, accuracy: 1e-9)
            XCTAssertEqual(raster.pixelWidth, 2.0, accuracy: 1e-9)
            XCTAssertEqual(Array(raster.values.prefix(3)), [1, 2, 3])
            XCTAssertTrue(raster.values[3].isNaN)
            XCTAssertEqual(raster.values[5], 6)
        }
    }

    func testRefusesWhatItCannotRead() {
        XCTAssertThrowsError(try GeoTiff.read([1, 2, 3] as [UInt8])) { XCTAssertTrue($0 is GeoTiffError, "\($0)") }
        XCTAssertThrowsError(try GeoTiff.read(tiff(2, 1, [1, 2], .bigEndian, false, nil, bits: 16))) {
            XCTAssertTrue($0 is GeoTiffError, "\($0)")
        }
        let good = tiff(2, 1, [1, 2], .bigEndian, false, nil)
        XCTAssertThrowsError(try GeoTiff.read(Array(good.prefix(good.count - 4)))) { XCTAssertTrue($0 is GeoTiffError, "\($0)") }
    }

    func testSquaresAlongARouteStayInTheExtent() {
        XCTAssertEqual(Lidar.squareAt(334400.0, 515100.0), Lidar.Square(1306, 2012))
        XCTAssertTrue(Lidar.Square(1306, 2012).inExtent)
        XCTAssertFalse(Lidar.squareAt(216666.0, 771275.0).inExtent) // Ben Nevis, beyond the composite
        let route = [OsGridRef(334000.0, 515000.0), OsGridRef(334600.0, 515000.0)]
        let squares = Lidar.corridor(route, 20.0)
        XCTAssertEqual(squares.map { $0.col }, [1304, 1305, 1306, 1307])
        XCTAssertTrue(squares.allSatisfy { $0.row == 2011 })
        XCTAssertEqual(Lidar.corridor(route, 100.0).count, 8)
        XCTAssertNil(Lidar.box(0.0, 0.0, 700_000.0, 700_000.0, 100))
        XCTAssertEqual(Lidar.box(334000.0, 515000.0, 334500.0, 515300.0, 100)?.count, 6)
    }

    func testHeightIsInterpolatedBetweenPixelCentres() throws {
        let square = Lidar.Square(1305, 2012)
        var values = (0..<(Lidar.size * Lidar.size)).map { i in Float(i % Lidar.size) } // rises 1 m per metre east
        XCTAssertEqual(try XCTUnwrap(Lidar.height(values, square, Double(square.east) + 10.5, Double(square.north) + 100.0)),
                       10.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(Lidar.height(values, square, Double(square.east) + 10.75, Double(square.north) + 100.0)),
                       10.25, accuracy: 1e-6)
        values = [Float](repeating: .nan, count: values.count)
        XCTAssertNil(Lidar.height(values, square, Double(square.east) + 10.5, Double(square.north) + 100.0))
    }

    func testHillShadingIsLitFromTheNorthWest() {
        let level = Lidar.shade(0, 0)
        XCTAssertEqual(Double(level), 0.7071, accuracy: 1e-3)
        // A slope rising to the east faces west, a slope rising to the north faces south (rows run south).
        XCTAssertTrue(Lidar.shade(1, 0) > level)
        XCTAssertTrue(Lidar.shade(0, -1) < level)
        XCTAssertTrue(Lidar.shade(1, 1) > Lidar.shade(-1, -1))
    }

    func testCragsNeedSteepGroundAndRealHeight() {
        // A 10 m cliff between columns 99 and 101, a 1 m bank at column 200, and a 30° slope on rows 0..40.
        let heights = (0..<(Lidar.size * Lidar.size)).map { i -> Float in
            let row = i / Lidar.size
            let col = i % Lidar.size
            var h: Float = 100
            if col >= 100 { h += 10 }
            if col >= 200 { h += 1 }
            if row < 40 { h += Float(40 - row) * 0.577 }
            return h
        }
        let padded = Lidar.padded(heights) { _, _ in nil }
        let crags = Lidar.crags(padded)
        func at(_ row: Int, _ col: Int) -> Bool { crags[row * Lidar.size + col] }
        XCTAssertTrue(at(128, 99) || at(128, 100))
        XCTAssertFalse(at(128, 200) || at(128, 199))
        XCTAssertFalse(at(20, 50))
        XCTAssertFalse(at(128, 50))
        let colours = Lidar.overlay(padded, crags)
        XCTAssertEqual(colours[128 * Lidar.size + (at(128, 99) ? 99 : 100)], Lidar.cragColour)
        XCTAssertEqual(colours[128 * Lidar.size + 50] >> 24, 0) // level ground stays clear
        XCTAssertTrue(colours[20 * Lidar.size + 50] >> 24 > 0) // the slope is shaded
    }

    func testPaddingUsesNeighboursAndRepeatsMissingEdges() {
        let centre = [Float](repeating: 1, count: Lidar.size * Lidar.size)
        let east = [Float](repeating: 5, count: Lidar.size * Lidar.size)
        let padded = Lidar.padded(centre) { dx, dy in dx == 1 && dy == 0 ? east : nil }
        let stride = Lidar.size + 2 * Lidar.border
        let midRow = (Lidar.border + 100) * stride
        XCTAssertEqual(padded[midRow + stride - 1], 5)
        XCTAssertEqual(padded[midRow], 1)
        XCTAssertEqual(padded[0], 1)
        let wide = Lidar.padded(centre, border: LidarReveal.border) { dx, dy in dx == 1 && dy == 0 ? east : nil }
        let wideStride = Lidar.size + 2 * LidarReveal.border
        let wideRow = (LidarReveal.border + 100) * wideStride
        XCTAssertEqual(wide.count, wideStride * wideStride)
        XCTAssertEqual(wide[wideRow + wideStride - 1], 5)
        XCTAssertEqual(wide[wideRow + LidarReveal.border + Lidar.size], 5)
        XCTAssertEqual(wide[wideRow + LidarReveal.border + Lidar.size - 1], 1)
    }

    // A level square at 100 m with a 2 m deep, 6 m wide ditch across rows 126...131 and a 1 m high bank on rows 160...163.
    private func earthworks() -> [Float] {
        (0..<(Lidar.size * Lidar.size)).map { i in
            let row = i / Lidar.size
            return (126...131).contains(row) ? 98 : (160...163).contains(row) ? 101 : 100
        }
    }

    private func grey(_ argb: UInt32) -> Int {
        XCTAssertEqual(argb >> 24, 0xFF, "reveal pictures are opaque")
        XCTAssertEqual(argb >> 16 & 0xFF, argb & 0xFF)
        XCTAssertEqual(argb >> 8 & 0xFF, argb & 0xFF)
        return Int(argb & 0xFF)
    }

    func testRevealShowsDitchesDarkAndBanksLightInEveryStyle() {
        let padded = Lidar.padded(earthworks(), border: LidarReveal.border) { _, _ in nil }
        for style in LidarReveal.Style.allCases {
            let pixels = LidarReveal.render(padded, style)
            func pixel(_ row: Int) -> Int { grey(pixels[row * Lidar.size + 128]) }
            let level = pixel(30)
            let ditch = (124...133).map { pixel($0) }
            if style == .hillshade {
                XCTAssertTrue(ditch.contains { abs($0 - level) > 20 }, "\(style): the ditch walls are shaded")
            } else {
                XCTAssertTrue(ditch.min()! < level - 20, "\(style): the ditch is darker than level ground")
            }
            if style == .slrm { XCTAssertTrue(pixel(162) > level + 10, "\(style): the bank is lighter") }
        }
    }

    func testRevealOfLevelGroundIsEvenAndLeavesTheMapShowingWhereThereAreNoHeights() {
        var heights = [Float](repeating: 50, count: Lidar.size * Lidar.size)
        for i in 0..<(40 * Lidar.size) { heights[i] = .nan }
        let padded = Lidar.padded(heights, border: LidarReveal.border) { _, _ in nil }
        for style in LidarReveal.Style.allCases {
            let pixels = LidarReveal.render(padded, style)
            XCTAssertEqual(pixels[10 * Lidar.size + 100], 0, "\(style): no survey, nothing drawn")
            let level = grey(pixels[200 * Lidar.size + 100])
            XCTAssertEqual(level, grey(pixels[150 * Lidar.size + 30]))
            XCTAssertTrue((100...255).contains(level))
        }
    }

    func testSkyViewIsOneOnLevelGroundAndLessInAHollow() {
        let stride = Lidar.size + 2 * LidarReveal.border
        let padded = Lidar.padded(earthworks(), border: LidarReveal.border) { _, _ in nil }
        func at(_ row: Int) -> Float { LidarReveal.skyView(padded, (row + LidarReveal.border) * stride + 128 + LidarReveal.border, stride) }
        XCTAssertEqual(at(30), 1, accuracy: 1e-6)
        XCTAssertTrue(at(128) < 0.9)
        XCTAssertTrue(at(162) > at(128))
    }

    func testRevealStyleIdsRoundTripAndDefaultToSkyView() {
        for style in LidarReveal.Style.allCases { XCTAssertEqual(LidarReveal.Style.of(style.id), style) }
        XCTAssertEqual(LidarReveal.Style.of(nil), .svf)
        XCTAssertEqual(LidarReveal.Style.of("nonsense"), .svf)
    }

    /// `LidarRouteCheck.Ground` from closures, standing in for Kotlin's anonymous objects.
    private struct Ground: LidarRouteCheck.Ground {
        let heightAt: (Double, Double) -> Double?
        let cragAt: (Double, Double) -> Bool

        func height(_ easting: Double, _ northing: Double) -> Double? { heightAt(easting, northing) }

        func crag(_ easting: Double, _ northing: Double) -> Bool { cragAt(easting, northing) }
    }

    func testRouteCheckFindsSteepGroundAndCragsBesideTheLine() throws {
        let e0 = 334_000.0
        let n0 = 515_000.0
        let route = [OsGrid.toWgs84(e0, n0), OsGrid.toWgs84(e0 + 300, n0)]
        let ground = Ground(heightAt: { easting, _ in
            if easting > e0 + 280 { return nil }
            if easting < e0 + 100 { return 100.0 }
            if easting < e0 + 120 { return 100.0 + (easting - e0 - 100) } // 45° for 20 m
            return 120.0
        }, cragAt: { easting, northing in abs(easting - (e0 + 200)) <= 1.5 && abs(northing - (n0 + 6)) < 0.5 })
        let report = LidarRouteCheck.check(route, ground)
        XCTAssertEqual(report.lengthM, 300.0, accuracy: 0.5)
        XCTAssertEqual(report.coveredM, 280.0, accuracy: 2.0)
        XCTAssertEqual(report.steep.count, 1)
        let steep = try XCTUnwrap(report.steep.first)
        XCTAssertTrue((88.0...102.0).contains(steep.startM) && (118.0...132.0).contains(steep.endM), "\(steep)")
        XCTAssertEqual(steep.value, 45.0, accuracy: 1.0)
        XCTAssertEqual(report.crags.count, 1)
        let crag = try XCTUnwrap(report.crags.first)
        XCTAssertTrue((190.0...204.0).contains(crag.startM), "\(crag)")
        XCTAssertEqual(crag.value, 6.0, accuracy: 1.1)
        XCTAssertNotNil(crag.at)
    }

    func testLevelRouteHasNothingToReport() {
        let route = [LatLon(54.5, -3.0), OsGrid.toWgs84(OsGrid.project(LatLon(54.5, -3.0)).easting + 500,
                                                        OsGrid.project(LatLon(54.5, -3.0)).northing)]
        let report = LidarRouteCheck.check(route, Ground(heightAt: { easting, _ in 200.0 + easting * 0.1 }, // about 6°
                                                         cragAt: { _, _ in false }))
        XCTAssertTrue(report.steep.isEmpty && report.crags.isEmpty)
        XCTAssertEqual(report.coveredM, report.lengthM, accuracy: 1e-6)
    }

    func testRouteIsSampledEveryMetreAndCragsAreFoundBesideGapsInTheSurvey() throws {
        let e0 = 334_000.0
        let n0 = 515_000.0
        // Points 1.9 m apart, as a recorded track can have.
        let route = (0...10).map { OsGrid.toWgs84(e0 + Double($0) * 1.9, n0) }
        var sampled: [Double] = []
        _ = LidarRouteCheck.check(route, Ground(heightAt: { easting, _ in
            sampled.append(easting)
            return 100.0
        }, cragAt: { _, _ in false }))
        XCTAssertTrue(zip(sampled, sampled.dropFirst()).allSatisfy { a, b in b - a <= 1.05 }, "\(sampled)")
        // No heights on the line itself (water, say), and a crag 5 m beside it.
        let report = LidarRouteCheck.check(route, Ground(heightAt: { _, _ in nil }, cragAt: { easting, northing in
            easting >= e0 + 9 && easting < e0 + 10 && (n0 + 4.5...n0 + 5.5).contains(northing)
        }))
        XCTAssertEqual(report.coveredM, 0.0)
        XCTAssertEqual(report.crags.count, 1)
        XCTAssertEqual(try XCTUnwrap(report.crags.first).value, 5.0, accuracy: 0.2)
    }

    func testEdgeSquaresArePlacedWhereTheServiceClipsThem() throws {
        let square = Lidar.Square(312, 40) // straddles the survey's west edge at E 80,000
        let top = Double(square.north) + 256.0
        let whole = GeoTiff.Raster(width: 256, height: 256, values: [Float](repeating: 5, count: 256 * 256),
                                   left: Double(square.east), top: top, pixelWidth: 1.0, pixelHeight: 1.0)
        // The whole square is used as it is, not copied (Kotlin checks it is the same array).
        let placed = try XCTUnwrap(Lidar.place(whole, square))
        XCTAssertEqual(placed.withUnsafeBufferPointer { $0.baseAddress }, whole.values.withUnsafeBufferPointer { $0.baseAddress })
        // At the west edge the service sends only the 128 columns from E 80,000.
        let west = try XCTUnwrap(Lidar.place(GeoTiff.Raster(width: 128, height: 256, values: [Float](repeating: 7, count: 128 * 256),
                                                            left: 80_000.0, top: top, pixelWidth: 1.0, pixelHeight: 1.0), square))
        XCTAssertTrue(west[0].isNaN && west[255 * 256 + 127].isNaN)
        XCTAssertEqual(west[128], 7)
        XCTAssertEqual(west[255 * 256 + 255], 7)
        // At the north edge it sends the rows below it.
        let north = try XCTUnwrap(Lidar.place(GeoTiff.Raster(width: 256, height: 168, values: [Float](repeating: 3, count: 256 * 168),
                                                             left: Double(square.east), top: top - 88, pixelWidth: 1.0, pixelHeight: 1.0),
                                              square))
        XCTAssertTrue(north[87 * 256].isNaN)
        XCTAssertEqual(north[88 * 256], 3)
        // Anything not on the square's 1 m grid is refused.
        XCTAssertNil(Lidar.place(GeoTiff.Raster(width: 256, height: 256, values: whole.values, left: Double(square.east) + 0.5, top: top,
                                                pixelWidth: 1.0, pixelHeight: 1.0), square))
        XCTAssertNil(Lidar.place(GeoTiff.Raster(width: 128, height: 128, values: [Float](repeating: 0, count: 128 * 128),
                                                left: Double(square.east), top: top, pixelWidth: 2.0, pixelHeight: 2.0), square))
        XCTAssertNil(Lidar.place(GeoTiff.Raster(width: 256, height: 256, values: whole.values, left: Double(square.east) + 128.0, top: top,
                                                pixelWidth: 1.0, pixelHeight: 1.0), square))
    }

    private enum ByteOrder { case littleEndian, bigEndian }

    /// A one-strip, single-band float TIFF with tie point (1000, 2004) and 2 m pixels.
    private func tiff(_ width: Int, _ height: Int, _ values: [Float], _ order: ByteOrder, _ deflate: Bool, _ noData: String?,
                      bits: Int = 32) -> [UInt8] {
        func put(_ value: UInt64, _ size: Int) -> [UInt8] {
            (0..<size).map { k in UInt8(truncatingIfNeeded: value >> UInt64(8 * (order == .bigEndian ? size - 1 - k : k))) }
        }
        let pixels = values.flatMap { put(UInt64($0.bitPattern), 4) }
        let strip = deflate ? zlibCompressed(pixels) : pixels
        let ascii = noData.map { Array(($0 + "\u{0}").utf8) }
        struct Entry {
            let tag: Int
            let type: Int
            let count: Int
            var inline: Int64? = nil
            var data: [UInt8]? = nil
        }
        func doubles(_ d: Double...) -> [UInt8] { d.flatMap { put($0.bitPattern, 8) } }
        var entries = [
            Entry(tag: 256, type: 3, count: 1, inline: Int64(width)), Entry(tag: 257, type: 3, count: 1, inline: Int64(height)),
            Entry(tag: 258, type: 3, count: 1, inline: Int64(bits)), Entry(tag: 259, type: 3, count: 1, inline: deflate ? 8 : 1),
            Entry(tag: 273, type: 4, count: 1, data: strip), Entry(tag: 277, type: 3, count: 1, inline: 1),
            Entry(tag: 278, type: 3, count: 1, inline: Int64(height)), Entry(tag: 279, type: 4, count: 1, inline: Int64(strip.count)),
            Entry(tag: 339, type: 3, count: 1, inline: 3),
            Entry(tag: 33550, type: 12, count: 3, data: doubles(2.0, 2.0, 0.0)),
            Entry(tag: 33922, type: 12, count: 6, data: doubles(0.0, 0.0, 0.0, 1000.0, 2004.0, 0.0)),
        ]
        if let ascii = ascii { entries.append(Entry(tag: 42113, type: 2, count: ascii.count, data: ascii)) }
        let ifdSize = 2 + entries.count * 12 + 4
        var dataAt = 8 + ifdSize
        let offsets = entries.map { e -> Int in
            guard let data = e.data, e.tag == 273 || data.count > 4 else { return -1 }
            defer { dataAt += data.count }
            return dataAt
        }
        var out: [UInt8] = Array((order == .littleEndian ? "II" : "MM").utf8)
        out += put(42, 2) + put(8, 4)
        out += put(UInt64(entries.count), 2)
        for (i, e) in entries.enumerated() {
            out += put(UInt64(e.tag), 2) + put(UInt64(e.type), 2) + put(UInt64(e.count), 4)
            if e.tag == 273 || e.data != nil {
                out += put(UInt64(UInt32(bitPattern: Int32(offsets[i]))), 4)
            } else if e.type == 3 {
                out += put(UInt64(UInt16(truncatingIfNeeded: e.inline!)), 2) + put(0, 2)
            } else {
                out += put(UInt64(UInt32(truncatingIfNeeded: e.inline!)), 4)
            }
        }
        out += put(0, 4)
        out += [UInt8](repeating: 0, count: dataAt - out.count)
        for (i, e) in entries.enumerated() where offsets[i] >= 0 {
            out.replaceSubrange(offsets[i]..<offsets[i] + e.data!.count, with: e.data!)
        }
        return out
    }

    /// A zlib stream of `data` for the Deflate strips, standing in for `java.util.zip.Deflater`: one fixed-Huffman
    /// block of literals.
    private func zlibCompressed(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C]
        var buffer: UInt32 = 0
        var count = 0
        func write(_ value: Int, _ bits: Int) {
            buffer |= UInt32(value) << UInt32(count)
            count += bits
            while count >= 8 {
                out.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                count -= 8
            }
        }
        // Huffman codes go most significant bit first.
        func code(_ value: Int, _ length: Int) {
            for i in stride(from: length - 1, through: 0, by: -1) { write(value >> i & 1, 1) }
        }
        write(1, 1) // the last block
        write(1, 2) // fixed Huffman codes
        for byte in data {
            if byte < 144 { code(0x30 + Int(byte), 8) } else { code(0x190 + Int(byte) - 144, 9) }
        }
        code(0, 7) // end of block
        if count > 0 { out.append(UInt8(buffer & 0xFF)) }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        out += [UInt8(b >> 8), UInt8(b & 0xFF), UInt8(a >> 8), UInt8(a & 0xFF)]
        return out
    }
}
