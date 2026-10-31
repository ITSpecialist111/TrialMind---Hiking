import Foundation

/// The area a set of tiles at one zoom covers, ready to draw: row spans to fill and the merged outline,
/// in tile units (XYZ columns and rows) at `zoom`.
struct TileFootprint {
    let zoom: Int
    /// (row, firstColumn, endColumn) triples; endColumn is exclusive.
    let spans: [Int]
    /// (x0, y0, x1, y1) straight edges on tile corners, each as long as it can be.
    let edges: [Int]
    let minX: Int
    let minY: Int
    /// The corner after the last column and row.
    let maxX: Int
    let maxY: Int

    private init(zoom: Int, spans: [Int], edges: [Int], minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.zoom = zoom
        self.spans = spans
        self.edges = edges
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// The footprint of tiles `xs[i]`, `ys[i]` (duplicates allowed), or nil when there are none.
    static func of(_ zoom: Int, _ xs: [Int], _ ys: [Int]) -> TileFootprint? {
        precondition(xs.count == ys.count, "xs and ys differ in length")
        if xs.isEmpty { return nil }
        var sorted = (0..<xs.count).map { key(xs[$0], ys[$0]) }
        sorted.sort()
        var n = 0
        for i in sorted.indices {
            let k = sorted[i]
            if n == 0 || sorted[n - 1] != k {
                sorted[n] = k
                n += 1
            }
        }
        let cells = Array(sorted[0..<n])
        func has(_ x: Int, _ y: Int) -> Bool { binarySearch(cells, key(x, y)) }

        var spans: [Int] = []
        var horizontal = [Int64](repeating: 0, count: 2 * n)
        var vertical = [Int64](repeating: 0, count: 2 * n)
        var hn = 0
        var vn = 0
        var minX = Int.max
        var maxX = Int.min
        var i = 0
        while i < n {
            let y = row(cells[i])
            let x0 = column(cells[i])
            var x1 = x0 + 1
            while i + 1 < n && cells[i + 1] == key(x1, y) {
                i += 1
                x1 += 1
            }
            spans.append(y)
            spans.append(x0)
            spans.append(x1)
            minX = min(minX, x0)
            maxX = max(maxX, x1)
            i += 1
        }
        // Unit edges keyed (line, position along it) so sorting lines them up for merging.
        for c in cells {
            let x = column(c)
            let y = row(c)
            if !has(x, y - 1) { horizontal[hn] = key(x, y); hn += 1 }
            if !has(x, y + 1) { horizontal[hn] = key(x, y + 1); hn += 1 }
            if !has(x - 1, y) { vertical[vn] = key(y, x); vn += 1 }
            if !has(x + 1, y) { vertical[vn] = key(y, x + 1); vn += 1 }
        }
        var edges: [Int] = []
        merge(&horizontal, hn) { line, from, to in edges += [from, line, to, line] }
        merge(&vertical, vn) { line, from, to in edges += [line, from, line, to] }
        return TileFootprint(zoom: zoom, spans: spans, edges: edges, minX: minX, minY: row(cells[0]), maxX: maxX,
                             maxY: row(cells[cells.count - 1]) + 1)
    }

    // Row-major, so sorted cells run along each row in column order. Tile numbers are never negative.
    private static func key(_ x: Int, _ y: Int) -> Int64 { Int64(truncatingIfNeeded: y) << 32 | Int64(truncatingIfNeeded: x) & 0xFFFF_FFFF }
    private static func row(_ k: Int64) -> Int { Int(k >> 32) }
    private static func column(_ k: Int64) -> Int { Int(Int32(truncatingIfNeeded: k)) }

    /// `java.util.Arrays.binarySearch(sorted, k) >= 0`.
    private static func binarySearch(_ sorted: [Int64], _ k: Int64) -> Bool {
        var low = 0
        var high = sorted.count - 1
        while low <= high {
            let mid = (low + high) >> 1
            if sorted[mid] < k {
                low = mid + 1
            } else if sorted[mid] > k {
                high = mid - 1
            } else {
                return true
            }
        }
        return false
    }

    private static func merge(_ units: inout [Int64], _ count: Int, _ emit: (_ line: Int, _ from: Int, _ to: Int) -> Void) {
        units[0..<count].sort()
        var i = 0
        while i < count {
            let line = row(units[i])
            let from = column(units[i])
            var to = from + 1
            while i + 1 < count && units[i + 1] == key(to, line) {
                i += 1
                to += 1
            }
            emit(line, from, to)
            i += 1
        }
    }
}
