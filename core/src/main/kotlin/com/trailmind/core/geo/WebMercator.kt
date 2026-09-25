package com.trailmind.core.geo

import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sinh
import kotlin.math.tan

data class TileKey(val z: Int, val x: Int, val y: Int) {
    /** MBTiles stores rows in TMS order (origin bottom-left). */
    val tmsY: Int get() = (1 shl z) - 1 - y

    fun parent(): TileKey? = if (z == 0) null else TileKey(z - 1, x shr 1, y shr 1)

    override fun toString(): String = "$z/$x/$y"
}

data class TileRange(val z: Int, val minX: Int, val maxX: Int, val minY: Int, val maxY: Int) {
    val count: Long get() = (maxX - minX + 1).toLong() * (maxY - minY + 1).toLong()

    fun tiles(): Sequence<TileKey> = sequence {
        for (x in minX..maxX) for (y in minY..maxY) yield(TileKey(z, x, y))
    }
}

/** EPSG:3857 / "slippy map" maths for 256 px tiles. */
object WebMercator {
    const val TILE_SIZE = 256
    const val MAX_LAT = 85.05112878

    fun mapSize(zoom: Double): Double = TILE_SIZE * 2.0.pow(zoom)

    fun lonToX(lon: Double, zoom: Double): Double = (lon + 180.0) / 360.0 * mapSize(zoom)

    fun latToY(lat: Double, zoom: Double): Double {
        val s = sin(Math.toRadians(lat.coerceIn(-MAX_LAT, MAX_LAT)))
        return (0.5 - ln((1 + s) / (1 - s)) / (4 * PI)) * mapSize(zoom)
    }

    fun xToLon(x: Double, zoom: Double): Double = x / mapSize(zoom) * 360.0 - 180.0

    fun yToLat(y: Double, zoom: Double): Double {
        val n = PI - 2.0 * PI * y / mapSize(zoom)
        return Math.toDegrees(atan(sinh(n)))
    }

    fun tileFor(p: LatLon, z: Int): TileKey {
        val max = (1 shl z) - 1
        val x = floor(lonToX(p.lon, z.toDouble()) / TILE_SIZE).toInt().coerceIn(0, max)
        val y = floor(latToY(p.lat, z.toDouble()) / TILE_SIZE).toInt().coerceIn(0, max)
        return TileKey(z, x, y)
    }

    fun tileRange(box: BoundingBox, z: Int): TileRange {
        val nw = tileFor(LatLon(box.maxLat, box.minLon), z)
        val se = tileFor(LatLon(box.minLat, box.maxLon), z)
        return TileRange(z, minOf(nw.x, se.x), maxOf(nw.x, se.x), minOf(nw.y, se.y), maxOf(nw.y, se.y))
    }

    fun countTiles(box: BoundingBox, minZoom: Int, maxZoom: Int): Long =
        (minZoom..maxZoom).sumOf { tileRange(box, it).count }

    /** Ground resolution in metres per pixel at [lat]. */
    fun metresPerPixel(lat: Double, zoom: Double): Double =
        cos(Math.toRadians(lat)) * 2 * PI * EARTH_RADIUS / mapSize(zoom)

    /** EPSG:3857 projected metres (x east, y north) for [p]. */
    fun toMetres(p: LatLon): Pair<Double, Double> {
        val lat = p.lat.coerceIn(-MAX_LAT, MAX_LAT)
        return EARTH_RADIUS * Math.toRadians(p.lon) to EARTH_RADIUS * ln(tan(PI / 4 + Math.toRadians(lat) / 2))
    }

    fun fromMetres(x: Double, y: Double): LatLon =
        LatLon(Math.toDegrees(2 * atan(exp(y / EARTH_RADIUS)) - PI / 2), Math.toDegrees(x / EARTH_RADIUS))

    private const val EARTH_RADIUS = 6_378_137.0
}
