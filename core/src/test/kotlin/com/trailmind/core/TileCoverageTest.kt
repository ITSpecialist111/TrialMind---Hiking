package com.trailmind.core

import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.WebMercator
import com.trailmind.core.map.BngTiles
import com.trailmind.core.map.TileCoverage
import com.trailmind.core.map.TileFootprint
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TileCoverageTest {
    @Test
    fun boxMatchesCount() {
        val box = BoundingBox(54.40, -3.20, 54.50, -3.00)
        assertEquals(WebMercator.countTiles(box, 12, 15), TileCoverage.box(box, 12, 15).count().toLong())
    }

    @Test
    fun corridorIsContiguousAndSmallerThanBox() {
        val start = LatLon(54.45, -3.20)
        val points = (0..40).map { Geo.destination(start, 60.0, it * 500.0) } // 20 km diagonal
        val z = 15
        val corridor = TileCoverage.corridor(points, 500.0, z)
        val box = BoundingBox.of(points)!!.expandedByMetres(500.0)
        val boxCount = WebMercator.tileRange(box, z).count
        assertTrue(corridor.size < boxCount / 2, "corridor=${corridor.size} box=$boxCount")
        // every route point's own tile is included
        points.forEach { assertTrue(WebMercator.tileFor(it, z) in corridor) }
        assertEquals(corridor.size.toLong(), TileCoverage.corridorCount(points, 500.0, z, z))
        assertEquals(corridor.toSet().size, corridor.size)
    }

    private fun edges(f: TileFootprint) = f.edges.toList().chunked(4)
    private fun perimeter(f: TileFootprint) = edges(f).sumOf { (x0, y0, x1, y1) -> abs(x1 - x0) + abs(y1 - y0) }

    @Test
    fun footprintOfARectangleIsOneSpanPerRowAndFourEdges() {
        val f = TileFootprint.of(16, IntArray(6) { 10 + it % 3 }, IntArray(6) { 20 + it / 3 })!!
        assertEquals(listOf(20, 10, 13, 21, 10, 13), f.spans.toList())
        assertEquals(
            setOf(listOf(10, 20, 13, 20), listOf(10, 22, 13, 22), listOf(10, 20, 10, 22), listOf(13, 20, 13, 22)),
            edges(f).toSet(),
        )
        assertEquals(listOf(10, 20, 13, 22), listOf(f.minX, f.minY, f.maxX, f.maxY))
    }

    @Test
    fun footprintOutlinesAnLShapeWithoutInnerEdges() {
        // ##
        // #   (the last cell is listed twice)
        val f = TileFootprint.of(5, intArrayOf(0, 1, 0, 0), intArrayOf(0, 0, 1, 1))!!
        assertEquals(listOf(0, 0, 2, 1, 0, 1), f.spans.toList())
        assertEquals(6, edges(f).size)
        assertEquals(8, perimeter(f))
    }

    @Test
    fun footprintOfNoTilesIsNull() {
        assertNull(TileFootprint.of(3, IntArray(0), IntArray(0)))
    }

    @Test
    fun bngTilesMatchTheOsGrid() {
        assertEquals(896.0, BngTiles.resolution(0))
        assertEquals(1.75, BngTiles.resolution(9))
        // New Fancy View is in Leisure_27700 zoom 9 tile 1342/2604.
        val g = OsGrid.project(LatLon(51.78340, -2.53921))
        assertEquals(1342, BngTiles.column(g.easting, 9))
        assertEquals(2604, BngTiles.row(g.northing, 9))
        assertTrue(g.easting in BngTiles.easting(1342, 9)..BngTiles.easting(1343, 9))
        assertTrue(g.northing in BngTiles.northing(2605, 9)..BngTiles.northing(2604, 9))
        // OS's capabilities give zoom 0 as 5 columns by 7 rows.
        assertEquals(4, BngTiles.column(BngTiles.GB_MAX_E, 0))
        assertEquals(6, BngTiles.row(0.0, 0))
        assertEquals(listOf(9, 9, 8, 9, 0), listOf(1.75, 1.2, 3.0, 0.2, 5000.0).map { BngTiles.zoomFor(it, 0, 9) })
    }

    @Test
    fun footprintOfACorridorMatchesItsTiles() {
        val start = LatLon(51.73, -2.53)
        val points = (0..30).map { Geo.destination(start, 20.0 + it * 5, it * 300.0) }
        val tiles = TileCoverage.corridor(points, 250.0, 16)
        val set = tiles.map { it.x to it.y }.toSet()
        val f = TileFootprint.of(16, IntArray(tiles.size) { tiles[it].x }, IntArray(tiles.size) { tiles[it].y })!!
        assertEquals(tiles.size, f.spans.toList().chunked(3).sumOf { (_, x0, x1) -> x1 - x0 })
        val exposedSides = tiles.sumOf { t -> listOf(-1 to 0, 1 to 0, 0 to -1, 0 to 1).count { (dx, dy) -> (t.x + dx to t.y + dy) !in set } }
        assertEquals(exposedSides, perimeter(f))
        assertTrue(edges(f).size < exposedSides, "collinear edges are merged")
    }
}
