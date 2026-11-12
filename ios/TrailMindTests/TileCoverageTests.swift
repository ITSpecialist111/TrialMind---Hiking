import XCTest
@testable import TrailMind

final class TileCoverageTests: XCTestCase {
    func testBoxMatchesCount() {
        let box = BoundingBox(54.40, -3.20, 54.50, -3.00)
        XCTAssertEqual(WebMercator.countTiles(box, 12, 15), Int64(Array(TileCoverage.box(box, 12, 15)).count))
    }

    func testCorridorIsContiguousAndSmallerThanBox() throws {
        let start = LatLon(54.45, -3.20)
        let points = (0...40).map { Geo.destination(start, bearingDeg: 60.0, distanceM: Double($0) * 500.0) } // 20 km diagonal
        let z = 15
        let corridor = TileCoverage.corridor(points, 500.0, z)
        let box = try XCTUnwrap(BoundingBox.of(points)).expandedByMetres(500.0)
        let boxCount = WebMercator.tileRange(box, z).count
        XCTAssertTrue(Int64(corridor.count) < boxCount / 2, "corridor=\(corridor.count) box=\(boxCount)")
        // every route point's own tile is included
        points.forEach { XCTAssertTrue(corridor.contains(WebMercator.tileFor($0, z))) }
        XCTAssertEqual(Int64(corridor.count), TileCoverage.corridorCount(points, 500.0, z, z))
        XCTAssertEqual(Set(corridor).count, corridor.count)
    }

    private func edges(_ f: TileFootprint) -> [[Int]] {
        stride(from: 0, to: f.edges.count, by: 4).map { Array(f.edges[$0..<min($0 + 4, f.edges.count)]) }
    }

    private func perimeter(_ f: TileFootprint) -> Int {
        edges(f).reduce(0) { sum, e in sum + abs(e[2] - e[0]) + abs(e[3] - e[1]) }
    }

    func testFootprintOfARectangleIsOneSpanPerRowAndFourEdges() throws {
        let f = try XCTUnwrap(TileFootprint.of(16, (0..<6).map { 10 + $0 % 3 }, (0..<6).map { 20 + $0 / 3 }))
        XCTAssertEqual(f.spans, [20, 10, 13, 21, 10, 13])
        XCTAssertEqual(Set(edges(f)), [[10, 20, 13, 20], [10, 22, 13, 22], [10, 20, 10, 22], [13, 20, 13, 22]])
        XCTAssertEqual([f.minX, f.minY, f.maxX, f.maxY], [10, 20, 13, 22])
    }

    func testFootprintOutlinesAnLShapeWithoutInnerEdges() throws {
        // ##
        // #   (the last cell is listed twice)
        let f = try XCTUnwrap(TileFootprint.of(5, [0, 1, 0, 0], [0, 0, 1, 1]))
        XCTAssertEqual(f.spans, [0, 0, 2, 1, 0, 1])
        XCTAssertEqual(edges(f).count, 6)
        XCTAssertEqual(perimeter(f), 8)
    }

    func testFootprintOfNoTilesIsNull() {
        XCTAssertNil(TileFootprint.of(3, [], []))
    }

    func testBngTilesMatchTheOsGrid() {
        XCTAssertEqual(BngTiles.resolution(0), 896.0)
        XCTAssertEqual(BngTiles.resolution(9), 1.75)
        // New Fancy View is in Leisure_27700 zoom 9 tile 1342/2604.
        let g = OsGrid.project(LatLon(51.78340, -2.53921))
        XCTAssertEqual(BngTiles.column(g.easting, 9), 1342)
        XCTAssertEqual(BngTiles.row(g.northing, 9), 2604)
        XCTAssertEqual(BngTiles.column(g.easting, 5), BngTiles.column(g.easting, 9) >> 4)
        XCTAssertEqual(BngTiles.row(g.northing, 5), BngTiles.row(g.northing, 9) >> 4)
        XCTAssertTrue((BngTiles.easting(1342, 9)...BngTiles.easting(1343, 9)).contains(g.easting))
        XCTAssertTrue((BngTiles.northing(2605, 9)...BngTiles.northing(2604, 9)).contains(g.northing))
        // OS's capabilities give zoom 0 as 5 columns by 7 rows.
        XCTAssertEqual(BngTiles.column(BngTiles.gbMaxE, 0), 4)
        XCTAssertEqual(BngTiles.row(0.0, 0), 6)
        XCTAssertEqual([1.75, 1.2, 3.0, 0.2, 5000.0].map { BngTiles.zoomFor($0, 0, 9) }, [9, 9, 8, 9, 0])
    }

    func testBngCoverageIncludesNewFancyAndClampsToGreatBritain() {
        let point = LatLon(51.78340, -2.53921)
        let tile = TileKey(9, 1342, 2604)
        XCTAssertTrue(TileCoverage.bngCorridor([point], 250.0, 9).contains(tile))
        XCTAssertTrue(Array(TileCoverage.bngBox(BoundingBox(51.7833, -2.5393, 51.7835, -2.5391), 9, 9)).contains(tile))
        XCTAssertEqual(Int64(Array(TileCoverage.bngCorridor([point], 250.0, 6, 9)).count),
                       TileCoverage.bngCorridorCount([point], 250.0, 6, 9))
        XCTAssertTrue(TileCoverage.bngBox(BoundingBox(49.0, -10.0, 51.8, -2.5), 9, 9)
            .allSatisfy { $0.x >= BngTiles.column(0.0, 9) && $0.y <= BngTiles.row(0.0, 9) })
    }

    func testBngCoverageRejectsOverseasAndKeepsScilly() throws {
        let lydney = try XCTUnwrap(OsGrid.parse("SO 60 10"))
        XCTAssertEqual([Int(lydney.easting) / 100_000, Int(lydney.northing) / 100_000], [3, 2])
        XCTAssertEqual(OsGrid.letters(lydney.easting, lydney.northing), "SO")
        let overseas: [(String, BoundingBox)] = [
            ("Paris", BoundingBox(48.84, 2.29, 48.89, 2.40)),
            ("Dublin", BoundingBox(53.32, -6.40, 53.39, -6.20)),
            ("Belfast", BoundingBox(54.57, -5.96, 54.62, -5.89)),
            ("Calais", BoundingBox(50.93, 1.83, 50.97, 1.88)),
            ("Jersey", BoundingBox(49.18, -2.17, 49.23, -2.08)),
        ]
        for zoom in 0...9 {
            XCTAssertEqual(overseas.filter { any(TileCoverage.bngBox($0.1, zoom, zoom)) }.map { $0.0 }, [], "zoom \(zoom)")
            XCTAssertEqual(overseas.filter {
                !TileCoverage.bngCorridor([LatLon($0.1.minLat, $0.1.minLon), LatLon($0.1.maxLat, $0.1.maxLon)], 250.0, zoom).isEmpty
            }.map { $0.0 }, [], "corridor zoom \(zoom)")
        }
        let britishIslands: [(String, BoundingBox)] = [
            ("Dover", BoundingBox(51.12, 1.30, 51.14, 1.33)),
            ("Scilly", BoundingBox(49.89, -6.38, 49.94, -6.27)),
            ("Mull of Kintyre", BoundingBox(55.29, -5.82, 55.34, -5.69)),
            ("St Kilda", BoundingBox(57.78, -8.62, 57.85, -8.54)),
            ("Unst", BoundingBox(60.72, -0.94, 60.79, -0.84)),
        ]
        XCTAssertEqual(britishIslands.filter { !any(TileCoverage.bngBox($0.1, 9, 9)) }.map { $0.0 }, [])
    }

    func testBngCorridorCoversTheFullSegmentNotOnlyItsEndpoints() {
        let start = LatLon(51.78340, -2.53921)
        let end = Geo.destination(start, bearingDeg: 90.0, distanceM: 3_000.0)
        let middle = OsGrid.project(Geo.destination(start, bearingDeg: 90.0, distanceM: 1_500.0))
        let tiles = TileCoverage.bngCorridor([start, end], 250.0, 9)
        XCTAssertTrue(tiles.contains(TileKey(9, BngTiles.column(middle.easting, 9), BngTiles.row(middle.northing, 9))))
        XCTAssertEqual(Set(tiles).count, tiles.count)
    }

    func testBngBoundarySeparatesBritishCoastsAndIslandsFromNeighboursAtEveryZoom() {
        let rejected: [(String, LatLon)] = [
            ("Rathlin", LatLon(55.29, -6.20)), ("Ballycastle", LatLon(55.20, -6.25)),
            ("Belfast", LatLon(54.60, -5.93)), ("Ards", LatLon(54.45, -5.45)),
            ("Douglas", LatLon(54.15, -4.48)), ("Calais", LatLon(50.95, 1.85)),
            ("Guernsey", LatLon(49.45, -2.55)), ("Alderney", LatLon(49.72, -2.20)),
            ("Point of Ayre", LatLon(54.42, -4.37)), ("Malin Head", LatLon(55.38, -7.37)),
            ("Dublin", LatLon(53.35, -6.26)),
        ]
        let kept: [(String, LatLon)] = [
            ("Scilly", LatLon(49.90, -6.35)), ("Land's End", LatLon(50.07, -5.72)),
            ("Dover", LatLon(51.13, 1.32)), ("Mull of Kintyre", LatLon(55.29, -5.80)),
            ("Islay", LatLon(55.59, -6.31)), ("Mull of Galloway", LatLon(54.64, -4.86)),
            ("St Kilda", LatLon(57.81, -8.58)), ("Orkney", LatLon(58.98, -2.96)),
            ("Muckle Flugga", LatLon(60.86, -0.89)), ("Sule Skerry", LatLon(59.09, -4.41)),
            ("North Rona", LatLon(59.12, -5.82)), ("Foula", LatLon(60.14, -2.08)),
            ("Lowestoft", LatLon(52.48, 1.76)), ("Dungeness", LatLon(50.91, 0.98)),
            ("Isle of Wight", LatLon(50.58, -1.30)), ("Pembrokeshire", LatLon(51.88, -5.31)),
        ]
        for zoom in 0...9 {
            for (name, point) in rejected {
                let box = BoundingBox(point.lat, point.lon, point.lat, point.lon).expandedByMetres(500.0)
                XCTAssertTrue(!any(TileCoverage.bngBox(box, zoom, zoom)), "\(name) box z\(zoom)")
                XCTAssertTrue(TileCoverage.bngCorridor([point, Geo.destination(point, bearingDeg: 90.0, distanceM: 250.0)], 500.0, zoom).isEmpty,
                              "\(name) corridor z\(zoom)")
            }
            for (name, point) in kept {
                let grid = OsGrid.project(point)
                let tile = TileKey(zoom, BngTiles.column(grid.easting, zoom), BngTiles.row(grid.northing, zoom))
                XCTAssertTrue(Set(TileCoverage.bngBox(BoundingBox(point.lat, point.lon, point.lat, point.lon), zoom, zoom)).contains(tile),
                              "\(name) box z\(zoom)")
                XCTAssertTrue(TileCoverage.bngCorridor([point], 250.0, zoom).contains(tile), "\(name) corridor z\(zoom)")
            }
        }
    }

    func testBngCoastalCorridorRetainsItsWholeLength() {
        let coast = [LatLon(54.64, -4.86), LatLon(54.68, -4.88), LatLon(54.72, -4.95), LatLon(54.76, -4.99)]
        for zoom in 0...9 {
            let tiles = TileCoverage.bngCorridor(coast, 250.0, zoom)
            for (start, end) in zip(coast, coast.dropFirst()) {
                for step in 0...100 {
                    let point = OsGrid.project(LatLon(start.lat + (end.lat - start.lat) * Double(step) / 100,
                                                      start.lon + (end.lon - start.lon) * Double(step) / 100))
                    XCTAssertTrue(tiles.contains(TileKey(zoom, BngTiles.column(point.easting, zoom), BngTiles.row(point.northing, zoom))),
                                  "Coast z\(zoom) step\(step)")
                }
            }
        }
    }

    func testFootprintOfACorridorMatchesItsTiles() throws {
        let start = LatLon(51.73, -2.53)
        let points = (0...30).map { Geo.destination(start, bearingDeg: 20.0 + Double($0 * 5), distanceM: Double($0) * 300.0) }
        let tiles = TileCoverage.corridor(points, 250.0, 16)
        let set = Set(tiles.map { [$0.x, $0.y] })
        let f = try XCTUnwrap(TileFootprint.of(16, tiles.map { $0.x }, tiles.map { $0.y }))
        XCTAssertEqual(stride(from: 0, to: f.spans.count, by: 3).reduce(0) { $0 + f.spans[$1 + 2] - f.spans[$1 + 1] }, tiles.count)
        let exposedSides = tiles.reduce(0) { sum, t in
            sum + [(-1, 0), (1, 0), (0, -1), (0, 1)].filter { !set.contains([t.x + $0.0, t.y + $0.1]) }.count
        }
        XCTAssertEqual(perimeter(f), exposedSides)
        XCTAssertTrue(edges(f).count < exposedSides, "collinear edges are merged")
    }

    /// Kotlin's `Sequence.any()`: whether there is at least one.
    private func any<S: Sequence>(_ sequence: S) -> Bool {
        var iterator = sequence.makeIterator()
        return iterator.next() != nil
    }
}
