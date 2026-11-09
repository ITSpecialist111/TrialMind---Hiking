import Foundation

/// 1 m LiDAR terrain in 256 m British National Grid squares, as the Environment Agency's composite DTM covers England:
/// which squares an area needs, heights within a square, crags, and hill shading for the map.
enum Lidar {
    /// Pixels, and metres, along each side of a square.
    static let size = 256
    /// Neighbouring pixels needed around a square to find slope and crags at its edges.
    static let border = 2

    // The composite's published extent; squares outside it are never requested (the service fails on them).
    static let minE = 80_000
    static let maxE = 656_000
    static let minN = 4_000
    static let maxN = 665_000

    /// A crag is a 1 m cell at least this steep...
    static let cragSlopeDeg = 50.0
    /// ...with at least this much height difference in the 5 m × 5 m around it, which leaves out banks and ditches.
    static let cragReliefM: Float = 4

    /// Grid square `col`, `row`: its south-west corner is at easting col × 256, northing row × 256.
    struct Square: Hashable, CustomStringConvertible {
        var col: Int
        var row: Int

        init(_ col: Int, _ row: Int) {
            self.col = col
            self.row = row
        }

        var east: Int { col * Lidar.size }
        var north: Int { row * Lidar.size }
        var inExtent: Bool {
            east + Lidar.size > Lidar.minE && east < Lidar.maxE && north + Lidar.size > Lidar.minN && north < Lidar.maxN
        }

        var description: String { "Square(col=\(col), row=\(row))" }
    }

    static func squareAt(_ easting: Double, _ northing: Double) -> Square {
        Square(toInt(floor(easting / Double(size))), toInt(floor(northing / Double(size))))
    }

    /// The square's heights, row-major from its north edge, from the `raster` the service sent for it; nil unless the
    /// raster is 1 m pixels lined up with the square. At the edge of the survey the service sends only the part inside
    /// it, so the rest is NaN.
    static func place(_ raster: GeoTiff.Raster, _ square: Square) -> [Float]? {
        if abs(raster.pixelWidth - 1) > 1e-6 || abs(raster.pixelHeight - 1) > 1e-6 { return nil }
        let x = raster.left - Double(square.east)
        let y = Double(square.north + size) - raster.top
        let x0 = kRound(x)
        let y0 = kRound(y)
        if abs(x - Double(x0)) > 0.01 || abs(y - Double(y0)) > 0.01 || x0 < 0 || y0 < 0 || x0 + raster.width > size
            || y0 + raster.height > size { return nil }
        if raster.width == size && raster.height == size { return raster.values }
        var values = [Float](repeating: .nan, count: size * size)
        for row in 0..<raster.height {
            let from = row * raster.width
            let to = (y0 + row) * size + x0
            values.replaceSubrange(to..<to + raster.width, with: raster.values[from..<from + raster.width])
        }
        return values
    }

    /// Marks the service's fill as missing and says whether any heights are left. Where it has no survey it sends 0.0
    /// without a no-data tag; a real height of exactly 0.000 m is rare enough to lose.
    static func clean(_ values: inout [Float]) -> Bool {
        var any = false
        for i in values.indices {
            if values[i] == 0 { values[i] = .nan } else if !values[i].isNaN { any = true }
        }
        return any
    }

    /// Squares within `bufferM` of the line through `points`, in order along it, inside the extent.
    static func corridor(_ points: [OsGridRef], _ bufferM: Double) -> [Square] {
        var out: [Square] = []
        var seen = Set<Square>()
        func around(_ e: Double, _ n: Double) {
            for col in stride(from: toInt(floor((e - bufferM) / Double(size))), through: toInt(floor((e + bufferM) / Double(size))), by: 1) {
                for row in stride(from: toInt(floor((n - bufferM) / Double(size))), through: toInt(floor((n + bufferM) / Double(size))), by: 1) {
                    let square = Square(col, row)
                    if square.inExtent && seen.insert(square).inserted { out.append(square) }
                }
            }
        }
        if points.count == 1 { around(points[0].easting, points[0].northing) }
        for i in stride(from: 1, to: points.count, by: 1) {
            let a = points[i - 1]
            let b = points[i]
            let de = b.easting - a.easting
            let dn = b.northing - a.northing
            let length = (de * de + dn * dn).squareRoot()
            let steps = max(1, toInt(length / (Double(size) / 4.0)) + 1)
            for s in 0...steps {
                let f = Double(s) / Double(steps)
                around(a.easting + (b.easting - a.easting) * f, a.northing + (b.northing - a.northing) * f)
            }
        }
        return out
    }

    /// Squares covering the grid box, inside the extent, or nil when there are more than `limit`.
    static func box(_ minE: Double, _ minN: Double, _ maxE: Double, _ maxN: Double, _ limit: Int) -> [Square]? {
        let c0 = toInt(floor(max(minE, Double(Lidar.minE)) / Double(size)))
        let c1 = toInt(floor(min(maxE, Double(Lidar.maxE) - 1.0) / Double(size)))
        let r0 = toInt(floor(max(minN, Double(Lidar.minN)) / Double(size)))
        let r1 = toInt(floor(min(maxN, Double(Lidar.maxN) - 1.0) / Double(size)))
        if c1 < c0 || r1 < r0 { return [] }
        if Int64(c1 - c0 + 1) * Int64(r1 - r0 + 1) > Int64(limit) { return nil }
        return (r0...r1).flatMap { row in (c0...c1).map { col in Square(col, row) } }
    }

    /// Height at a grid position inside `square`, between the four nearest pixel centres; nil where there is no data.
    static func height(_ values: [Float], _ square: Square, _ easting: Double, _ northing: Double) -> Double? {
        if values.count != size * size { return nil }
        let x = (easting - Double(square.east) - 0.5).clamped(0.0, Double(size) - 1.0)
        let y = (Double(square.north + size) - northing - 0.5).clamped(0.0, Double(size) - 1.0)
        let x0 = min(toInt(x), size - 2)
        let y0 = min(toInt(y), size - 2)
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        let a = values[y0 * size + x0]
        let b = values[y0 * size + x0 + 1]
        let c = values[(y0 + 1) * size + x0]
        let d = values[(y0 + 1) * size + x0 + 1]
        if a.isNaN || b.isNaN || c.isNaN || d.isNaN {
            // At a data edge, the nearest pixel if it has a value.
            let nearest = values[min(toInt(y + 0.5), size - 1) * size + min(toInt(x + 0.5), size - 1)]
            return nearest.isNaN ? nil : Double(nearest)
        }
        let top = Double(a) + Double(b - a) * fx
        let bottom = Double(c) + Double(d - c) * fx
        return top + (bottom - top) * fy
    }

    /// `centre` with `border` pixels around it from its neighbours. `neighbour` gets the offset in pixel rows and
    /// columns, so dy = -1 is the square to the north; where it has none, the centre's own edge is repeated.
    static func padded(_ centre: [Float], border: Int = Lidar.border, _ neighbour: (_ dx: Int, _ dy: Int) -> [Float]?) -> [Float] {
        precondition(centre.count == size * size && border >= 0 && border <= size)
        let stride = size + 2 * border
        var around = [[Float]?](repeating: nil, count: 9)
        for i in 0..<9 {
            around[i] = i == 4 ? centre : neighbour(i % 3 - 1, i / 3 - 1).flatMap { $0.count == size * size ? $0 : nil }
        }
        var out = [Float](repeating: 0, count: stride * stride)
        for row in -border..<(size + border) {
            for col in -border..<(size + border) {
                let dx = col < 0 ? -1 : col >= size ? 1 : 0
                let dy = row < 0 ? -1 : row >= size ? 1 : 0
                if let source = around[(dy + 1) * 3 + dx + 1] {
                    out[(row + border) * stride + col + border] = source[kMod(row, size) * size + kMod(col, size)]
                } else {
                    out[(row + border) * stride + col + border] = centre[row.clamped(0, size - 1) * size + col.clamped(0, size - 1)]
                }
            }
        }
        return out
    }

    /// Which cells of a `padded` square are crag: see `cragSlopeDeg` and `cragReliefM`.
    static func crags(_ padded: [Float]) -> [Bool] {
        let stride = size + 2 * border
        precondition(padded.count == stride * stride)
        let relief = Lidar.relief(padded)
        var out = [Bool](repeating: false, count: size * size)
        for row in 0..<size {
            for col in 0..<size {
                let o = row * size + col
                let r = relief[o]
                if !(r >= cragReliefM) { continue }
                let g2 = gradient2(padded, (row + border) * stride + col + border, stride)
                out[o] = g2 >= cragGradient2
            }
        }
        return out
    }

    /// ARGB shading for a `padded` square: slopes facing away from light in the north-west darken the map beneath,
    /// slopes facing it lighten it, level ground is left clear, and `crags` are marked in dark red.
    static func overlay(_ padded: [Float], _ crags: [Bool]) -> [UInt32] {
        let stride = size + 2 * border
        precondition(padded.count == stride * stride && crags.count == size * size)
        var out = [UInt32](repeating: 0, count: size * size)
        for row in 0..<size {
            for col in 0..<size {
                let o = row * size + col
                if crags[o] {
                    out[o] = cragColour
                    continue
                }
                let i = (row + border) * stride + col + border
                let dzdx = Lidar.dzdx(padded, i, stride)
                let dzdy = Lidar.dzdy(padded, i, stride)
                if dzdx.isNaN || dzdy.isNaN { continue }
                out[o] = shadeColour(shade(dzdx, dzdy))
            }
        }
        return out
    }

    /// Hill shading from 0 (dark) to 1, with light from the north-west at 45° as on most maps; level ground is about 0.71.
    static func shade(_ dzdx: Float, _ dzdy: Float) -> Float {
        let lit = flat * (1 + flat * (dzdx + dzdy))
        return (lit / (1 + dzdx * dzdx + dzdy * dzdy).squareRoot()).clamped(0, 1)
    }

    private static func shadeColour(_ shade: Float) -> UInt32 {
        let d = shade - flat
        if d < 0 {
            let alpha = toInt(minOf(1, -d / flat * 1.4) * Float(maxDarkAlpha))
            return UInt32(truncatingIfNeeded: alpha << 24)
        } else {
            let alpha = toInt(minOf(1, d / (1 - flat)) * Float(maxLightAlpha))
            return UInt32(truncatingIfNeeded: alpha << 24 | 0xFFFFFF)
        }
    }

    // Horn's method on 1 m cells; rows run south, so dz/dy is the rise towards the south.
    private static func dzdx(_ p: [Float], _ i: Int, _ s: Int) -> Float {
        let east = p[i - s + 1] + 2 * p[i + 1] + p[i + s + 1]
        let west = p[i - s - 1] + 2 * p[i - 1] + p[i + s - 1]
        return (east - west) / 8
    }

    private static func dzdy(_ p: [Float], _ i: Int, _ s: Int) -> Float {
        let south = p[i + s - 1] + 2 * p[i + s] + p[i + s + 1]
        let north = p[i - s - 1] + 2 * p[i - s] + p[i - s + 1]
        return (south - north) / 8
    }

    private static func gradient2(_ p: [Float], _ i: Int, _ s: Int) -> Float {
        let x = dzdx(p, i, s)
        let y = dzdy(p, i, s)
        return x * x + y * y
    }

    /// Highest minus lowest height in the 5 × 5 cells around each cell of a `padded` square; NaN when any is missing.
    private static func relief(_ padded: [Float]) -> [Float] {
        let stride = size + 2 * border
        var hiRow = [Float](repeating: 0, count: stride * size)
        var loRow = [Float](repeating: 0, count: stride * size)
        for r in 0..<stride {
            for c in 0..<size {
                var hi = -Float.greatestFiniteMagnitude
                var lo = Float.greatestFiniteMagnitude
                for k in 0...(2 * border) {
                    let v = padded[r * stride + c + k]
                    if v.isNaN {
                        hi = .nan
                        break
                    }
                    if v > hi { hi = v }
                    if v < lo { lo = v }
                }
                hiRow[r * size + c] = hi
                loRow[r * size + c] = lo
            }
        }
        var out = [Float](repeating: 0, count: size * size)
        for r in 0..<size {
            for c in 0..<size {
                var hi = -Float.greatestFiniteMagnitude
                var lo = Float.greatestFiniteMagnitude
                for k in 0...(2 * border) {
                    let h = hiRow[(r + k) * size + c]
                    if h.isNaN {
                        hi = .nan
                        break
                    }
                    if h > hi { hi = h }
                    let l = loRow[(r + k) * size + c]
                    if l < lo { lo = l }
                }
                out[r * size + c] = hi - lo
            }
        }
        return out
    }

    private static let flat: Float = 0.70710677
    private static let maxDarkAlpha = 150
    private static let maxLightAlpha = 80
    private static let cragGradient2: Float = {
        let t = tan(toRadians(cragSlopeDeg))
        return Float(t * t)
    }()
    /// Dark red, opaque enough to read over any base map.
    static let cragColour: UInt32 = 215 << 24 | 130 << 16 | 20 << 8 | 20

    /// Kotlin's `toInt()`: truncates, saturates at its 32-bit range and gives 0 for NaN, where `Int(_:)` would trap.
    private static func toInt(_ x: Double) -> Int {
        x.isNaN ? 0 : x >= 2_147_483_647 ? 2_147_483_647 : x <= -2_147_483_648 ? -2_147_483_648 : Int(x)
    }

    private static func toInt(_ x: Float) -> Int { toInt(Double(x)) }

    /// Kotlin's `minOf` on floats (Java's `Math.min`): NaN if either is, and -0 below +0.
    private static func minOf(_ a: Float, _ b: Float) -> Float {
        if a.isNaN { return a }
        if a == 0 && b == 0 && b.sign == .minus { return b }
        return a <= b ? a : b
    }
}
