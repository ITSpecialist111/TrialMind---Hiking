import Foundation

/// Heights and slopes from Terrarium-encoded Web Mercator terrain tiles.
enum Terrain {
    static let zoom = 13
    static let tileSize = 256

    static func decodeTerrarium(_ red: Int, _ green: Int, _ blue: Int) -> Float {
        Float(Double(red) * 256.0 + Double(green) + Double(blue) / 256.0 - 32768.0)
    }

    /// Heights of ARGB pixels, as Android's `Bitmap.getPixels` gives them.
    static func decodeTerrarium(_ argb: [UInt32]) -> [Float] {
        argb.map { pixel in decodeTerrarium(Int(pixel >> 16 & 0xff), Int(pixel >> 8 & 0xff), Int(pixel & 0xff)) }
    }

    static func heightAt(_ lat: Double, _ lon: Double, _ zoom: Int = Terrain.zoom, _ tile: (TileKey) -> [Float]?) -> Double? {
        let world = toInt(WebMercator.mapSize(Double(zoom)))
        let px = WebMercator.lonToX(lon, Double(zoom)) - 0.5
        let py = WebMercator.latToY(lat, Double(zoom)) - 0.5
        let x0 = toInt(floor(px))
        let y0 = toInt(floor(py)).clamped(0, world - 1)
        let fx = px - floor(px)
        let fy = py - floor(py)
        let x1 = x0 + 1
        let y1 = min(y0 + 1, world - 1)

        func value(_ x: Int, _ y: Int) -> Double? {
            let wrappedX = kMod(x, world)
            guard let grid = tile(TileKey(zoom, wrappedX / tileSize, y / tileSize)) else { return nil }
            if grid.count < tileSize * tileSize { return nil }
            return Double(grid[(y % tileSize) * tileSize + wrappedX % tileSize])
        }

        guard let a = value(x0, y0) else { return nil }
        guard let b = value(x1, y0) else { return nil }
        guard let c = value(x0, y1) else { return nil }
        guard let d = value(x1, y1) else { return nil }
        let top = a + (b - a) * fx
        let bottom = c + (d - c) * fx
        return top + (bottom - top) * fy
    }

    static func fillMissingHeights(_ points: [TrackPoint], _ sample: (LatLon) -> Double?) -> [TrackPoint] {
        points.map { point in
            if point.ele != nil { return point }
            guard let ele = sample(point.latLon()) else { return point }
            var filled = point
            filled.ele = ele
            return filled
        }
    }

    /// The tile's heights with a one-pixel border from its neighbours (by dx, dy), repeating its own edge where one is missing.
    static func padded(_ centre: [Float], _ size: Int = Terrain.tileSize, _ neighbour: (_ dx: Int, _ dy: Int) -> [Float]?) -> [Float] {
        precondition(centre.count == size * size)
        let stride = size + 2
        var around = [[Float]?](repeating: nil, count: 9)
        for i in 0..<9 {
            around[i] = i == 4 ? centre : neighbour(i % 3 - 1, i / 3 - 1).flatMap { $0.count == size * size ? $0 : nil }
        }
        var out = [Float](repeating: 0, count: stride * stride)
        for row in -1...size {
            for col in -1...size {
                let dx = col < 0 ? -1 : col >= size ? 1 : 0
                let dy = row < 0 ? -1 : row >= size ? 1 : 0
                if let source = around[(dy + 1) * 3 + dx + 1] {
                    out[(row + 1) * stride + col + 1] = source[kMod(row, size) * size + kMod(col, size)]
                } else {
                    out[(row + 1) * stride + col + 1] = centre[row.clamped(0, size - 1) * size + col.clamped(0, size - 1)]
                }
            }
        }
        return out
    }

    /// `SlopeClass` ordinal of every pixel by Horn's method on `padded` heights (see `padded`);
    /// `metresPerPixel` gives each row's ground resolution.
    static func slopeClasses(_ padded: [Float], _ size: Int, _ metresPerPixel: (_ row: Int) -> Double) -> [UInt8] {
        let stride = size + 2
        precondition(padded.count == stride * stride)
        var out = [UInt8](repeating: 0, count: size * size)
        for row in 0..<size {
            let eight = 8.0 * metresPerPixel(row)
            for col in 0..<size {
                let i = (row + 1) * stride + col + 1
                let east = padded[i - stride + 1] + 2 * padded[i + 1] + padded[i + stride + 1]
                let west = padded[i - stride - 1] + 2 * padded[i - 1] + padded[i + stride - 1]
                let south = padded[i + stride - 1] + 2 * padded[i + stride] + padded[i + stride + 1]
                let north = padded[i - stride - 1] + 2 * padded[i - stride] + padded[i - stride + 1]
                // As in Kotlin, the sums are Float and the division Double.
                let dzdx = Double(east - west) / eight
                let dzdy = Double(south - north) / eight
                let gradient2 = dzdx * dzdx + dzdy * dzdy
                var c = 0
                while c < gradient2Limits.count && gradient2 >= gradient2Limits[c] { c += 1 }
                out[row * size + col] = UInt8(c)
            }
        }
        return out
    }

    static func metresPerPixel(_ lat: Double, _ zoom: Int = Terrain.zoom) -> Double {
        WebMercator.metresPerPixel(lat, Double(zoom))
    }

    /// Shading classes from 25°, 30°, 35° and 40°; the ordinal is what `slopeClasses` returns.
    enum SlopeClass: Int, CaseIterable {
        case none = 0, moderate, steep, verySteep, extreme

        var ordinal: Int { rawValue }

        var fromDegrees: Double {
            switch self {
            case .none: return 0.0
            case .moderate: return 25.0
            case .steep: return 30.0
            case .verySteep: return 35.0
            case .extreme: return 40.0
            }
        }
    }

    private static let gradient2Limits: [Double] = SlopeClass.allCases.dropFirst().map { slope in
        let t = tan(toRadians(slope.fromDegrees))
        return t * t
    }

    /// Kotlin's `toInt()`: truncates, saturates at its 32-bit range and gives 0 for NaN, where `Int(_:)` would trap.
    private static func toInt(_ x: Double) -> Int {
        x.isNaN ? 0 : x >= 2_147_483_647 ? 2_147_483_647 : x <= -2_147_483_648 ? -2_147_483_648 : Int(x)
    }
}
