package com.trailmind.core

import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.WebMercator
import com.trailmind.core.map.Terrain
import kotlin.math.tan
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class TerrainTest {
    @Test fun decodesTerrariumRgb() {
        assertEquals(0f, Terrain.decodeTerrarium(128, 0, 0))
        assertEquals(123.5f, Terrain.decodeTerrarium(128, 123, 128))
    }

    @Test fun bilinearSamplingIsContinuousAcrossTileEdge() {
        val z = 2
        val eastTile = FloatArray(256 * 256) { index -> ((index % 256) + 256).toFloat() }
        val westTile = FloatArray(256 * 256) { index -> (index % 256).toFloat() }
        val lat = WebMercator.yToLat(100.5, z.toDouble())
        val lon = WebMercator.xToLon(256.25, z.toDouble())
        val sample = Terrain.heightAt(lat, lon, z) { key ->
            when (key) {
                TileKey(z, 0, 0) -> westTile
                TileKey(z, 1, 0) -> eastTile
                else -> null
            }
        }
        assertEquals(255.75, sample!!, 0.001)
    }

    @Test fun routeFillingPreservesExistingElevationAndPointMetadata() {
        val original = listOf(TrackPoint(51.0, -2.0, 123.0, 456L), TrackPoint(51.1, -2.1))
        val filled = Terrain.fillMissingHeights(original) { 200.0 }
        assertEquals(123.0, filled[0].ele)
        assertEquals(456L, filled[0].timeMs)
        assertEquals(200.0, filled[1].ele)
        assertEquals(original[1].lat, filled[1].lat)
    }

    /** Heights of a plane rising at [degrees] towards the east, padded as [Terrain.padded] would. */
    private fun plane(degrees: Double, mpp: Double, size: Int = 8): FloatArray {
        val rise = tan(Math.toRadians(degrees)) * mpp
        val centre = FloatArray(size * size) { i -> (100 + (i % size) * rise).toFloat() }
        return Terrain.padded(centre, size) { dx, _ -> FloatArray(size * size) { i -> (100 + ((i % size) + dx * size) * rise).toFloat() } }
    }

    @Test fun hornSlopeClassesMatchPlanesAndFlatGround() {
        val mpp = Terrain.metresPerPixel(51.8, 13)
        fun classOf(degrees: Double) = Terrain.slopeClasses(plane(degrees, mpp), 8) { mpp }.toSet().single().toInt()
        assertEquals(Terrain.SlopeClass.NONE.ordinal, classOf(0.0))
        assertEquals(Terrain.SlopeClass.NONE.ordinal, classOf(24.0))
        assertEquals(Terrain.SlopeClass.MODERATE.ordinal, classOf(26.0))
        assertEquals(Terrain.SlopeClass.STEEP.ordinal, classOf(31.0))
        assertEquals(Terrain.SlopeClass.VERY_STEEP.ordinal, classOf(36.0))
        assertEquals(Terrain.SlopeClass.EXTREME.ordinal, classOf(45.0))
    }

    @Test fun paddingUsesNeighbourEdgesAndRepeatsMissingOnes() {
        val centre = FloatArray(4) { it.toFloat() }
        val east = FloatArray(4) { 10f + it }
        val padded = Terrain.padded(centre, 2) { dx, dy -> if (dx == 1 && dy == 0) east else null }
        assertEquals(10f, padded[1 * 4 + 3])
        assertEquals(12f, padded[2 * 4 + 3])
        assertEquals(0f, padded[1 * 4 + 0])
        assertEquals(0f, padded[0])
    }

    @Test fun missingNeighbourTileMakesEdgeSampleUnavailable() {
        val lat = WebMercator.yToLat(100.5, 2.0)
        val lon = WebMercator.xToLon(256.25, 2.0)
        assertNull(Terrain.heightAt(lat, lon, 2) { null })
    }
}