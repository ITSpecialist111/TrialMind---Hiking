package com.trailmind.core

import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.OsGridRef
import com.trailmind.core.map.GeoTiff
import com.trailmind.core.map.Lidar
import com.trailmind.core.map.LidarRouteCheck
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.Deflater

class LidarTest {
    private fun resource(name: String): ByteArray =
        requireNotNull(javaClass.getResourceAsStream("/lidar/$name")) { "missing $name" }.use { it.readBytes() }

    @Test fun readsEnvironmentAgencyGeoTiff() {
        // A 32 m window on Helvellyn as the service sends it: big-endian, tiled, Deflate, GDAL no-data tag.
        val raster = GeoTiff.read(resource("helvellyn-32.tif"))
        assertEquals(32, raster.width)
        assertEquals(32, raster.height)
        assertEquals(334400.0, raster.left, 1e-6)
        assertEquals(515132.0, raster.top, 1e-6)
        assertEquals(1.0, raster.pixelWidth, 1e-9)
        assertEquals(1.0, raster.pixelHeight, 1e-9)
        assertEquals(830.788, raster.values[0].toDouble(), 0.005)
        assertEquals(849.97, raster.values[31 * 32 + 31].toDouble(), 0.005)
        assertTrue(raster.values.all { it in 818f..868f })
    }

    @Test fun squareOutsideCoverageReadsAsNoData() {
        // Snowdon is in Wales: the service fills the square with 0.0 and no no-data tag.
        val raster = GeoTiff.read(resource("snowdon-empty.tif"))
        assertEquals(256, raster.width)
        assertEquals(260864.0, raster.left, 1e-6)
        assertEquals(354560.0, raster.top, 1e-6)
        assertFalse(Lidar.clean(raster.values))
        assertTrue(raster.values.all { it.isNaN() })
        val helvellyn = GeoTiff.read(resource("helvellyn-32.tif")).values
        assertTrue(Lidar.clean(helvellyn))
        assertTrue(helvellyn.none { it.isNaN() })
    }

    @Test fun readsLittleEndianStripsUncompressedAndDeflated() {
        val values = floatArrayOf(1f, 2f, 3f, -9999f, 5f, 6f)
        for (deflate in listOf(false, true)) {
            val raster = GeoTiff.read(tiff(3, 2, values, ByteOrder.LITTLE_ENDIAN, deflate, "-9999"))
            assertEquals(3, raster.width)
            assertEquals(2, raster.height)
            assertEquals(1000.0, raster.left, 1e-9)
            assertEquals(2004.0, raster.top, 1e-9)
            assertEquals(2.0, raster.pixelWidth, 1e-9)
            assertEquals(listOf(1f, 2f, 3f), raster.values.take(3))
            assertTrue(raster.values[3].isNaN())
            assertEquals(6f, raster.values[5])
        }
    }

    @Test fun refusesWhatItCannotRead() {
        assertThrows<IOException> { GeoTiff.read(byteArrayOf(1, 2, 3)) }
        assertThrows<IOException> { GeoTiff.read(tiff(2, 1, floatArrayOf(1f, 2f), ByteOrder.BIG_ENDIAN, false, null, bits = 16)) }
        val good = tiff(2, 1, floatArrayOf(1f, 2f), ByteOrder.BIG_ENDIAN, false, null)
        assertThrows<IOException> { GeoTiff.read(good.copyOf(good.size - 4)) }
    }

    @Test fun squaresAlongARouteStayInTheExtent() {
        assertEquals(Lidar.Square(1306, 2012), Lidar.squareAt(334400.0, 515100.0))
        assertTrue(Lidar.Square(1306, 2012).inExtent)
        assertFalse(Lidar.squareAt(216666.0, 771275.0).inExtent) // Ben Nevis, beyond the composite
        val route = listOf(OsGridRef(334000.0, 515000.0), OsGridRef(334600.0, 515000.0))
        val squares = Lidar.corridor(route, 20.0)
        assertEquals(listOf(1304, 1305, 1306, 1307), squares.map { it.col })
        assertTrue(squares.all { it.row == 2011 })
        assertEquals(8, Lidar.corridor(route, 100.0).size)
        assertNull(Lidar.box(0.0, 0.0, 700_000.0, 700_000.0, 100))
        assertEquals(6, Lidar.box(334000.0, 515000.0, 334500.0, 515300.0, 100)?.size)
    }

    @Test fun heightIsInterpolatedBetweenPixelCentres() {
        val square = Lidar.Square(1305, 2012)
        val values = FloatArray(Lidar.SIZE * Lidar.SIZE) { i -> (i % Lidar.SIZE).toFloat() } // rises 1 m per metre east
        assertEquals(10.0, Lidar.height(values, square, square.east + 10.5, square.north + 100.0)!!, 1e-6)
        assertEquals(10.25, Lidar.height(values, square, square.east + 10.75, square.north + 100.0)!!, 1e-6)
        values.fill(Float.NaN)
        assertNull(Lidar.height(values, square, square.east + 10.5, square.north + 100.0))
    }

    @Test fun hillShadingIsLitFromTheNorthWest() {
        val level = Lidar.shade(0f, 0f)
        assertEquals(0.7071, level.toDouble(), 1e-3)
        // A slope rising to the east faces west, a slope rising to the north faces south (rows run south).
        assertTrue(Lidar.shade(1f, 0f) > level)
        assertTrue(Lidar.shade(0f, -1f) < level)
        assertTrue(Lidar.shade(1f, 1f) > Lidar.shade(-1f, -1f))
    }

    @Test fun cragsNeedSteepGroundAndRealHeight() {
        // A 10 m cliff between columns 99 and 101, a 1 m bank at column 200, and a 30° slope on rows 0..40.
        val heights = FloatArray(Lidar.SIZE * Lidar.SIZE) { i ->
            val row = i / Lidar.SIZE
            val col = i % Lidar.SIZE
            var h = 100f
            if (col >= 100) h += 10f
            if (col >= 200) h += 1f
            if (row < 40) h += (40 - row) * 0.577f
            h
        }
        val padded = Lidar.padded(heights) { _, _ -> null }
        val crags = Lidar.crags(padded)
        fun at(row: Int, col: Int) = crags[row * Lidar.SIZE + col]
        assertTrue(at(128, 99) || at(128, 100))
        assertFalse(at(128, 200) || at(128, 199))
        assertFalse(at(20, 50))
        assertFalse(at(128, 50))
        val colours = Lidar.overlay(padded, crags)
        assertEquals(Lidar.CRAG_COLOUR, colours[128 * Lidar.SIZE + if (at(128, 99)) 99 else 100])
        assertEquals(0, colours[128 * Lidar.SIZE + 50] ushr 24) // level ground stays clear
        assertTrue(colours[20 * Lidar.SIZE + 50] ushr 24 > 0) // the slope is shaded
    }

    @Test fun paddingUsesNeighboursAndRepeatsMissingEdges() {
        val centre = FloatArray(Lidar.SIZE * Lidar.SIZE) { 1f }
        val east = FloatArray(Lidar.SIZE * Lidar.SIZE) { 5f }
        val padded = Lidar.padded(centre) { dx, dy -> if (dx == 1 && dy == 0) east else null }
        val stride = Lidar.SIZE + 2 * Lidar.BORDER
        val midRow = (Lidar.BORDER + 100) * stride
        assertEquals(5f, padded[midRow + stride - 1])
        assertEquals(1f, padded[midRow])
        assertEquals(1f, padded[0])
    }

    @Test fun routeCheckFindsSteepGroundAndCragsBesideTheLine() {
        val e0 = 334_000.0
        val n0 = 515_000.0
        val route = listOf(OsGrid.toWgs84(e0, n0), OsGrid.toWgs84(e0 + 300, n0))
        val ground = object : LidarRouteCheck.Ground {
            override fun height(easting: Double, northing: Double): Double? = when {
                easting > e0 + 280 -> null
                easting < e0 + 100 -> 100.0
                easting < e0 + 120 -> 100.0 + (easting - e0 - 100) // 45° for 20 m
                else -> 120.0
            }
            override fun crag(easting: Double, northing: Double) =
                kotlin.math.abs(easting - (e0 + 200)) <= 1.5 && kotlin.math.abs(northing - (n0 + 6)) < 0.5
        }
        val report = LidarRouteCheck.check(route, ground)
        assertEquals(300.0, report.lengthM, 0.5)
        assertEquals(280.0, report.coveredM, 2.0)
        assertEquals(1, report.steep.size)
        val steep = report.steep.single()
        assertTrue(steep.startM in 88.0..102.0 && steep.endM in 118.0..132.0, "$steep")
        assertEquals(45.0, steep.value, 1.0)
        assertEquals(1, report.crags.size)
        val crag = report.crags.single()
        assertTrue(crag.startM in 190.0..204.0, "$crag")
        assertEquals(6.0, crag.value, 1.1)
        assertNotNull(crag.at)
    }

    @Test fun levelRouteHasNothingToReport() {
        val route = listOf(LatLon(54.5, -3.0), OsGrid.toWgs84(OsGrid.project(LatLon(54.5, -3.0)).easting + 500, OsGrid.project(LatLon(54.5, -3.0)).northing))
        val report = LidarRouteCheck.check(route, object : LidarRouteCheck.Ground {
            override fun height(easting: Double, northing: Double) = 200.0 + easting * 0.1 // about 6°
            override fun crag(easting: Double, northing: Double) = false
        })
        assertTrue(report.steep.isEmpty() && report.crags.isEmpty())
        assertEquals(report.lengthM, report.coveredM, 1e-6)
    }

    @Test fun routeIsSampledEveryMetreAndCragsAreFoundBesideGapsInTheSurvey() {
        val e0 = 334_000.0
        val n0 = 515_000.0
        // Points 1.9 m apart, as a recorded track can have.
        val route = (0..10).map { OsGrid.toWgs84(e0 + it * 1.9, n0) }
        val sampled = ArrayList<Double>()
        LidarRouteCheck.check(route, object : LidarRouteCheck.Ground {
            override fun height(easting: Double, northing: Double): Double { sampled += easting; return 100.0 }
            override fun crag(easting: Double, northing: Double) = false
        })
        assertTrue(sampled.zipWithNext().all { (a, b) -> b - a <= 1.05 }, "$sampled")
        // No heights on the line itself (water, say), and a crag 5 m beside it.
        val report = LidarRouteCheck.check(route, object : LidarRouteCheck.Ground {
            override fun height(easting: Double, northing: Double): Double? = null
            override fun crag(easting: Double, northing: Double) = easting >= e0 + 9 && easting < e0 + 10 && northing in (n0 + 4.5)..(n0 + 5.5)
        })
        assertEquals(0.0, report.coveredM)
        assertEquals(5.0, report.crags.single().value, 0.2)
    }

    @Test fun edgeSquaresArePlacedWhereTheServiceClipsThem() {
        val square = Lidar.Square(312, 40) // straddles the survey's west edge at E 80,000
        val top = square.north + 256.0
        val whole = GeoTiff.Raster(256, 256, FloatArray(256 * 256) { 5f }, square.east.toDouble(), top, 1.0, 1.0)
        assertTrue(Lidar.place(whole, square) === whole.values)
        // At the west edge the service sends only the 128 columns from E 80,000.
        val west = Lidar.place(GeoTiff.Raster(128, 256, FloatArray(128 * 256) { 7f }, 80_000.0, top, 1.0, 1.0), square)!!
        assertTrue(west[0].isNaN() && west[255 * 256 + 127].isNaN())
        assertEquals(7f, west[128])
        assertEquals(7f, west[255 * 256 + 255])
        // At the north edge it sends the rows below it.
        val north = Lidar.place(GeoTiff.Raster(256, 168, FloatArray(256 * 168) { 3f }, square.east.toDouble(), top - 88, 1.0, 1.0), square)!!
        assertTrue(north[87 * 256].isNaN())
        assertEquals(3f, north[88 * 256])
        // Anything not on the square's 1 m grid is refused.
        assertNull(Lidar.place(GeoTiff.Raster(256, 256, whole.values, square.east + 0.5, top, 1.0, 1.0), square))
        assertNull(Lidar.place(GeoTiff.Raster(128, 128, FloatArray(128 * 128), square.east.toDouble(), top, 2.0, 2.0), square))
        assertNull(Lidar.place(GeoTiff.Raster(256, 256, whole.values, square.east + 128.0, top, 1.0, 1.0), square))
    }

    /** A one-strip, single-band float TIFF with tie point (1000, 2004) and 2 m pixels. */
    private fun tiff(width: Int, height: Int, values: FloatArray, order: ByteOrder, deflate: Boolean, noData: String?, bits: Int = 32): ByteArray {
        val pixels = ByteBuffer.allocate(values.size * 4).order(order).apply { values.forEach { putFloat(it) } }.array()
        val strip = if (!deflate) pixels else ByteArrayOutputStream().also { out ->
            val d = Deflater()
            d.setInput(pixels); d.finish()
            val chunk = ByteArray(1024)
            while (!d.finished()) out.write(chunk, 0, d.deflate(chunk))
            d.end()
        }.toByteArray()
        val ascii = noData?.let { (it + "\u0000").toByteArray(Charsets.US_ASCII) }
        data class Entry(val tag: Int, val type: Int, val count: Int, val inline: Long? = null, val data: ByteArray? = null)
        fun doubles(vararg d: Double) = ByteBuffer.allocate(d.size * 8).order(order).apply { d.forEach { putDouble(it) } }.array()
        val entries = listOfNotNull(
            Entry(256, 3, 1, width.toLong()), Entry(257, 3, 1, height.toLong()), Entry(258, 3, 1, bits.toLong()),
            Entry(259, 3, 1, if (deflate) 8 else 1), Entry(273, 4, 1, data = strip), Entry(277, 3, 1, 1),
            Entry(278, 3, 1, height.toLong()), Entry(279, 4, 1, strip.size.toLong()), Entry(339, 3, 1, 3),
            Entry(33550, 12, 3, data = doubles(2.0, 2.0, 0.0)), Entry(33922, 12, 6, data = doubles(0.0, 0.0, 0.0, 1000.0, 2004.0, 0.0)),
            ascii?.let { Entry(42113, 2, it.size, data = it) },
        )
        val ifdSize = 2 + entries.size * 12 + 4
        var dataAt = 8 + ifdSize
        val offsets = entries.map { e -> if (e.data == null || (e.tag != 273 && e.data.size <= 4)) -1 else dataAt.also { dataAt += e.data.size } }
        val out = ByteBuffer.allocate(dataAt).order(order)
        out.put(if (order == ByteOrder.LITTLE_ENDIAN) "II".toByteArray() else "MM".toByteArray())
        out.putShort(42); out.putInt(8)
        out.putShort(entries.size.toShort())
        entries.forEachIndexed { i, e ->
            out.putShort(e.tag.toShort()); out.putShort(e.type.toShort()); out.putInt(e.count)
            when {
                e.tag == 273 -> out.putInt(offsets[i])
                e.data != null -> out.putInt(offsets[i])
                e.type == 3 -> { out.putShort(e.inline!!.toInt().toShort()); out.putShort(0) }
                else -> out.putInt(e.inline!!.toInt())
            }
        }
        out.putInt(0)
        entries.forEachIndexed { i, e -> if (offsets[i] >= 0) { out.position(offsets[i]); out.put(e.data!!) } }
        return out.array()
    }
}
