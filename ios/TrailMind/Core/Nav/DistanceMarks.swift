import Foundation

/// Whole-kilometre or whole-mile marks along a route, thinned so their labels stay readable at any scale.
enum DistanceMarks {
    private static let nice = [1, 2, 5, 10, 20, 50, 100, 200, 500]

    static func stepM(imperial: Bool) -> Double { imperial ? 1609.344 : 1000.0 }

    /// Positions `stepM` apart along `guide`; element i is (i + 1) steps from the start.
    static func along(_ guide: RouteGuide, stepM: Double) -> [LatLon] {
        let count = kTruncate(guide.totalM / stepM)
        return count < 1 ? [] : (1...count).map { guide.pointAt(Double($0) * stepM) }
    }

    /// Draw every n-th mark, the smallest nice n that puts marks `stepPx` apart at least `minPx` apart.
    static func every(stepPx: Double, minPx: Double) -> Int { nice.first { Double($0) * stepPx >= minPx } ?? nice[nice.count - 1] }
}
