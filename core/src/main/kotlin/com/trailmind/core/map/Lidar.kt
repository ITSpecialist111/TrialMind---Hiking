package com.trailmind.core.map

import com.trailmind.core.geo.OsGridRef
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * 1 m LiDAR terrain in 256 m British National Grid squares, as the Environment Agency's composite DTM covers England:
 * which squares an area needs, heights within a square, crags, and hill shading for the map.
 */
object Lidar {
    /** Pixels, and metres, along each side of a square. */
    const val SIZE = 256
    /** Neighbouring pixels needed around a square to find slope and crags at its edges. */
    const val BORDER = 2

    // The composite's published extent; squares outside it are never requested (the service fails on them).
    const val MIN_E = 80_000
    const val MAX_E = 656_000
    const val MIN_N = 4_000
    const val MAX_N = 665_000

    /** A crag is a 1 m cell at least this steep... */
    const val CRAG_SLOPE_DEG = 50.0
    /** ...with at least this much height difference in the 5 m × 5 m around it, which leaves out banks and ditches. */
    const val CRAG_RELIEF_M = 4f

    /** Grid square [col], [row]: its south-west corner is at easting col × 256, northing row × 256. */
    data class Square(val col: Int, val row: Int) {
        val east: Int get() = col * SIZE
        val north: Int get() = row * SIZE
        val inExtent: Boolean get() = east + SIZE > MIN_E && east < MAX_E && north + SIZE > MIN_N && north < MAX_N
    }

    fun squareAt(easting: Double, northing: Double) = Square(floor(easting / SIZE).toInt(), floor(northing / SIZE).toInt())

    /**
     * The square's heights, row-major from its north edge, from the [raster] the service sent for it; null unless the
     * raster is 1 m pixels lined up with the square. At the edge of the survey the service sends only the part inside
     * it, so the rest is NaN.
     */
    fun place(raster: GeoTiff.Raster, square: Square): FloatArray? {
        if (abs(raster.pixelWidth - 1) > 1e-6 || abs(raster.pixelHeight - 1) > 1e-6) return null
        val x = raster.left - square.east
        val y = square.north + SIZE - raster.top
        val x0 = x.roundToInt()
        val y0 = y.roundToInt()
        if (abs(x - x0) > 0.01 || abs(y - y0) > 0.01 || x0 < 0 || y0 < 0 || x0 + raster.width > SIZE || y0 + raster.height > SIZE) return null
        if (raster.width == SIZE && raster.height == SIZE) return raster.values
        val values = FloatArray(SIZE * SIZE) { Float.NaN }
        for (row in 0 until raster.height) System.arraycopy(raster.values, row * raster.width, values, (y0 + row) * SIZE + x0, raster.width)
        return values
    }

    /**
     * Marks the service's fill as missing and says whether any heights are left. Where it has no survey it sends 0.0
     * without a no-data tag; a real height of exactly 0.000 m is rare enough to lose.
     */
    fun clean(values: FloatArray): Boolean {
        var any = false
        for (i in values.indices) {
            if (values[i] == 0f) values[i] = Float.NaN else if (!values[i].isNaN()) any = true
        }
        return any
    }

    /** Squares within [bufferM] of the line through [points], in order along it, inside the extent. */
    fun corridor(points: List<OsGridRef>, bufferM: Double): List<Square> {
        val out = LinkedHashSet<Square>()
        fun around(e: Double, n: Double) {
            for (col in floor((e - bufferM) / SIZE).toInt()..floor((e + bufferM) / SIZE).toInt())
                for (row in floor((n - bufferM) / SIZE).toInt()..floor((n + bufferM) / SIZE).toInt()) {
                    val square = Square(col, row)
                    if (square.inExtent) out += square
                }
        }
        if (points.size == 1) around(points[0].easting, points[0].northing)
        for (i in 1 until points.size) {
            val a = points[i - 1]
            val b = points[i]
            val length = sqrt((b.easting - a.easting).let { it * it } + (b.northing - a.northing).let { it * it })
            val steps = maxOf(1, (length / (SIZE / 4.0)).toInt() + 1)
            for (s in 0..steps) {
                val f = s.toDouble() / steps
                around(a.easting + (b.easting - a.easting) * f, a.northing + (b.northing - a.northing) * f)
            }
        }
        return out.toList()
    }

    /** Squares covering the grid box, inside the extent, or null when there are more than [limit]. */
    fun box(minE: Double, minN: Double, maxE: Double, maxN: Double, limit: Int): List<Square>? {
        val c0 = floor(maxOf(minE, MIN_E.toDouble()) / SIZE).toInt()
        val c1 = floor(minOf(maxE, MAX_E - 1.0) / SIZE).toInt()
        val r0 = floor(maxOf(minN, MIN_N.toDouble()) / SIZE).toInt()
        val r1 = floor(minOf(maxN, MAX_N - 1.0) / SIZE).toInt()
        if (c1 < c0 || r1 < r0) return emptyList()
        if ((c1 - c0 + 1).toLong() * (r1 - r0 + 1) > limit) return null
        return (r0..r1).flatMap { row -> (c0..c1).map { col -> Square(col, row) } }
    }

    /** Height at a grid position inside [square], between the four nearest pixel centres; null where there is no data. */
    fun height(values: FloatArray, square: Square, easting: Double, northing: Double): Double? {
        if (values.size != SIZE * SIZE) return null
        val x = (easting - square.east - 0.5).coerceIn(0.0, SIZE - 1.0)
        val y = (square.north + SIZE - northing - 0.5).coerceIn(0.0, SIZE - 1.0)
        val x0 = x.toInt().coerceAtMost(SIZE - 2)
        val y0 = y.toInt().coerceAtMost(SIZE - 2)
        val fx = x - x0
        val fy = y - y0
        val a = values[y0 * SIZE + x0]
        val b = values[y0 * SIZE + x0 + 1]
        val c = values[(y0 + 1) * SIZE + x0]
        val d = values[(y0 + 1) * SIZE + x0 + 1]
        if (a.isNaN() || b.isNaN() || c.isNaN() || d.isNaN()) {
            // At a data edge, the nearest pixel if it has a value.
            val nearest = values[(y + 0.5).toInt().coerceAtMost(SIZE - 1) * SIZE + (x + 0.5).toInt().coerceAtMost(SIZE - 1)]
            return nearest.takeUnless { it.isNaN() }?.toDouble()
        }
        val top = a + (b - a) * fx
        val bottom = c + (d - c) * fx
        return top + (bottom - top) * fy
    }

    /**
     * [centre] with [BORDER] pixels around it from its neighbours. [neighbour] gets the offset in pixel rows and
     * columns, so dy = -1 is the square to the north; where it has none, the centre's own edge is repeated.
     */
    fun padded(centre: FloatArray, neighbour: (dx: Int, dy: Int) -> FloatArray?): FloatArray {
        require(centre.size == SIZE * SIZE)
        val stride = SIZE + 2 * BORDER
        val around = Array(9) { i -> if (i == 4) centre else neighbour(i % 3 - 1, i / 3 - 1)?.takeIf { it.size == SIZE * SIZE } }
        val out = FloatArray(stride * stride)
        for (row in -BORDER until SIZE + BORDER) for (col in -BORDER until SIZE + BORDER) {
            val dx = if (col < 0) -1 else if (col >= SIZE) 1 else 0
            val dy = if (row < 0) -1 else if (row >= SIZE) 1 else 0
            val source = around[(dy + 1) * 3 + dx + 1]
            out[(row + BORDER) * stride + col + BORDER] = if (source != null) source[Math.floorMod(row, SIZE) * SIZE + Math.floorMod(col, SIZE)]
                else centre[row.coerceIn(0, SIZE - 1) * SIZE + col.coerceIn(0, SIZE - 1)]
        }
        return out
    }

    /** Which cells of a [padded] square are crag: see [CRAG_SLOPE_DEG] and [CRAG_RELIEF_M]. */
    fun crags(padded: FloatArray): BooleanArray {
        val stride = SIZE + 2 * BORDER
        require(padded.size == stride * stride)
        val relief = relief(padded)
        val out = BooleanArray(SIZE * SIZE)
        for (row in 0 until SIZE) for (col in 0 until SIZE) {
            val o = row * SIZE + col
            val r = relief[o]
            if (!(r >= CRAG_RELIEF_M)) continue
            val g2 = gradient2(padded, (row + BORDER) * stride + col + BORDER, stride)
            out[o] = g2 >= CRAG_GRADIENT2
        }
        return out
    }

    /**
     * ARGB shading for a [padded] square: slopes facing away from light in the north-west darken the map beneath,
     * slopes facing it lighten it, level ground is left clear, and [crags] are marked in dark red.
     */
    fun overlay(padded: FloatArray, crags: BooleanArray): IntArray {
        val stride = SIZE + 2 * BORDER
        require(padded.size == stride * stride && crags.size == SIZE * SIZE)
        val out = IntArray(SIZE * SIZE)
        for (row in 0 until SIZE) for (col in 0 until SIZE) {
            val o = row * SIZE + col
            if (crags[o]) { out[o] = CRAG_COLOUR; continue }
            val i = (row + BORDER) * stride + col + BORDER
            val dzdx = dzdx(padded, i, stride)
            val dzdy = dzdy(padded, i, stride)
            if (dzdx.isNaN() || dzdy.isNaN()) continue
            out[o] = shadeColour(shade(dzdx, dzdy))
        }
        return out
    }

    /** Hill shading from 0 (dark) to 1, with light from the north-west at 45° as on most maps; level ground is about 0.71. */
    fun shade(dzdx: Float, dzdy: Float): Float =
        (FLAT * (1 + FLAT * (dzdx + dzdy)) / sqrt(1 + dzdx * dzdx + dzdy * dzdy)).coerceIn(0f, 1f)

    private fun shadeColour(shade: Float): Int {
        val d = shade - FLAT
        return if (d < 0) {
            val alpha = (minOf(1f, -d / FLAT * 1.4f) * MAX_DARK_ALPHA).toInt()
            alpha shl 24
        } else {
            val alpha = (minOf(1f, d / (1 - FLAT)) * MAX_LIGHT_ALPHA).toInt()
            (alpha shl 24) or 0xFFFFFF
        }
    }

    // Horn's method on 1 m cells; rows run south, so dz/dy is the rise towards the south.
    private fun dzdx(p: FloatArray, i: Int, s: Int) =
        ((p[i - s + 1] + 2 * p[i + 1] + p[i + s + 1]) - (p[i - s - 1] + 2 * p[i - 1] + p[i + s - 1])) / 8f

    private fun dzdy(p: FloatArray, i: Int, s: Int) =
        ((p[i + s - 1] + 2 * p[i + s] + p[i + s + 1]) - (p[i - s - 1] + 2 * p[i - s] + p[i - s + 1])) / 8f

    private fun gradient2(p: FloatArray, i: Int, s: Int): Float {
        val x = dzdx(p, i, s)
        val y = dzdy(p, i, s)
        return x * x + y * y
    }

    /** Highest minus lowest height in the 5 × 5 cells around each cell of a [padded] square; NaN when any is missing. */
    private fun relief(padded: FloatArray): FloatArray {
        val stride = SIZE + 2 * BORDER
        val hiRow = FloatArray(stride * SIZE)
        val loRow = FloatArray(stride * SIZE)
        for (r in 0 until stride) for (c in 0 until SIZE) {
            var hi = -Float.MAX_VALUE
            var lo = Float.MAX_VALUE
            for (k in 0..2 * BORDER) {
                val v = padded[r * stride + c + k]
                if (v.isNaN()) { hi = Float.NaN; break }
                if (v > hi) hi = v
                if (v < lo) lo = v
            }
            hiRow[r * SIZE + c] = hi
            loRow[r * SIZE + c] = lo
        }
        val out = FloatArray(SIZE * SIZE)
        for (r in 0 until SIZE) for (c in 0 until SIZE) {
            var hi = -Float.MAX_VALUE
            var lo = Float.MAX_VALUE
            for (k in 0..2 * BORDER) {
                val h = hiRow[(r + k) * SIZE + c]
                if (h.isNaN()) { hi = Float.NaN; break }
                if (h > hi) hi = h
                val l = loRow[(r + k) * SIZE + c]
                if (l < lo) lo = l
            }
            out[r * SIZE + c] = hi - lo
        }
        return out
    }

    private const val FLAT = 0.70710677f
    private const val MAX_DARK_ALPHA = 150
    private const val MAX_LIGHT_ALPHA = 80
    private val CRAG_GRADIENT2 = tan(Math.toRadians(CRAG_SLOPE_DEG)).let { it * it }.toFloat()
    /** Dark red, opaque enough to read over any base map. */
    const val CRAG_COLOUR = (215 shl 24) or (130 shl 16) or (20 shl 8) or 20
}
