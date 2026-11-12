import XCTest
@testable import TrailMind

/// Offline-area shapes for the map: a footprint's cells as rectangles and its outline as loops.
final class FootprintShapeTests: XCTestCase {
    private typealias C = FootprintShape.Corner

    private func footprint(_ cells: [(Int, Int)], zoom: Int = 12) throws -> TileFootprint {
        try XCTUnwrap(TileFootprint.of(zoom, cells.map(\.0), cells.map(\.1)))
    }

    func testARectangleIsOneRectAndOneLoop() throws {
        let f = try footprint((0..<6).map { (10 + $0 % 3, 20 + $0 / 3) })
        XCTAssertEqual(FootprintShape.rects(f), [FootprintShape.Rect(x0: 10, y0: 20, x1: 13, y1: 22)])
        let loops = FootprintShape.loops(f)
        XCTAssertEqual(loops, [[C(10, 20), C(13, 20), C(13, 22), C(10, 22)]])
        XCTAssertEqual(FootprintShape.signedArea2(loops[0]), 12)
        XCTAssertFalse(FootprintShape.isHole(loops[0]))
        // Every corner: one per unit of perimeter.
        XCTAssertEqual(FootprintShape.loops(f, everyCorner: true).map(\.count), [10])
    }

    func testAnLShapeHasSixCorners() throws {
        let f = try footprint([(0, 0), (1, 0), (0, 1)])
        XCTAssertEqual(FootprintShape.rects(f), [FootprintShape.Rect(x0: 0, y0: 0, x1: 2, y1: 1), FootprintShape.Rect(x0: 0, y0: 1, x1: 1, y1: 2)])
        let loops = FootprintShape.loops(f)
        XCTAssertEqual(loops, [[C(0, 0), C(2, 0), C(2, 1), C(1, 1), C(1, 2), C(0, 2)]])
        XCTAssertEqual(FootprintShape.signedArea2(loops[0]), 6)
    }

    func testARingHasAnOuterLoopAndAHole() throws {
        let ring = (0..<3).flatMap { y in (0..<3).map { x in (x, y) } }.filter { $0 != (1, 1) }
        let loops = FootprintShape.loops(try footprint(ring))
        XCTAssertEqual(loops.count, 2)
        XCTAssertEqual(loops.map { FootprintShape.signedArea2($0) }.sorted(), [-2, 18])
        XCTAssertEqual(loops.filter(FootprintShape.isHole), [[C(2, 1), C(1, 1), C(1, 2), C(2, 2)]])
    }

    func testCellsMeetingAtACornerStaySeparate() throws {
        let loops = FootprintShape.loops(try footprint([(0, 0), (1, 1)]))
        XCTAssertEqual(loops.count, 2)
        XCTAssertEqual(Set(loops.map { Set($0) }), [Set([C(0, 0), C(1, 0), C(1, 1), C(0, 1)]), Set([C(1, 1), C(2, 1), C(2, 2), C(1, 2)])])
        let other = FootprintShape.loops(try footprint([(1, 0), (0, 1)]))
        XCTAssertEqual(other.count, 2)
        XCTAssertTrue(other.allSatisfy { $0.count == 4 && FootprintShape.signedArea2($0) == 2 })
    }

    func testRowsMergeOnlyWhileTheSpanAndRowsContinue() throws {
        let cells = [(0, 0), (1, 0), (0, 1), (1, 1), (0, 2), (1, 2), (2, 2), (0, 3), (1, 3), (5, 5), (6, 5), (5, 7), (6, 7)]
        XCTAssertEqual(FootprintShape.rects(try footprint(cells)), [
            FootprintShape.Rect(x0: 0, y0: 0, x1: 2, y1: 2),
            FootprintShape.Rect(x0: 0, y0: 2, x1: 3, y1: 3),
            FootprintShape.Rect(x0: 0, y0: 3, x1: 2, y1: 4),
            FootprintShape.Rect(x0: 5, y0: 5, x1: 7, y1: 6),
            FootprintShape.Rect(x0: 5, y0: 7, x1: 7, y1: 8),
        ])
    }

    func testARouteCorridorsOutlineMatchesItsEdgesAndArea() throws {
        let start = LatLon(54.45, -3.20)
        let route = (0...40).map { Geo.destination(start, bearingDeg: Double($0 * 9), distanceM: Double($0) * 300.0) }
        let tiles = TileCoverage.corridor(route, 300, 15)
        let f = try XCTUnwrap(TileFootprint.of(15, tiles.map(\.x), tiles.map(\.y)))
        var perimeter = 0
        for i in stride(from: 0, to: f.edges.count, by: 4) {
            let dx: Int = abs(f.edges[i + 2] - f.edges[i])
            let dy: Int = abs(f.edges[i + 3] - f.edges[i + 1])
            perimeter += dx + dy
        }
        let every = FootprintShape.loops(f, everyCorner: true)
        XCTAssertEqual(every.reduce(0) { $0 + $1.count }, perimeter)
        XCTAssertEqual(every.reduce(0) { $0 + FootprintShape.signedArea2($1) }, 2 * tiles.count)
        XCTAssertEqual(FootprintShape.loops(f).reduce(0) { $0 + FootprintShape.signedArea2($1) }, 2 * tiles.count)
        let rects = FootprintShape.rects(f)
        XCTAssertEqual(rects.reduce(0) { $0 + ($1.x1 - $1.x0) * ($1.y1 - $1.y0) }, tiles.count)
    }

    func testRingsGoRoundARectangle() {
        let r = FootprintShape.Rect(x0: 2, y0: 3, x1: 4, y1: 4)
        XCTAssertEqual(FootprintShape.ring(r), [C(2, 3), C(4, 3), C(4, 4), C(2, 4)])
        XCTAssertEqual(FootprintShape.ring(r, everyCorner: true), [C(2, 3), C(3, 3), C(4, 3), C(4, 4), C(3, 4), C(2, 4)])
        XCTAssertEqual(FootprintShape.signedArea2(FootprintShape.ring(r, everyCorner: true)), 4)
    }
}
