import Foundation

/// Joins the pieces of a route (for example the sections of an OpenStreetMap route relation) into one
/// line. A piece is flipped when that puts its start nearer to where the line so far ends. When
/// `ordered` is false the pieces are also chained nearest-end-first, because relations with gaps list
/// their sections in no particular order.
enum PathJoin {
    static func join(_ pieces: [[TrackPoint]], ordered: Bool = true) -> [TrackPoint] {
        var todo = pieces.filter { !$0.isEmpty }
        if todo.isEmpty { return [] }
        var out: [TrackPoint] = []
        var first = todo.removeFirst()
        if let next = todo.first {
            let fromStart = min(d(first.first!, next.first!), d(first.first!, next.last!))
            let fromEnd = min(d(first.last!, next.first!), d(first.last!, next.last!))
            if fromStart < fromEnd { first = first.reversed() }
        }
        append(&out, first)
        while !todo.isEmpty {
            let end = out.last!
            let i = ordered ? 0 : nearest(todo, end)
            let piece = todo.remove(at: i)
            append(&out, d(end, piece.last!) < d(end, piece.first!) ? piece.reversed() : piece)
        }
        return out
    }

    /// The index of the piece with an end nearest `end`; the first such piece on a tie, as Kotlin's `minBy`.
    private static func nearest(_ todo: [[TrackPoint]], _ end: TrackPoint) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (i, piece) in todo.enumerated() {
            let distance = min(d(end, piece.first!), d(end, piece.last!))
            if i == 0 || distance < bestDistance {
                best = i
                bestDistance = distance
            }
        }
        return best
    }

    private static func append(_ out: inout [TrackPoint], _ piece: [TrackPoint]) {
        for p in piece where out.isEmpty || d(out.last!, p) > 0.5 { out.append(p) }
    }

    private static func d(_ a: TrackPoint, _ b: TrackPoint) -> Double { Geo.distanceM(a.lat, a.lon, b.lat, b.lon) }
}
