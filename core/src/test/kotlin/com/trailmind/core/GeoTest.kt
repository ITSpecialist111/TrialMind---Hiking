package com.trailmind.core

import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.Sun
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.WebMercator
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GeoTest {
    @Test
    fun haversineMatchesKnownDistance() {
        // Snowdon summit to Pen-y-Pass car park ≈ 3.66 km straight line.
        val d = Geo.distanceM(LatLon(53.0685, -4.0763), LatLon(53.0806, -4.0269))
        assertEquals(3_550.0, d, 150.0)
        assertEquals(0.0, Geo.distanceM(LatLon(1.0, 1.0), LatLon(1.0, 1.0)), 1e-9)
    }

    @Test
    fun bearingsAndCardinals() {
        assertEquals(0.0, Geo.bearingDeg(LatLon(50.0, 0.0), LatLon(51.0, 0.0)), 1e-6)
        assertEquals(90.0, Geo.bearingDeg(LatLon(0.0, 0.0), LatLon(0.0, 1.0)), 1e-6)
        assertEquals("N", Geo.cardinal(359.0))
        assertEquals("SW", Geo.cardinal(225.0))
        assertEquals(-20.0, Geo.angleDiffDeg(10.0, 350.0), 1e-9)
    }

    @Test
    fun destinationRoundTrip() {
        val start = LatLon(54.45, -3.21)
        val dest = Geo.destination(start, 45.0, 1000.0)
        assertEquals(1000.0, Geo.distanceM(start, dest), 0.5)
        assertEquals(45.0, Geo.bearingDeg(start, dest), 0.1)
    }

    @Test
    fun segmentProjection() {
        val a = LatLon(54.0, -3.0)
        val b = Geo.destination(a, 90.0, 1000.0)
        val mid = Geo.destination(Geo.destination(a, 90.0, 500.0), 0.0, 30.0)
        val p = Geo.projectOntoSegment(mid, a, b)
        assertEquals(0.5, p.fraction, 0.01)
        assertEquals(30.0, p.distanceM, 0.5)
    }

    @Test
    fun webMercatorRoundTripAndTiles() {
        val z = 14.0
        val x = WebMercator.lonToX(-3.1, z)
        val y = WebMercator.latToY(54.5, z)
        assertEquals(-3.1, WebMercator.xToLon(x, z), 1e-9)
        assertEquals(54.5, WebMercator.yToLat(y, z), 1e-9)
        // London at z10 is tile 511/340 (well-known value).
        assertEquals(TileKey(10, 511, 340), WebMercator.tileFor(LatLon(51.5074, -0.1278), 10))
        assertEquals(1, TileKey(1, 0, 0).tmsY)
        val box = BoundingBox(54.4, -3.3, 54.5, -3.1)
        val count = WebMercator.countTiles(box, 10, 14)
        assertTrue(count in 50..400, "count=$count")
    }

    @Test
    fun osGridProjectionMatchesOrdnanceSurveyWorkedExample() {
        // OS "A guide to coordinate systems in Great Britain", worked example (OSGB36 input).
        val lat = 52.0 + 39.0 / 60 + 27.2531 / 3600
        val lon = 1.0 + 43.0 / 60 + 4.5177 / 3600
        val ref = OsGrid.projectOsgb36(LatLon(lat, lon))
        assertEquals(651409.903, ref.easting, 0.01)
        assertEquals(313177.270, ref.northing, 0.01)
        assertEquals("TG 51409 13177", ref.format(10))
        assertEquals("TG 514 131", ref.format(6))
    }

    @Test
    fun osGridFromWgs84IsWithinHelmertAccuracy() {
        // Ben Nevis summit trig point: NN 16667 71278 (OS), WGS84 ≈ 56.796891, -5.003675.
        val ref = assertNotNull(OsGrid.fromWgs84(LatLon(56.796891, -5.003675)))
        assertEquals(216667.0, ref.easting, 15.0)
        assertEquals(771278.0, ref.northing, 15.0)
        assertTrue(ref.format(6)!!.startsWith("NN 166 77") || ref.format(6)!!.startsWith("NN 166 71"), ref.format(6))
        assertNull(OsGrid.fromWgs84(LatLon(48.85, 2.35)), "Paris is outside the National Grid")
    }

    @Test
    fun gridLetters() {
        assertEquals("SV", OsGrid.letters(0.0, 0.0))
        assertEquals("NN", OsGrid.letters(216667.0, 771278.0))
        assertEquals("SD", OsGrid.letters(350000.0, 450000.0))
        assertNull(OsGrid.letters(-1.0, 0.0))
    }

    @Test
    fun sunsetInLondonMidsummer() {
        val t = Sun.times(LocalDate.of(2025, 6, 21), LatLon(51.5074, -0.1278))
        val set = Instant.ofEpochMilli(t.sunsetMs!!).atZone(ZoneOffset.UTC)
        // Actual: 20:21 UTC (21:21 BST).
        val minutes = set.hour * 60 + set.minute
        assertTrue(abs(minutes - (20 * 60 + 21)) <= 5, "sunset was $set")
        val rise = Instant.ofEpochMilli(t.sunriseMs!!).atZone(ZoneOffset.UTC)
        assertTrue(abs(rise.hour * 60 + rise.minute - (3 * 60 + 43)) <= 5, "sunrise was $rise")
    }
}
