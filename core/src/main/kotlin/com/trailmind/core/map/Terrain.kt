package com.trailmind.core.map

import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.WebMercator
import kotlin.math.floor
import kotlin.math.tan

/** Heights and slopes from Terrarium-encoded Web Mercator terrain tiles. */
object Terrain {
    const val ZOOM = 13
    const val TILE_SIZE = 256

    fun decodeTerrarium(red: Int, green: Int, blue: Int): Float =
        (red * 256.0 + green + blue / 256.0 - 32768.0).toFloat()

    fun decodeTerrarium(argb: IntArray): FloatArray = FloatArray(argb.size) { i ->
        val pixel = argb[i]
        decodeTerrarium(pixel shr 16 and 0xff, pixel shr 8 and 0xff, pixel and 0xff)
    }

    fun heightAt(lat: Double, lon: Double, zoom: Int = ZOOM, tile: (TileKey) -> FloatArray?): Double? {
        val world = WebMercator.mapSize(zoom.toDouble())
        val px = WebMercator.lonToX(lon, zoom.toDouble()) - 0.5
        val py = WebMercator.latToY(lat, zoom.toDouble()) - 0.5
        val x0 = floor(px).toInt()
        val y0 = floor(py).toInt().coerceIn(0, world.toInt() - 1)
        val fx = px - floor(px)
        val fy = py - floor(py)
        val x1 = x0 + 1
        val y1 = (y0 + 1).coerceAtMost(world.toInt() - 1)

        fun value(x: Int, y: Int): Double? {
            val wrappedX = Math.floorMod(x, world.toInt())
            val grid = tile(TileKey(zoom, wrappedX / TILE_SIZE, y / TILE_SIZE)) ?: return null
            if (grid.size < TILE_SIZE * TILE_SIZE) return null
            return grid[(y % TILE_SIZE) * TILE_SIZE + wrappedX % TILE_SIZE].toDouble()
        }

        val a = value(x0, y0) ?: return null
        val b = value(x1, y0) ?: return null
        val c = value(x0, y1) ?: return null
        val d = value(x1, y1) ?: return null
        val top = a + (b - a) * fx
        val bottom = c + (d - c) * fx
        return top + (bottom - top) * fy
    }

    fun fillMissingHeights(points: List<TrackPoint>, sample: (LatLon) -> Double?): List<TrackPoint> =
        points.map { point ->
            if (point.ele != null) point else sample(point.latLon())?.let { point.copy(ele = it) } ?: point
        }

    /** The tile's heights with a one-pixel border from its neighbours (by dx, dy), repeating its own edge where one is missing. */
    fun padded(centre: FloatArray, size: Int = TILE_SIZE, neighbour: (dx: Int, dy: Int) -> FloatArray?): FloatArray {
        require(centre.size == size * size)
        val stride = size + 2
        val around = Array(9) { i -> if (i == 4) centre else neighbour(i % 3 - 1, i / 3 - 1)?.takeIf { it.size == size * size } }
        val out = FloatArray(stride * stride)
        for (row in -1..size) for (col in -1..size) {
            val dx = if (col < 0) -1 else if (col >= size) 1 else 0
            val dy = if (row < 0) -1 else if (row >= size) 1 else 0
            val source = around[(dy + 1) * 3 + dx + 1]
            out[(row + 1) * stride + col + 1] = if (source != null) source[Math.floorMod(row, size) * size + Math.floorMod(col, size)]
                else centre[row.coerceIn(0, size - 1) * size + col.coerceIn(0, size - 1)]
        }
        return out
    }

    /**
     * [SlopeClass] ordinal of every pixel by Horn's method on [padded] heights (see [padded]);
     * [metresPerPixel] gives each row's ground resolution.
     */
    fun slopeClasses(padded: FloatArray, size: Int, metresPerPixel: (row: Int) -> Double): ByteArray {
        val stride = size + 2
        require(padded.size == stride * stride)
        val out = ByteArray(size * size)
        for (row in 0 until size) {
            val eight = 8.0 * metresPerPixel(row)
            for (col in 0 until size) {
                val i = (row + 1) * stride + col + 1
                val dzdx = ((padded[i - stride + 1] + 2 * padded[i + 1] + padded[i + stride + 1]) -
                    (padded[i - stride - 1] + 2 * padded[i - 1] + padded[i + stride - 1])) / eight
                val dzdy = ((padded[i + stride - 1] + 2 * padded[i + stride] + padded[i + stride + 1]) -
                    (padded[i - stride - 1] + 2 * padded[i - stride] + padded[i - stride + 1])) / eight
                val gradient2 = dzdx * dzdx + dzdy * dzdy
                var c = 0
                while (c < GRADIENT2_LIMITS.size && gradient2 >= GRADIENT2_LIMITS[c]) c++
                out[row * size + col] = c.toByte()
            }
        }
        return out
    }

    fun metresPerPixel(lat: Double, zoom: Int = ZOOM): Double = WebMercator.metresPerPixel(lat, zoom.toDouble())

    /** Shading classes from 25°, 30°, 35° and 40°; the ordinal is what [slopeClasses] returns. */
    enum class SlopeClass(val fromDegrees: Double) { NONE(0.0), MODERATE(25.0), STEEP(30.0), VERY_STEEP(35.0), EXTREME(40.0) }

    private val GRADIENT2_LIMITS = SlopeClass.entries.drop(1).map { tan(Math.toRadians(it.fromDegrees)).let { t -> t * t } }.toDoubleArray()
}