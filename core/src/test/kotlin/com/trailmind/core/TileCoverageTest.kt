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
        assertEquals(BngTiles.column(g.easting, 5), BngTiles.column(g.easting, 9) shr 4)
        assertEquals(BngTiles.row(g.northing, 5), BngTiles.row(g.northing, 9) shr 4)
        assertTrue(g.easting in BngTiles.easting(1342, 9)..BngTiles.easting(1343, 9))
        assertTrue(g.northing in BngTiles.northing(2605, 9)..BngTiles.northing(2604, 9))
        // OS's capabilities give zoom 0 as 5 columns by 7 rows.
        assertEquals(4, BngTiles.column(BngTiles.GB_MAX_E, 0))
        assertEquals(6, BngTiles.row(0.0, 0))
        assertEquals(listOf(9, 9, 8, 9, 0), listOf(1.75, 1.2, 3.0, 0.2, 5000.0).map { BngTiles.zoomFor(it, 0, 9) })
    }

    @Test
    fun bngCoverageIncludesNewFancyAndClampsToGreatBritain() {
        val point = LatLon(51.78340, -2.53921)
        val tile = com.trailmind.core.geo.TileKey(9, 1342, 2604)
        assertTrue(tile in TileCoverage.bngCorridor(listOf(point), 250.0, 9))
        assertTrue(tile in TileCoverage.bngBox(BoundingBox(51.7833, -2.5393, 51.7835, -2.5391), 9, 9).toList())
        assertEquals(TileCoverage.bngCorridor(listOf(point), 250.0, 6, 9).count().toLong(),
            TileCoverage.bngCorridorCount(listOf(point), 250.0, 6, 9))
        assertTrue(TileCoverage.bngBox(BoundingBox(49.0, -10.0, 51.8, -2.5), 9, 9)
            .all { it.x >= BngTiles.column(0.0, 9) && it.y <= BngTiles.row(0.0, 9) })
    }

    @Test
    fun bngCoverageRejectsOverseasAndKeepsScilly() {
        val lydney = OsGrid.parse("SO 60 10")!!
        assertEquals(3 to 2, lydney.easting.toInt() / 100_000 to lydney.northing.toInt() / 100_000)
        assertEquals("SO", OsGrid.letters(lydney.easting, lydney.northing))
        val overseas = mapOf(
            "Paris" to BoundingBox(48.84, 2.29, 48.89, 2.40),
            "Dublin" to BoundingBox(53.32, -6.40, 53.39, -6.20),
            "Belfast" to BoundingBox(54.57, -5.96, 54.62, -5.89),
            "Calais" to BoundingBox(50.93, 1.83, 50.97, 1.88),
            "Jersey" to BoundingBox(49.18, -2.17, 49.23, -2.08),
        )
        for (zoom in 0..9) {
            assertEquals(emptyList(), overseas.filterValues { TileCoverage.bngBox(it, zoom, zoom).any() }.keys.toList(), "zoom $zoom")
            assertEquals(emptyList(), overseas.filterValues {
                TileCoverage.bngCorridor(listOf(LatLon(it.minLat, it.minLon), LatLon(it.maxLat, it.maxLon)), 250.0, zoom).isNotEmpty()
            }.keys.toList(), "corridor zoom $zoom")
        }
        val britishIslands = mapOf(
            "Dover" to BoundingBox(51.12, 1.30, 51.14, 1.33),
            "Scilly" to BoundingBox(49.89, -6.38, 49.94, -6.27),
            "Mull of Kintyre" to BoundingBox(55.29, -5.82, 55.34, -5.69),
            "St Kilda" to BoundingBox(57.78, -8.62, 57.85, -8.54),
            "Unst" to BoundingBox(60.72, -0.94, 60.79, -0.84),
        )
        assertEquals(emptyList(), britishIslands.filterValues { TileCoverage.bngBox(it, 9, 9).none() }.keys.toList())
    }

    @Test
    fun bngCorridorCoversTheFullSegmentNotOnlyItsEndpoints() {
        val start = LatLon(51.78340, -2.53921)
        val end = Geo.destination(start, 90.0, 3_000.0)
        val middle = OsGrid.project(Geo.destination(start, 90.0, 1_500.0))
        val tiles = TileCoverage.bngCorridor(listOf(start, end), 250.0, 9)
        assertTrue(com.trailmind.core.geo.TileKey(9, BngTiles.column(middle.easting, 9), BngTiles.row(middle.northing, 9)) in tiles)
        assertEquals(tiles.size, tiles.toSet().size)
    }

    @Test
    fun bngBoundarySeparatesBritishCoastsAndIslandsFromNeighboursAtEveryZoom() {
        val rejected = mapOf(
            "Rathlin" to LatLon(55.29, -6.20), "Ballycastle" to LatLon(55.20, -6.25),
            "Belfast" to LatLon(54.60, -5.93), "Ards" to LatLon(54.45, -5.45),
            "Douglas" to LatLon(54.15, -4.48), "Calais" to LatLon(50.95, 1.85),
            "Guernsey" to LatLon(49.45, -2.55), "Alderney" to LatLon(49.72, -2.20),
            "Point of Ayre" to LatLon(54.42, -4.37), "Malin Head" to LatLon(55.38, -7.37),
            "Dublin" to LatLon(53.35, -6.26),
        )
        val kept = mapOf(
            "Scilly" to LatLon(49.90, -6.35), "Land's End" to LatLon(50.07, -5.72),
            "Dover" to LatLon(51.13, 1.32), "Mull of Kintyre" to LatLon(55.29, -5.80),
            "Islay" to LatLon(55.59, -6.31), "Mull of Galloway" to LatLon(54.64, -4.86),
            "St Kilda" to LatLon(57.81, -8.58), "Orkney" to LatLon(58.98, -2.96),
            "Muckle Flugga" to LatLon(60.86, -0.89), "Sule Skerry" to LatLon(59.09, -4.41),
            "North Rona" to LatLon(59.12, -5.82), "Foula" to LatLon(60.14, -2.08),
            "Lowestoft" to LatLon(52.48, 1.76), "Dungeness" to LatLon(50.91, 0.98),
            "Isle of Wight" to LatLon(50.58, -1.30), "Pembrokeshire" to LatLon(51.88, -5.31),
        )
        for (zoom in 0..9) {
            for ((name, point) in rejected) {
                val box = BoundingBox(point.lat, point.lon, point.lat, point.lon).expandedByMetres(500.0)
                assertTrue(TileCoverage.bngBox(box, zoom, zoom).none(), "$name box z$zoom")
                assertTrue(TileCoverage.bngCorridor(listOf(point, Geo.destination(point, 90.0, 250.0)), 500.0, zoom).isEmpty(), "$name corridor z$zoom")
            }
            for ((name, point) in kept) {
                val grid = OsGrid.project(point)
                val tile = com.trailmind.core.geo.TileKey(zoom, BngTiles.column(grid.easting, zoom), BngTiles.row(grid.northing, zoom))
                assertTrue(tile in TileCoverage.bngBox(BoundingBox(point.lat, point.lon, point.lat, point.lon), zoom, zoom).toSet(), "$name box z$zoom")
                assertTrue(tile in TileCoverage.bngCorridor(listOf(point), 250.0, zoom), "$name corridor z$zoom")
            }
        }
    }

    @Test
    fun bngCoastalCorridorRetainsItsWholeLength() {
        val coast = listOf(LatLon(54.64, -4.86), LatLon(54.68, -4.88), LatLon(54.72, -4.95), LatLon(54.76, -4.99))
        for (zoom in 0..9) {
            val tiles = TileCoverage.bngCorridor(coast, 250.0, zoom)
            for ((start, end) in coast.zipWithNext()) for (step in 0..100) {
                val point = OsGrid.project(LatLon(start.lat + (end.lat - start.lat) * step / 100, start.lon + (end.lon - start.lon) * step / 100))
                assertTrue(com.trailmind.core.geo.TileKey(zoom, BngTiles.column(point.easting, zoom), BngTiles.row(point.northing, zoom)) in tiles, "Coast z$zoom step$step")
            }
        }
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
