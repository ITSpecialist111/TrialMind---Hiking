import XCTest
@testable import TrailMind

final class TerrainTests: XCTestCase {
    func testDecodesTerrariumRgb() {
        XCTAssertEqual(Terrain.decodeTerrarium(128, 0, 0), 0 as Float)
        XCTAssertEqual(Terrain.decodeTerrarium(128, 123, 128), 123.5 as Float)
    }

    func testBilinearSamplingIsContinuousAcrossTileEdge() throws {
        let z = 2
        let eastTile = (0..<(256 * 256)).map { index in Float((index % 256) + 256) }
        let westTile = (0..<(256 * 256)).map { index in Float(index % 256) }
        let lat = WebMercator.yToLat(100.5, Double(z))
        let lon = WebMercator.xToLon(256.25, Double(z))
        let sample = Terrain.heightAt(lat, lon, z) { key in
            switch key {
            case TileKey(z, 0, 0): return westTile
            case TileKey(z, 1, 0): return eastTile
            default: return nil
            }
        }
        XCTAssertEqual(try XCTUnwrap(sample), 255.75, accuracy: 0.001)
    }

    func testRouteFillingPreservesExistingElevationAndPointMetadata() {
        let original = [TrackPoint(lat: 51.0, lon: -2.0, ele: 123.0, timeMs: 456), TrackPoint(lat: 51.1, lon: -2.1)]
        let filled = Terrain.fillMissingHeights(original) { _ in 200.0 }
        XCTAssertEqual(filled[0].ele, 123.0)
        XCTAssertEqual(filled[0].timeMs, 456)
        XCTAssertEqual(filled[1].ele, 200.0)
        XCTAssertEqual(filled[1].lat, original[1].lat)
    }

    /// Heights of a plane rising at `degrees` towards the east, padded as `Terrain.padded` would.
    private func plane(_ degrees: Double, _ mpp: Double, _ size: Int = 8) -> [Float] {
        let rise = tan(toRadians(degrees)) * mpp
        let centre = (0..<(size * size)).map { i in Float(100 + Double(i % size) * rise) }
        return Terrain.padded(centre, size) { dx, _ in
            (0..<(size * size)).map { i in Float(100 + Double((i % size) + dx * size) * rise) }
        }
    }

    func testHornSlopeClassesMatchPlanesAndFlatGround() {
        let mpp = Terrain.metresPerPixel(51.8, 13)
        func classOf(_ degrees: Double) -> Int {
            let classes = Set(Terrain.slopeClasses(plane(degrees, mpp), 8) { _ in mpp })
            XCTAssertEqual(classes.count, 1, "one class for a plane at \(degrees)°")
            return Int(classes.first ?? 255)
        }
        XCTAssertEqual(classOf(0.0), Terrain.SlopeClass.none.ordinal)
        XCTAssertEqual(classOf(24.0), Terrain.SlopeClass.none.ordinal)
        XCTAssertEqual(classOf(26.0), Terrain.SlopeClass.moderate.ordinal)
        XCTAssertEqual(classOf(31.0), Terrain.SlopeClass.steep.ordinal)
        XCTAssertEqual(classOf(36.0), Terrain.SlopeClass.verySteep.ordinal)
        XCTAssertEqual(classOf(45.0), Terrain.SlopeClass.extreme.ordinal)
    }

    func testPaddingUsesNeighbourEdgesAndRepeatsMissingOnes() {
        let centre = (0..<4).map { Float($0) }
        let east = (0..<4).map { 10 + Float($0) }
        let padded = Terrain.padded(centre, 2) { dx, dy in dx == 1 && dy == 0 ? east : nil }
        XCTAssertEqual(padded[1 * 4 + 3], 10)
        XCTAssertEqual(padded[2 * 4 + 3], 12)
        XCTAssertEqual(padded[1 * 4 + 0], 0)
        XCTAssertEqual(padded[0], 0)
    }

    func testMissingNeighbourTileMakesEdgeSampleUnavailable() {
        let lat = WebMercator.yToLat(100.5, 2.0)
        let lon = WebMercator.xToLon(256.25, 2.0)
        XCTAssertNil(Terrain.heightAt(lat, lon, 2) { _ in nil })
    }
}
