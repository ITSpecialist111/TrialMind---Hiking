import Foundation

/// A stretch of a route from `startM` to `endM` along it; `value` is its steepest angle or nearest crag, worst at `at`.
struct LidarSection: Hashable {
    var startM: Double
    var endM: Double
    var value: Double
    var at: LatLon

    init(_ startM: Double, _ endM: Double, _ value: Double, _ at: LatLon) {
        self.startM = startM
        self.endM = endM
        self.value = value
        self.at = at
    }
}

struct LidarRouteReport: Hashable {
    var lengthM: Double
    /// How much of the route LiDAR covers, in metres along it.
    var coveredM: Double
    /// Where the line climbs or drops at `LidarRouteCheck.steepDeg` or more over `LidarRouteCheck.windowM`; value in degrees.
    var steep: [LidarSection]
    /// Where a crag is within `LidarRouteCheck.cragNearM` of the line; value is the nearest distance in metres.
    var crags: [LidarSection]
}

/// Checks a route line against 1 m LiDAR for ground steep enough to need hands, and crags beside it.
enum LidarRouteCheck {
    static let steepDeg = 35.0
    static let windowM = 10.0
    static let cragNearM = 10
    /// Crags are looked for around points at most this far apart along the line.
    private static let cragStepM = 2.0
    private static let maxSections = 60

    protocol Ground {
        /// Height at a grid position, or nil where LiDAR has no data.
        func height(_ easting: Double, _ northing: Double) -> Double?
        /// Whether the 1 m cell at a grid position is crag.
        func crag(_ easting: Double, _ northing: Double) -> Bool
    }

    static func check(_ points: [LatLon], _ ground: any Ground) -> LidarRouteReport {
        if points.count < 2 { return LidarRouteReport(lengthM: 0.0, coveredM: 0.0, steep: [], crags: []) }
        let grid = points.map { OsGrid.project($0) }
        // Samples at most a metre apart along the line.
        var along: [Double] = []
        var east: [Double] = []
        var north: [Double] = []
        var positions: [LatLon] = []
        var start = 0.0
        for i in 1..<grid.count {
            let a = grid[i - 1]
            let b = grid[i]
            let de = b.easting - a.easting
            let dn = b.northing - a.northing
            let length = (de * de + dn * dn).squareRoot()
            let steps = max(toInt(ceil(length)), 1)
            for s in 0..<steps {
                let f = Double(s) / Double(steps)
                along.append(start + length * f)
                east.append(a.easting + (b.easting - a.easting) * f)
                north.append(a.northing + (b.northing - a.northing) * f)
                positions.append(LatLon(points[i - 1].lat + (points[i].lat - points[i - 1].lat) * f,
                                        points[i - 1].lon + (points[i].lon - points[i - 1].lon) * f))
            }
            start += length
        }
        along.append(start)
        east.append(grid[grid.count - 1].easting)
        north.append(grid[grid.count - 1].northing)
        positions.append(points[points.count - 1])
        let n = along.count
        let heights = (0..<n).map { ground.height(east[$0], north[$0]) ?? .nan }
        var covered = 0.0
        for i in 1..<n where !heights[i].isNaN && !heights[i - 1].isNaN { covered += along[i] - along[i - 1] }

        var steep = Sections(gapM: 2.0, worse: { a, b in a > b })
        var j = 0
        for i in 0..<n {
            if j < i { j = i }
            while j < n - 1 && along[j] - along[i] < windowM { j += 1 }
            let run = along[j] - along[i]
            if run < windowM || heights[i].isNaN || heights[j].isNaN { continue }
            let degrees = toDegrees(atan(abs(heights[j] - heights[i]) / run))
            if degrees >= steepDeg { steep.add(along[i], along[j], degrees, positions[heights[j] > heights[i] ? j : i]) }
        }

        var crags = Sections(gapM: 4.0, worse: { a, b in a < b })
        let r2 = cragNearM * cragNearM
        // Probes no more than cragStepM apart however the samples are spaced, and also where the line itself has no
        // height: a crag beside a gap in the survey (water, say) is still a crag.
        var probedAt = 0.0
        for i in 0..<n {
            if i != 0 && i != n - 1 && along[i + 1] - probedAt <= cragStepM { continue }
            probedAt = along[i]
            var nearest = Int.max
            for dy in -cragNearM...cragNearM {
                for dx in -cragNearM...cragNearM {
                    let d2 = dx * dx + dy * dy
                    if d2 > r2 || d2 >= nearest { continue }
                    if ground.crag(east[i] + Double(dx), north[i] + Double(dy)) { nearest = d2 }
                }
            }
            if nearest != Int.max { crags.add(along[i], along[i], Double(nearest).squareRoot(), positions[i]) }
        }
        return LidarRouteReport(lengthM: start, coveredM: covered, steep: steep.list(), crags: crags.list())
    }

    /// Joins overlapping or nearby stretches, keeping the worst value in each.
    private struct Sections {
        let gapM: Double
        let worse: (Double, Double) -> Bool
        private var out: [LidarSection] = []

        init(gapM: Double, worse: @escaping (Double, Double) -> Bool) {
            self.gapM = gapM
            self.worse = worse
        }

        mutating func add(_ from: Double, _ to: Double, _ value: Double, _ at: LatLon) {
            if let last = out.last, from <= last.endM + gapM {
                let worst = worse(value, last.value)
                out[out.count - 1] = LidarSection(last.startM, max(last.endM, to), worst ? value : last.value, worst ? at : last.at)
            } else {
                out.append(LidarSection(from, to, value, at))
            }
        }

        func list() -> [LidarSection] { Array(out.prefix(maxSections)) }
    }

    /// Kotlin's `toInt()`: truncates, saturates at its 32-bit range and gives 0 for NaN, where `Int(_:)` would trap.
    private static func toInt(_ x: Double) -> Int {
        x.isNaN ? 0 : x >= 2_147_483_647 ? 2_147_483_647 : x <= -2_147_483_648 ? -2_147_483_648 : Int(x)
    }
}
