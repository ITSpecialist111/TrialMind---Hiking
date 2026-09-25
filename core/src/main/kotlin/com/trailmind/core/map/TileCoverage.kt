package com.trailmind.core.map

import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.WebMercator

/** Which tiles an offline pack needs: a rectangle, or a corridor around a route (much smaller). */
object TileCoverage {
    fun box(box: BoundingBox, minZoom: Int, maxZoom: Int): Sequence<TileKey> =
        (minZoom..maxZoom).asSequence().flatMap { WebMercator.tileRange(box, it).tiles() }

    fun corridor(points: List<LatLon>, bufferM: Double, z: Int): List<TileKey> {
        if (points.isEmpty()) return emptyList()
        val out = LinkedHashSet<TileKey>()
        val step = bufferM.coerceAtLeast(25.0)
        fun addAround(p: LatLon) {
            val b = BoundingBox(p.lat, p.lon, p.lat, p.lon).expandedByMetres(bufferM)
            out.addAll(WebMercator.tileRange(b, z).tiles())
        }
        addAround(points.first())
        for (i in 1 until points.size) {
            val a = points[i - 1]
            val b = points[i]
            val d = Geo.distanceM(a, b)
            val n = (d / step).toInt()
            for (k in 1..n) {
                val t = k * step / d
                addAround(LatLon(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t))
            }
            addAround(b)
        }
        return out.sortedWith(compareBy({ it.x }, { it.y }))
    }

    fun corridor(points: List<LatLon>, bufferM: Double, minZoom: Int, maxZoom: Int): Sequence<TileKey> =
        (minZoom..maxZoom).asSequence().flatMap { corridor(points, bufferM, it).asSequence() }

    fun corridorCount(points: List<LatLon>, bufferM: Double, minZoom: Int, maxZoom: Int): Long =
        (minZoom..maxZoom).sumOf { corridor(points, bufferM, it).size.toLong() }
}
