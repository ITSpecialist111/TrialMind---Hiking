import Foundation

/// A pack's footprint as shapes a map draws as polygons: its cells merged into rectangles, and its outline as closed
/// loops of tile corners. Coordinates are tile numbers at the footprint's zoom (x to the east, y to the south).
enum FootprintShape {
    struct Corner: Hashable {
        var x: Int
        var y: Int

        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }

    /// Cells x0..<x1 by y0..<y1.
    struct Rect: Hashable {
        var x0: Int
        var y0: Int
        var x1: Int
        var y1: Int
    }

    /// The cells as rectangles: each row's spans, merged into the row above while the span is the same.
    static func rects(_ f: TileFootprint) -> [Rect] {
        var out: [Rect] = []
        var previous: [Corner: Int] = [:]
        var current: [Corner: Int] = [:]
        var row: Int? = nil
        for i in stride(from: 0, to: f.spans.count - 2, by: 3) {
            let y = f.spans[i]
            let span = Corner(f.spans[i + 1], f.spans[i + 2])
            if row != y {
                previous = row.map { y == $0 + 1 } == true ? current : [:]
                current = [:]
                row = y
            }
            if let index = previous.removeValue(forKey: span) {
                out[index].y1 = y + 1
                current[span] = index
            } else {
                out.append(Rect(x0: span.x, y0: y, x1: span.y, y1: y + 1))
                current[span] = out.count - 1
            }
        }
        return out
    }

    // East, south, west, north.
    private static let dx = [1, 0, -1, 0]
    private static let dy = [0, 1, 0, -1]

    /// The outline as closed loops of corners, each corner listed once per visit with the loop closing back to its first.
    /// The cells lie on the right of the direction of travel, so outer edges run clockwise on screen and holes the other
    /// way. Where two cells meet only at a corner the loop turns right, keeping each closed shape apart. Corners along a
    /// straight edge are dropped unless `everyCorner` (National Grid outlines are bent through every tile corner).
    static func loops(_ f: TileFootprint, everyCorner: Bool = false) -> [[Corner]] {
        var cells = Set<Corner>()
        for i in stride(from: 0, to: f.spans.count - 2, by: 3) {
            for x in f.spans[i + 1]..<f.spans[i + 2] { cells.insert(Corner(x, f.spans[i])) }
        }
        // Boundary edges by their first corner and direction, in row order so the result does not depend on hashing.
        var outgoing: [Corner: UInt8] = [:]
        var edges: [(Corner, Int)] = []
        func add(_ c: Corner, _ d: Int) {
            outgoing[c, default: 0] |= 1 << UInt8(d)
            edges.append((c, d))
        }
        for i in stride(from: 0, to: f.spans.count - 2, by: 3) {
            let y = f.spans[i]
            for x in f.spans[i + 1]..<f.spans[i + 2] {
                if !cells.contains(Corner(x, y - 1)) { add(Corner(x, y), 0) }
                if !cells.contains(Corner(x + 1, y)) { add(Corner(x + 1, y), 1) }
                if !cells.contains(Corner(x, y + 1)) { add(Corner(x + 1, y + 1), 2) }
                if !cells.contains(Corner(x - 1, y)) { add(Corner(x, y + 1), 3) }
            }
        }
        var usedDirections: [Corner: UInt8] = [:]
        func isUsed(_ c: Corner, _ d: Int) -> Bool { (usedDirections[c] ?? 0) & (1 << UInt8(d)) != 0 }
        var loops: [[Corner]] = []
        for (start, startDirection) in edges where !isUsed(start, startDirection) {
            var corners: [Corner] = []
            var directions: [Int] = []
            var c = start
            var d = startDirection
            repeat {
                usedDirections[c, default: 0] |= 1 << UInt8(d)
                corners.append(c)
                directions.append(d)
                let next = Corner(c.x + dx[d], c.y + dy[d])
                let available = outgoing[next] ?? 0
                guard let turn = [(d + 1) % 4, d, (d + 3) % 4].first(where: { available & (1 << UInt8($0)) != 0 }) else { break }
                c = next
                d = turn
            } while !(c == start && d == startDirection)
            if everyCorner {
                loops.append(corners)
            } else {
                let n = directions.count
                loops.append((0..<n).filter { directions[$0] != directions[($0 + n - 1) % n] }.map { corners[$0] })
            }
        }
        return loops
    }

    /// Twice the area inside a loop, positive for outer edges (clockwise on screen) and negative for holes.
    static func signedArea2(_ loop: [Corner]) -> Int {
        guard loop.count > 2 else { return 0 }
        var sum = 0
        for i in loop.indices {
            let a = loop[i]
            let b = loop[(i + 1) % loop.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum
    }

    static func isHole(_ loop: [Corner]) -> Bool { signedArea2(loop) < 0 }

    /// The corners around a rectangle, clockwise on screen from its north-west corner; with `everyCorner`, one per
    /// tile edge along each side.
    static func ring(_ r: Rect, everyCorner: Bool = false) -> [Corner] {
        if !everyCorner { return [Corner(r.x0, r.y0), Corner(r.x1, r.y0), Corner(r.x1, r.y1), Corner(r.x0, r.y1)] }
        var out: [Corner] = []
        for x in r.x0..<r.x1 { out.append(Corner(x, r.y0)) }
        for y in r.y0..<r.y1 { out.append(Corner(r.x1, y)) }
        for x in stride(from: r.x1, to: r.x0, by: -1) { out.append(Corner(x, r.y1)) }
        for y in stride(from: r.y1, to: r.y0, by: -1) { out.append(Corner(r.x0, y)) }
        return out
    }
}
