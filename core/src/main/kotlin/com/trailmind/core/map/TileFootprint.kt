package com.trailmind.core.map

/**
 * The area a set of tiles at one zoom covers, ready to draw: row spans to fill and the merged outline,
 * in tile units (XYZ columns and rows) at [zoom].
 */
class TileFootprint private constructor(
    val zoom: Int,
    /** (row, firstColumn, endColumn) triples; endColumn is exclusive. */
    val spans: IntArray,
    /** (x0, y0, x1, y1) straight edges on tile corners, each as long as it can be. */
    val edges: IntArray,
    val minX: Int,
    val minY: Int,
    /** The corner after the last column and row. */
    val maxX: Int,
    val maxY: Int,
) {
    companion object {
        /** The footprint of tiles [xs][i], [ys][i] (duplicates allowed), or null when there are none. */
        fun of(zoom: Int, xs: IntArray, ys: IntArray): TileFootprint? {
            require(xs.size == ys.size) { "xs and ys differ in length" }
            if (xs.isEmpty()) return null
            val sorted = LongArray(xs.size) { key(xs[it], ys[it]) }.also { it.sort() }
            var n = 0
            for (k in sorted) if (n == 0 || sorted[n - 1] != k) sorted[n++] = k
            val cells = sorted.copyOf(n)
            fun has(x: Int, y: Int) = java.util.Arrays.binarySearch(cells, key(x, y)) >= 0

            val spans = IntBuf(64)
            val horizontal = LongArray(2 * n)
            val vertical = LongArray(2 * n)
            var hn = 0
            var vn = 0
            var minX = Int.MAX_VALUE
            var maxX = Int.MIN_VALUE
            var i = 0
            while (i < n) {
                val y = row(cells[i])
                val x0 = column(cells[i])
                var x1 = x0 + 1
                while (i + 1 < n && cells[i + 1] == key(x1, y)) { i++; x1++ }
                spans.add(y); spans.add(x0); spans.add(x1)
                minX = minOf(minX, x0)
                maxX = maxOf(maxX, x1)
                i++
            }
            // Unit edges keyed (line, position along it) so sorting lines them up for merging.
            for (c in cells) {
                val x = column(c)
                val y = row(c)
                if (!has(x, y - 1)) horizontal[hn++] = key(x, y)
                if (!has(x, y + 1)) horizontal[hn++] = key(x, y + 1)
                if (!has(x - 1, y)) vertical[vn++] = key(y, x)
                if (!has(x + 1, y)) vertical[vn++] = key(y, x + 1)
            }
            val edges = IntBuf(64)
            merge(horizontal, hn) { line, from, to -> edges.add(from); edges.add(line); edges.add(to); edges.add(line) }
            merge(vertical, vn) { line, from, to -> edges.add(line); edges.add(from); edges.add(line); edges.add(to) }
            return TileFootprint(zoom, spans.toArray(), edges.toArray(), minX, row(cells.first()), maxX, row(cells.last()) + 1)
        }

        // Row-major, so sorted cells run along each row in column order. Tile numbers are never negative.
        private fun key(x: Int, y: Int): Long = (y.toLong() shl 32) or (x.toLong() and 0xFFFF_FFFFL)
        private fun row(k: Long): Int = (k shr 32).toInt()
        private fun column(k: Long): Int = k.toInt()

        private inline fun merge(units: LongArray, count: Int, emit: (line: Int, from: Int, to: Int) -> Unit) {
            units.sort(0, count)
            var i = 0
            while (i < count) {
                val line = row(units[i])
                val from = column(units[i])
                var to = from + 1
                while (i + 1 < count && units[i + 1] == key(to, line)) { i++; to++ }
                emit(line, from, to)
                i++
            }
        }
    }

    private class IntBuf(capacity: Int) {
        private var a = IntArray(capacity)
        private var n = 0
        fun add(v: Int) {
            if (n == a.size) a = a.copyOf(n * 2)
            a[n++] = v
        }
        fun toArray(): IntArray = a.copyOf(n)
    }
}
