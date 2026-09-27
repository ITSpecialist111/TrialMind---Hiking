package com.trailmind.core.map

import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.OsGridRef
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.WebMercator
import kotlin.math.max
import kotlin.math.min

/** Which tiles an offline pack needs: a rectangle, or a corridor around a route (much smaller). */
object TileCoverage {
    // Offshore WGS84 envelope: sea separators around Ireland/Man/Channel, with margins beyond GB's outer islands, not a coastline simplification.
    private val gbBoundary = listOf(
        LatLon(49.75, -6.65), LatLon(50.30, -6.65), LatLon(51.70, -5.70),
        LatLon(53.30, -5.50), LatLon(53.80, -5.00), LatLon(54.25, -4.00),
        LatLon(54.50, -4.00), LatLon(54.52, -4.85), LatLon(54.70, -5.20),
        LatLon(55.05, -5.40), LatLon(55.32, -6.00), LatLon(55.48, -6.40),
        LatLon(55.50, -7.00), LatLon(56.80, -8.00), LatLon(57.40, -9.00),
        LatLon(58.50, -9.00), LatLon(59.50, -7.00), LatLon(61.30, -2.50),
        LatLon(61.30, 0.50), LatLon(59.30, 0.00), LatLon(58.00, 0.00),
        LatLon(56.00, 0.50), LatLon(54.00, 0.50), LatLon(52.00, 2.20),
        LatLon(51.20, 1.75), LatLon(50.85, 1.35), LatLon(50.50, 0.30),
        LatLon(50.00, -1.50), LatLon(49.75, -3.00),
    ).map(OsGrid::project)
    private val gbEdges = gbBoundary.zip(gbBoundary.drop(1) + gbBoundary.first())

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

    fun bngBox(box: BoundingBox, minZoom: Int, maxZoom: Int): Sequence<TileKey> {
        val midLat = (box.minLat + box.maxLat) / 2
        val midLon = (box.minLon + box.maxLon) / 2
        val corners = listOf(
            LatLon(box.minLat, box.minLon), LatLon(box.minLat, midLon), LatLon(box.minLat, box.maxLon),
            LatLon(midLat, box.minLon), LatLon(midLat, box.maxLon),
            LatLon(box.maxLat, box.minLon), LatLon(box.maxLat, midLon), LatLon(box.maxLat, box.maxLon),
        ).map(OsGrid::project)
        return (minZoom..maxZoom).asSequence().flatMap { z ->
            bngRange(corners.minOf { it.easting }, corners.maxOf { it.easting },
                corners.minOf { it.northing }, corners.maxOf { it.northing }, z)
        }
    }

    fun bngCorridor(points: List<LatLon>, bufferM: Double, z: Int): List<TileKey> {
        if (points.isEmpty()) return emptyList()
        require(bufferM >= 0)
        val grid = points.map(OsGrid::project)
        val tiles = LinkedHashSet<TileKey>()
        val segments = (0 until max(1, grid.size - 1)).flatMap { index ->
            clipToGb(grid[index], grid[min(index + 1, grid.lastIndex)])
        }
        for ((a, b) in segments) {
            for (tile in bngRange(min(a.easting, b.easting) - bufferM, max(a.easting, b.easting) + bufferM,
                min(a.northing, b.northing) - bufferM, max(a.northing, b.northing) + bufferM, z)) {
                val west = BngTiles.easting(tile.x, z)
                val east = BngTiles.easting(tile.x + 1, z)
                val north = BngTiles.northing(tile.y, z)
                val south = BngTiles.northing(tile.y + 1, z)
                fun distanceSquared(e: Double, n: Double): Double {
                    val dx = b.easting - a.easting
                    val dy = b.northing - a.northing
                    val t = if (dx == 0.0 && dy == 0.0) 0.0 else
                        (((e - a.easting) * dx + (n - a.northing) * dy) / (dx * dx + dy * dy)).coerceIn(0.0, 1.0)
                    val de = e - a.easting - t * dx
                    val dn = n - a.northing - t * dy
                    return de * de + dn * dn
                }
                val crosses = segmentCrossesBox(a.easting, a.northing, b.easting, b.northing, west, east, south, north)
                val closestEndpoint = listOf(a, b).any {
                    val de = it.easting - it.easting.coerceIn(west, east)
                    val dn = it.northing - it.northing.coerceIn(south, north)
                    de * de + dn * dn <= bufferM * bufferM
                }
                if (crosses || closestEndpoint || listOf(west to south, west to north, east to south, east to north)
                        .any { (e, n) -> distanceSquared(e, n) <= bufferM * bufferM }) tiles.add(tile)
            }
        }
        return tiles.sortedWith(compareBy({ it.x }, { it.y }))
    }

    fun bngCorridor(points: List<LatLon>, bufferM: Double, minZoom: Int, maxZoom: Int): Sequence<TileKey> =
        (minZoom..maxZoom).asSequence().flatMap { bngCorridor(points, bufferM, it).asSequence() }

    fun bngCorridorCount(points: List<LatLon>, bufferM: Double, minZoom: Int, maxZoom: Int): Long =
        (minZoom..maxZoom).sumOf { bngCorridor(points, bufferM, it).size.toLong() }

    private fun bngRange(minE: Double, maxE: Double, minN: Double, maxN: Double, z: Int): Sequence<TileKey> {
        require(z in 0..9)
        val west = max(minE, max(0.0, gbBoundary.minOf { it.easting }))
        val east = min(maxE, gbBoundary.maxOf { it.easting })
        val south = max(minN, max(0.0, gbBoundary.minOf { it.northing }))
        val north = min(maxN, gbBoundary.maxOf { it.northing })
        if (west > east || south > north || !gbIntersectsBox(west, east, south, north)) return emptySequence()
        return (BngTiles.column(west, z)..BngTiles.column(east, z)).asSequence().flatMap { column ->
            (BngTiles.row(north, z)..BngTiles.row(south, z)).asSequence().map { row -> TileKey(z, column, row) }
        }.filter { tile ->
            gbIntersectsBox(max(west, BngTiles.easting(tile.x, z)), min(east, BngTiles.easting(tile.x + 1, z)),
                max(south, BngTiles.northing(tile.y + 1, z)), min(north, BngTiles.northing(tile.y, z)))
        }
    }

    private fun inGb(easting: Double, northing: Double): Boolean {
        var inside = false
        for ((start, end) in gbEdges) {
            if ((start.northing > northing) != (end.northing > northing) &&
                easting < start.easting + (end.easting - start.easting) *
                (northing - start.northing) / (end.northing - start.northing)) inside = !inside
        }
        return inside
    }

    private fun gbIntersectsBox(west: Double, east: Double, south: Double, north: Double): Boolean =
        listOf(west to south, west to north, east to south, east to north).any { (easting, northing) -> inGb(easting, northing) } ||
            gbEdges.any { (start, end) -> segmentCrossesBox(start.easting, start.northing, end.easting, end.northing, west, east, south, north) }

    private fun clipToGb(start: OsGridRef, end: OsGridRef): List<Pair<OsGridRef, OsGridRef>> {
        val eastDelta = end.easting - start.easting
        val northDelta = end.northing - start.northing
        val cuts = mutableListOf(0.0, 1.0)
        for ((edgeStart, edgeEnd) in gbEdges) {
            val edgeEast = edgeEnd.easting - edgeStart.easting
            val edgeNorth = edgeEnd.northing - edgeStart.northing
            val determinant = eastDelta * edgeNorth - northDelta * edgeEast
            if (determinant == 0.0) continue
            val offsetEast = edgeStart.easting - start.easting
            val offsetNorth = edgeStart.northing - start.northing
            val along = (offsetEast * edgeNorth - offsetNorth * edgeEast) / determinant
            val edgeAlong = (offsetEast * northDelta - offsetNorth * eastDelta) / determinant
            if (along in 0.0..1.0 && edgeAlong in 0.0..1.0) cuts.add(along)
        }
        fun at(fraction: Double) = OsGridRef(start.easting + eastDelta * fraction, start.northing + northDelta * fraction)
        return cuts.distinct().sorted().zipWithNext().mapNotNull { (from, to) ->
            val midpoint = at((from + to) / 2)
            if (inGb(midpoint.easting, midpoint.northing)) at(from) to at(to) else null
        }
    }

    private fun segmentCrossesBox(ax: Double, ay: Double, bx: Double, by: Double,
                                  west: Double, east: Double, south: Double, north: Double): Boolean {
        var start = 0.0
        var end = 1.0
        val dx = bx - ax
        val dy = by - ay
        for ((p, q) in listOf(-dx to ax - west, dx to east - ax, -dy to ay - south, dy to north - ay)) {
            if (p == 0.0) { if (q < 0) return false }
            else {
                val t = q / p
                if (p < 0) start = max(start, t) else end = min(end, t)
                if (start > end) return false
            }
        }
        return true
    }
}
