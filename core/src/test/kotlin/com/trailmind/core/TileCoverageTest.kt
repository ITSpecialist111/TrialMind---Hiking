package com.trailmind.core

import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.WebMercator
import com.trailmind.core.map.TileCoverage
import kotlin.test.Test
import kotlin.test.assertEquals
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
}
