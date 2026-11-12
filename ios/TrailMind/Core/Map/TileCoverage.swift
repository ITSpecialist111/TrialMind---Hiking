import Foundation

/// Which tiles an offline pack needs: a rectangle, or a corridor around a route (much smaller).
enum TileCoverage {
    // Offshore WGS84 envelope: sea separators around Ireland/Man/Channel, with margins beyond GB's outer islands, not a coastline simplification.
    private static let gbBoundary: [OsGridRef] = [
        LatLon(49.75, -6.65), LatLon(50.30, -6.65), LatLon(51.70, -5.70),
        LatLon(53.30, -5.50), LatLon(53.80, -5.00), LatLon(54.25, -4.00),
        LatLon(54.50, -4.00), LatLon(54.52, -4.85), LatLon(54.70, -5.20),
        LatLon(55.05, -5.40), LatLon(55.32, -6.00), LatLon(55.48, -6.40),
        LatLon(55.50, -7.00), LatLon(56.80, -8.00), LatLon(57.40, -9.00),
        LatLon(58.50, -9.00), LatLon(59.50, -7.00), LatLon(61.30, -2.50),
        LatLon(61.30, 0.50), LatLon(59.30, 0.00), LatLon(58.00, 0.00),
        LatLon(56.00, 0.50), LatLon(54.00, 0.50), LatLon(52.00, 2.20),
        LatLon(51.20, 1.75), LatLon(50.85, 1.35), LatLon(50.50, 0.30),
        LatLon(50.00, -1.50), LatLon(49.75, -3.00),
    ].map(OsGrid.project)
    private static let gbEdges: [(start: OsGridRef, end: OsGridRef)] =
        zip(gbBoundary, Array(gbBoundary.dropFirst()) + [gbBoundary[0]]).map { (start: $0, end: $1) }
    private static let gbMinEasting = gbBoundary.map(\.easting).reduce(Double.infinity) { minOf($0, $1) }
    private static let gbMaxEasting = gbBoundary.map(\.easting).reduce(-Double.infinity) { maxOf($0, $1) }
    private static let gbMinNorthing = gbBoundary.map(\.northing).reduce(Double.infinity) { minOf($0, $1) }
    private static let gbMaxNorthing = gbBoundary.map(\.northing).reduce(-Double.infinity) { maxOf($0, $1) }

    /// Every tile of `box` from `minZoom` to `maxZoom`, made as it is used rather than all at once.
    static func box(_ box: BoundingBox, _ minZoom: Int, _ maxZoom: Int) -> AnySequence<TileKey> {
        AnySequence(stride(from: minZoom, through: maxZoom, by: 1).lazy.flatMap { z in
            let range = WebMercator.tileRange(box, z)
            return (range.minX...range.maxX).lazy.flatMap { x in (range.minY...range.maxY).lazy.map { y in TileKey(z, x, y) } }
        })
    }

    static func corridor(_ points: [LatLon], _ bufferM: Double, _ z: Int) -> [TileKey] {
        if points.isEmpty { return [] }
        var out = Set<TileKey>()
        let step = max(bufferM, 25.0)
        func addAround(_ p: LatLon) {
            let b = BoundingBox(p.lat, p.lon, p.lat, p.lon).expandedByMetres(bufferM)
            out.formUnion(WebMercator.tileRange(b, z).tiles())
        }
        addAround(points[0])
        for i in stride(from: 1, to: points.count, by: 1) {
            let a = points[i - 1]
            let b = points[i]
            let d = Geo.distanceM(a, b)
            let n = toInt(d / step)
            for k in stride(from: 1, through: n, by: 1) {
                let t = Double(k) * step / d
                addAround(LatLon(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t))
            }
            addAround(b)
        }
        return out.sorted(by: byColumnThenRow)
    }

    static func corridor(_ points: [LatLon], _ bufferM: Double, _ minZoom: Int, _ maxZoom: Int) -> AnySequence<TileKey> {
        AnySequence(stride(from: minZoom, through: maxZoom, by: 1).lazy.flatMap { corridor(points, bufferM, $0) })
    }

    static func corridorCount(_ points: [LatLon], _ bufferM: Double, _ minZoom: Int, _ maxZoom: Int) -> Int64 {
        stride(from: minZoom, through: maxZoom, by: 1).reduce(Int64(0)) { $0 + Int64(corridor(points, bufferM, $1).count) }
    }

    static func bngBox(_ box: BoundingBox, _ minZoom: Int, _ maxZoom: Int) -> AnySequence<TileKey> {
        let midLat = (box.minLat + box.maxLat) / 2
        let midLon = (box.minLon + box.maxLon) / 2
        let corners = [
            LatLon(box.minLat, box.minLon), LatLon(box.minLat, midLon), LatLon(box.minLat, box.maxLon),
            LatLon(midLat, box.minLon), LatLon(midLat, box.maxLon),
            LatLon(box.maxLat, box.minLon), LatLon(box.maxLat, midLon), LatLon(box.maxLat, box.maxLon),
        ].map(OsGrid.project)
        let minE = corners.dropFirst().reduce(corners[0].easting) { minOf($0, $1.easting) }
        let maxE = corners.dropFirst().reduce(corners[0].easting) { maxOf($0, $1.easting) }
        let minN = corners.dropFirst().reduce(corners[0].northing) { minOf($0, $1.northing) }
        let maxN = corners.dropFirst().reduce(corners[0].northing) { maxOf($0, $1.northing) }
        return AnySequence(stride(from: minZoom, through: maxZoom, by: 1).lazy.flatMap { z in bngRange(minE, maxE, minN, maxN, z) })
    }

    static func bngCorridor(_ points: [LatLon], _ bufferM: Double, _ z: Int) -> [TileKey] {
        if points.isEmpty { return [] }
        precondition(bufferM >= 0)
        let grid = points.map(OsGrid.project)
        var tiles = Set<TileKey>()
        var segments: [(OsGridRef, OsGridRef)] = []
        for index in 0..<max(1, grid.count - 1) {
            segments += clipToGb(grid[index], grid[min(index + 1, grid.count - 1)])
        }
        let buffer2 = bufferM * bufferM
        for (a, b) in segments {
            for tile in bngRange(minOf(a.easting, b.easting) - bufferM, maxOf(a.easting, b.easting) + bufferM,
                                 minOf(a.northing, b.northing) - bufferM, maxOf(a.northing, b.northing) + bufferM, z) {
                let west = BngGrid.easting(tile.x, z)
                let east = BngGrid.easting(tile.x + 1, z)
                let north = BngGrid.northing(tile.y, z)
                let south = BngGrid.northing(tile.y + 1, z)
                func distanceSquared(_ e: Double, _ n: Double) -> Double {
                    let dx = b.easting - a.easting
                    let dy = b.northing - a.northing
                    let t = dx == 0.0 && dy == 0.0 ? 0.0
                        : (((e - a.easting) * dx + (n - a.northing) * dy) / (dx * dx + dy * dy)).clamped(0.0, 1.0)
                    let de = e - a.easting - t * dx
                    let dn = n - a.northing - t * dy
                    return de * de + dn * dn
                }
                let crosses = segmentCrossesBox(a.easting, a.northing, b.easting, b.northing, west, east, south, north)
                let closestEndpoint = [a, b].contains { p in
                    let de = p.easting - p.easting.clamped(west, east)
                    let dn = p.northing - p.northing.clamped(south, north)
                    return de * de + dn * dn <= buffer2
                }
                if crosses || closestEndpoint || [(west, south), (west, north), (east, south), (east, north)]
                    .contains(where: { distanceSquared($0.0, $0.1) <= buffer2 }) {
                    tiles.insert(tile)
                }
            }
        }
        return tiles.sorted(by: byColumnThenRow)
    }

    static func bngCorridor(_ points: [LatLon], _ bufferM: Double, _ minZoom: Int, _ maxZoom: Int) -> AnySequence<TileKey> {
        AnySequence(stride(from: minZoom, through: maxZoom, by: 1).lazy.flatMap { bngCorridor(points, bufferM, $0) })
    }

    static func bngCorridorCount(_ points: [LatLon], _ bufferM: Double, _ minZoom: Int, _ maxZoom: Int) -> Int64 {
        stride(from: minZoom, through: maxZoom, by: 1).reduce(Int64(0)) { $0 + Int64(bngCorridor(points, bufferM, $1).count) }
    }

    private static func bngRange(_ minE: Double, _ maxE: Double, _ minN: Double, _ maxN: Double, _ z: Int) -> AnySequence<TileKey> {
        precondition((0...9).contains(z))
        let west = maxOf(minE, maxOf(0.0, gbMinEasting))
        let east = minOf(maxE, gbMaxEasting)
        let south = maxOf(minN, maxOf(0.0, gbMinNorthing))
        let north = minOf(maxN, gbMaxNorthing)
        if west > east || south > north || !gbIntersectsBox(west, east, south, north) { return AnySequence([]) }
        let rows = stride(from: BngGrid.row(north, z), through: BngGrid.row(south, z), by: 1)
        return AnySequence(stride(from: BngGrid.column(west, z), through: BngGrid.column(east, z), by: 1).lazy
            .flatMap { column in rows.lazy.map { row in TileKey(z, column, row) } }
            .filter { tile in
                gbIntersectsBox(maxOf(west, BngGrid.easting(tile.x, z)), minOf(east, BngGrid.easting(tile.x + 1, z)),
                                maxOf(south, BngGrid.northing(tile.y + 1, z)), minOf(north, BngGrid.northing(tile.y, z)))
            })
    }

    private static func inGb(_ easting: Double, _ northing: Double) -> Bool {
        var inside = false
        for (start, end) in gbEdges {
            if (start.northing > northing) != (end.northing > northing) &&
                easting < start.easting + (end.easting - start.easting) *
                (northing - start.northing) / (end.northing - start.northing) { inside = !inside }
        }
        return inside
    }

    private static func gbIntersectsBox(_ west: Double, _ east: Double, _ south: Double, _ north: Double) -> Bool {
        inGb(west, south) || inGb(west, north) || inGb(east, south) || inGb(east, north) ||
            gbEdges.contains { segmentCrossesBox($0.start.easting, $0.start.northing, $0.end.easting, $0.end.northing, west, east, south, north) }
    }

    private static func clipToGb(_ start: OsGridRef, _ end: OsGridRef) -> [(OsGridRef, OsGridRef)] {
        let eastDelta = end.easting - start.easting
        let northDelta = end.northing - start.northing
        var cuts = [0.0, 1.0]
        for (edgeStart, edgeEnd) in gbEdges {
            let edgeEast = edgeEnd.easting - edgeStart.easting
            let edgeNorth = edgeEnd.northing - edgeStart.northing
            let determinant = eastDelta * edgeNorth - northDelta * edgeEast
            if determinant == 0.0 { continue }
            let offsetEast = edgeStart.easting - start.easting
            let offsetNorth = edgeStart.northing - start.northing
            let along = (offsetEast * edgeNorth - offsetNorth * edgeEast) / determinant
            let edgeAlong = (offsetEast * northDelta - offsetNorth * eastDelta) / determinant
            if (0.0...1.0).contains(along) && (0.0...1.0).contains(edgeAlong) { cuts.append(along) }
        }
        func at(_ fraction: Double) -> OsGridRef {
            OsGridRef(start.easting + eastDelta * fraction, start.northing + northDelta * fraction)
        }
        let ordered = distinctSorted(cuts)
        var out: [(OsGridRef, OsGridRef)] = []
        for k in 1..<ordered.count {
            let from = ordered[k - 1]
            let to = ordered[k]
            let midpoint = at((from + to) / 2)
            if inGb(midpoint.easting, midpoint.northing) { out.append((at(from), at(to))) }
        }
        return out
    }

    private static func segmentCrossesBox(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                                          _ west: Double, _ east: Double, _ south: Double, _ north: Double) -> Bool {
        var start = 0.0
        var end = 1.0
        let dx = bx - ax
        let dy = by - ay
        if outside(-dx, ax - west, &start, &end) { return false }
        if outside(dx, east - ax, &start, &end) { return false }
        if outside(-dy, ay - south, &start, &end) { return false }
        return !outside(dy, north - ay, &start, &end)
    }

    /// Clips `start`...`end` along a segment to one side of a box, `p` and `q` as Liang–Barsky has them; whether
    /// nothing of the segment is left.
    private static func outside(_ p: Double, _ q: Double, _ start: inout Double, _ end: inout Double) -> Bool {
        if p == 0.0 { return q < 0 }
        let t = q / p
        if p < 0 { start = maxOf(start, t) } else { end = minOf(end, t) }
        return start > end
    }

    private static func byColumnThenRow(_ a: TileKey, _ b: TileKey) -> Bool { a.x != b.x ? a.x < b.x : a.y < b.y }

    /// Kotlin's `distinct().sorted()` on doubles, which tells -0.0 from 0.0 and puts it first.
    private static func distinctSorted(_ values: [Double]) -> [Double] {
        var seen = Set<UInt64>()
        return values.filter { seen.insert($0.bitPattern).inserted }
            .sorted { a, b in a < b || (a == b && a.sign == .minus && b.sign == .plus) }
    }

    /// Kotlin's `max` and `min` on doubles (Java's `Math.max`/`min`): NaN if either is, and -0 below +0.
    private static func maxOf(_ a: Double, _ b: Double) -> Double {
        if a.isNaN { return a }
        if a == 0 && b == 0 && a.sign == .minus { return b }
        return a >= b ? a : b
    }

    private static func minOf(_ a: Double, _ b: Double) -> Double {
        if a.isNaN { return a }
        if a == 0 && b == 0 && b.sign == .minus { return b }
        return a <= b ? a : b
    }

    /// Kotlin's `toInt()`: truncates, saturates at its 32-bit range and gives 0 for NaN, where `Int(_:)` would trap.
    fileprivate static func toInt(_ x: Double) -> Int {
        x.isNaN ? 0 : x >= 2_147_483_647 ? 2_147_483_647 : x <= -2_147_483_648 ? -2_147_483_648 : Int(x)
    }
}

/// The parts of `BngTiles`, ported on their own, that coverage needs: the OS Maps API tile grid in British National Grid,
/// 256 px tiles from a fixed top-left corner with the resolution halving at each zoom from 896 m per pixel.
private enum BngGrid {
    static let originE = -238_375.0
    static let originN = 1_376_256.0
    static let tileSize = 256

    static func resolution(_ z: Int) -> Double { 896.0 / Double(1 << z) }

    private static func span(_ z: Int) -> Double { Double(tileSize) * resolution(z) }

    static func column(_ easting: Double, _ z: Int) -> Int { TileCoverage.toInt(floor((easting - originE) / span(z))) }

    static func row(_ northing: Double, _ z: Int) -> Int { TileCoverage.toInt(floor((originN - northing) / span(z))) }

    /// The west edge of `column`.
    static func easting(_ column: Int, _ z: Int) -> Double { originE + Double(column) * span(z) }

    /// The north edge of `row`.
    static func northing(_ row: Int, _ z: Int) -> Double { originN - Double(row) * span(z) }
}
