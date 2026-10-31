import Foundation

struct TileKey: Hashable, Codable, CustomStringConvertible {
    var z: Int
    var x: Int
    var y: Int

    init(_ z: Int, _ x: Int, _ y: Int) { self.z = z; self.x = x; self.y = y }
    init(z: Int, x: Int, y: Int) { self.init(z, x, y) }

    /// MBTiles stores rows in TMS order (origin bottom-left).
    var tmsY: Int { (1 << z) - 1 - y }

    func parent() -> TileKey? { z == 0 ? nil : TileKey(z - 1, x >> 1, y >> 1) }

    var description: String { "\(z)/\(x)/\(y)" }
}

struct TileRange: Hashable {
    var z: Int
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int

    var count: Int64 { Int64(maxX - minX + 1) * Int64(maxY - minY + 1) }

    func tiles() -> [TileKey] {
        var out: [TileKey] = []
        out.reserveCapacity(Int(count))
        for x in minX...maxX { for y in minY...maxY { out.append(TileKey(z, x, y)) } }
        return out
    }
}

/// EPSG:3857 / "slippy map" maths for 256 px tiles.
enum WebMercator {
    static let tileSize = 256
    static let maxLat = 85.05112878
    private static let earthRadius = 6_378_137.0

    static func mapSize(_ zoom: Double) -> Double { Double(tileSize) * pow(2.0, zoom) }

    static func lonToX(_ lon: Double, _ zoom: Double) -> Double { (lon + 180.0) / 360.0 * mapSize(zoom) }

    static func latToY(_ lat: Double, _ zoom: Double) -> Double {
        let s = sin(toRadians(lat.clamped(-maxLat, maxLat)))
        return (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * mapSize(zoom)
    }

    static func xToLon(_ x: Double, _ zoom: Double) -> Double { x / mapSize(zoom) * 360.0 - 180.0 }

    static func yToLat(_ y: Double, _ zoom: Double) -> Double {
        let n = Double.pi - 2.0 * .pi * y / mapSize(zoom)
        return toDegrees(atan(sinh(n)))
    }

    static func tileFor(_ p: LatLon, _ z: Int) -> TileKey {
        let maxIndex = (1 << z) - 1
        let x = Int(floor(lonToX(p.lon, Double(z)) / Double(tileSize))).clamped(0, maxIndex)
        let y = Int(floor(latToY(p.lat, Double(z)) / Double(tileSize))).clamped(0, maxIndex)
        return TileKey(z, x, y)
    }

    static func tileRange(_ box: BoundingBox, _ z: Int) -> TileRange {
        let nw = tileFor(LatLon(box.maxLat, box.minLon), z)
        let se = tileFor(LatLon(box.minLat, box.maxLon), z)
        return TileRange(z: z, minX: min(nw.x, se.x), maxX: max(nw.x, se.x), minY: min(nw.y, se.y), maxY: max(nw.y, se.y))
    }

    static func countTiles(_ box: BoundingBox, _ minZoom: Int, _ maxZoom: Int) -> Int64 {
        guard minZoom <= maxZoom else { return 0 }
        return (minZoom...maxZoom).reduce(Int64(0)) { $0 + tileRange(box, $1).count }
    }

    /// Ground resolution in metres per pixel at `lat`.
    static func metresPerPixel(_ lat: Double, _ zoom: Double) -> Double {
        cos(toRadians(lat)) * 2 * .pi * earthRadius / mapSize(zoom)
    }

    /// EPSG:3857 projected metres (x east, y north) for `p`.
    static func toMetres(_ p: LatLon) -> (x: Double, y: Double) {
        let lat = p.lat.clamped(-maxLat, maxLat)
        return (earthRadius * toRadians(p.lon), earthRadius * log(tan(.pi / 4 + toRadians(lat) / 2)))
    }

    static func fromMetres(_ x: Double, _ y: Double) -> LatLon {
        LatLon(toDegrees(2 * atan(exp(y / earthRadius)) - .pi / 2), toDegrees(x / earthRadius))
    }
}
