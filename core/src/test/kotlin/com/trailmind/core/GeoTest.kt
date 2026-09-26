package com.trailmind.core

import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.MagneticCheck
import com.trailmind.core.geo.NorthAnchor
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.PathJoin
import com.trailmind.core.geo.PlaceQuery
import com.trailmind.core.geo.Sun
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.WebMercator
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GeoTest {
    @Test
    fun webMercatorMetresRoundTrip() {
        // Offa's Dyke Path's southern end at Sedbury Cliffs, as Waymarked Trails reports it.
        val p = WebMercator.fromMetres(-294810.17, 6733952.16)
        assertEquals(51.633, p.lat, 0.002)
        assertEquals(-2.648, p.lon, 0.002)
        val (x, y) = WebMercator.toMetres(p)
        assertEquals(-294810.17, x, 0.01)
        assertEquals(6733952.16, y, 0.01)
        assertEquals(20_037_508.34, WebMercator.toMetres(LatLon(0.0, 180.0)).first, 0.01)
    }

    @Test
    fun pathJoinOrientsAndChainsPieces() {
        fun pt(lon: Double) = TrackPoint(54.0, lon)
        val a = listOf(pt(0.000), pt(0.001))
        val bReversed = listOf(pt(0.003), pt(0.002), pt(0.001))
        assertEquals(listOf(0.000, 0.001, 0.002, 0.003), PathJoin.join(listOf(a, bReversed)).map { it.lon })
        // A first piece stored backwards is flipped so the line does not start with a jump.
        assertEquals(listOf(0.000, 0.001, 0.002, 0.003), PathJoin.join(listOf(a.reversed(), listOf(pt(0.002), pt(0.003)))).map { it.lon })
        // Unordered sections are chained nearest end first.
        val far = listOf(pt(0.010), pt(0.011))
        val near = listOf(pt(0.002), pt(0.003))
        assertEquals(listOf(0.000, 0.001, 0.002, 0.003, 0.010, 0.011), PathJoin.join(listOf(a, far, near), ordered = false).map { it.lon })
        // Ordered sections keep their order and are only flipped.
        assertEquals(listOf(0.000, 0.001, 0.010, 0.011, 0.003, 0.002), PathJoin.join(listOf(a, far, near)).map { it.lon })
    }

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
    fun osGridInverseMatchesOrdnanceSurveyWorkedExample() {
        val p = OsGrid.unprojectOsgb36(651409.903, 313177.270)
        assertEquals(52.0 + 39.0 / 60 + 27.2531 / 3600, p.lat, 1e-7)
        assertEquals(1.0 + 43.0 / 60 + 4.5177 / 3600, p.lon, 1e-7)
    }

    @Test
    fun osGridRoundTripsThroughWgs84() {
        // Forest of Dean, Ben Nevis, Westminster, John o' Groats, Land's End.
        for (p in listOf(LatLon(51.7834, -2.5392), LatLon(56.796891, -5.003675), LatLon(51.5007, -0.1246), LatLon(58.64, -3.07), LatLon(50.07, -5.71))) {
            val g = OsGrid.project(p)
            val back = OsGrid.toWgs84(g.easting, g.northing)
            assertEquals(p.lat, back.lat, 1e-7, "lat of $p")
            assertEquals(p.lon, back.lon, 1e-7, "lon of $p")
        }
    }

    @Test
    fun gridLetters() {
        assertEquals("SV", OsGrid.letters(0.0, 0.0))
        assertEquals("NN", OsGrid.letters(216667.0, 771278.0))
        assertEquals("SD", OsGrid.letters(350000.0, 450000.0))
        assertNull(OsGrid.letters(-1.0, 0.0))
    }

    @Test
    fun parseGridReferences() {
        val reference = assertNotNull(OsGrid.parse("SO 628 094"))
        assertEquals(362850.0, reference.easting)
        assertEquals(209450.0, reference.northing)
        assertEquals(100, reference.precisionM)
        assertEquals(reference, OsGrid.parse("so628094"))
        assertEquals(1, assertNotNull(OsGrid.parse("SO 62800 09400")).precisionM)
        assertEquals(1000, assertNotNull(OsGrid.parse("SO6209")).precisionM)
        assertEquals(100000, assertNotNull(OsGrid.parse("SO")).precisionM)
        for (invalid in listOf("SI 628 094", "SO62809", "SO123456789012", "ZZ", "SO 12 X4")) assertNull(OsGrid.parse(invalid))
        for (east in 0..6) for (north in 0..12) {
            val letters = assertNotNull(OsGrid.letters(east * 100_000.0, north * 100_000.0))
            val square = assertNotNull(OsGrid.parse(letters))
            assertEquals(east * 100_000.0 + 50_000, square.easting)
            assertEquals(north * 100_000.0 + 50_000, square.northing)
            assertFalse('I' in letters)
        }
        for (digits in listOf(2, 4, 6, 8, 10)) {
            val formatted = assertNotNull(com.trailmind.core.geo.OsGridRef(362800.0, 209400.0).format(digits))
            val parsed = assertNotNull(OsGrid.parse(formatted))
            assertEquals(formatted, com.trailmind.core.geo.OsGridRef(parsed.easting, parsed.northing).format(digits))
        }
    }

    @Test
    fun parseDecimalCoordinates() {
        val point = LatLon(51.7834, -2.5392)
        for (input in listOf("51.7834, -2.5392", "51.7834 -2.5392", "51.7834N 2.5392W")) {
            assertEquals(point, PlaceQuery.coordinates(input))
        }
        for (input in listOf("91, 0", "0 -181", "51.5N -2W", "51.5 2.1 3", "hello", "NaN, 0")) {
            assertNull(PlaceQuery.coordinates(input))
        }
        assertTrue(PlaceQuery.looksLikeCoordinates("91, 0"))
        assertTrue(PlaceQuery.looksLikeGrid("SI 123 456"))
        assertTrue(PlaceQuery.looksLikeGrid("SO 12345"))
        assertFalse(PlaceQuery.looksLikeGrid("Speech House"))
        assertFalse(PlaceQuery.looksLikeCoordinates("GL15 4HS"))
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

    // Lydney: about 49.2 µT, dipping 66.3°. In east/north/up that is (0, 19.8, -45.1).
    @Test
    fun magneticCheckAcceptsTheEarthsFieldFlatOrUpright() {
        val flat = MagneticCheck().apply { expect(49.2, 66.3) }
        repeat(10) { flat.add(0.0, 19.8, -45.1, 0.0, 0.0, 1.0) }
        assertFalse(flat.disturbed)
        // Upright with the back facing north: device y is up and z faces south.
        val upright = MagneticCheck().apply { expect(49.2, 66.3) }
        repeat(10) { upright.add(0.0, -45.1, -19.8, 0.0, 1.0, 0.0) }
        assertFalse(upright.disturbed)
        assertEquals(66.3, upright.dipDeg, 0.5)
    }

    @Test
    fun magneticCheckFlagsRealReadingsThatReportedNoProblem() {
        // Fold7 on a desk, reporting itself fully calibrated: a plausible dip, but 86 µT.
        val phone = MagneticCheck().apply { expect(49.2, 66.3) }
        repeat(5) { phone.add(32.64, -24.71, -75.32, -0.0366, 0.0202, 0.9991) }
        assertTrue(phone.disturbed)
        assertEquals(63.8, phone.dipDeg, 0.5)
        // Watch4 face up on its magnetic charger: a plausible strength, but the field points up.
        val watch = MagneticCheck().apply { expect(49.2, 66.3) }
        repeat(5) { watch.add(-9.72, 32.10, 46.80, 0.0, 0.0, 1.0) }
        assertTrue(watch.disturbed)
    }

    @Test
    fun magneticCheckWaitsForAPositionAndClearsOnceTheFieldIsClean() {
        val c = MagneticCheck()
        repeat(5) { c.add(32.64, -24.71, -75.32, 0.0, 0.0, 1.0) }
        assertFalse(c.disturbed, "nothing to compare with before a GPS fix")
        c.expect(49.2, 66.3)
        c.add(32.64, -24.71, -75.32, 0.0, 0.0, 1.0)
        assertTrue(c.disturbed)
        repeat(30) { c.add(0.0, 19.8, -45.1, 0.0, 0.0, 1.0) }
        assertFalse(c.disturbed)
    }

    // Row-major rotation matrices for a device lying flat whose top points [azimuthDeg] in the rotation vector's frame.
    private fun flat(azimuthDeg: Double): FloatArray {
        val a = Math.toRadians(azimuthDeg)
        val s = kotlin.math.sin(a).toFloat()
        val c = kotlin.math.cos(a).toFloat()
        return floatArrayOf(c, s, 0f, -s, c, 0f, 0f, 0f, 1f)
    }

    @Test
    fun northAnchorLeavesACorrectRotationVectorAlone() {
        val n = NorthAnchor()
        assertEquals(0.0, n.offsetDeg)
        // Flat, pointing magnetic north, and the rotation vector agrees: the field lies along the device's y.
        n.add(flat(0.0), 0.0, 19.8, -45.1)
        assertEquals(0.0, n.offsetDeg, 0.01)
    }

    @Test
    fun northAnchorCorrectsARotationVectorWhoseNorthIsOff() {
        // The watch points magnetic north, but a gyro-only rotation vector started 90 degrees off says east.
        val r = flat(90.0)
        val n = NorthAnchor()
        n.add(r, 0.0, 19.8, -45.1)
        val azimuth = Math.toDegrees(kotlin.math.atan2(r[1].toDouble(), r[4].toDouble()))
        assertEquals(90.0, azimuth, 0.01)
        assertEquals(0.0, Geo.normalizeDeg(azimuth - n.offsetDeg), 0.01)
        // Smoothing works across 180: readings of 170 and 190 average to 180, not 0.
        val w = NorthAnchor()
        repeat(200) { i -> w.add(flat(if (i % 2 == 0) 170.0 else 190.0), 0.0, 19.8, -45.1) }
        assertEquals(180.0, kotlin.math.abs(w.offsetDeg), 3.0)
    }
}
