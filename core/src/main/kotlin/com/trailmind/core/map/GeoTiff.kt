package com.trailmind.core.map

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.DataFormatException
import java.util.zip.Inflater

/**
 * Reads single-band 32-bit float GeoTIFFs, the format elevation web services return: strips or tiles, uncompressed
 * or Deflate, either byte order, north-up georeferencing. Anything else is refused with an [IOException].
 */
object GeoTiff {
    class Raster(
        val width: Int,
        val height: Int,
        /** Row-major from the top row; NaN where the file has no data. */
        val values: FloatArray,
        /** Map position of the top-left corner of the top-left pixel. */
        val left: Double,
        val top: Double,
        val pixelWidth: Double,
        val pixelHeight: Double,
    )

    private const val MAX_PIXELS = 4_194_304

    fun read(bytes: ByteArray): Raster {
        try {
            return parse(bytes)
        } catch (e: IndexOutOfBoundsException) {
            throw IOException("truncated TIFF", e)
        } catch (e: IllegalArgumentException) {
            throw IOException("malformed TIFF", e)
        }
    }

    private fun parse(bytes: ByteArray): Raster {
        if (bytes.size < 8) throw IOException("not a TIFF")
        val order = when {
            bytes[0] == 'I'.code.toByte() && bytes[1] == 'I'.code.toByte() -> ByteOrder.LITTLE_ENDIAN
            bytes[0] == 'M'.code.toByte() && bytes[1] == 'M'.code.toByte() -> ByteOrder.BIG_ENDIAN
            else -> throw IOException("not a TIFF")
        }
        val buf = ByteBuffer.wrap(bytes).order(order)
        if (buf.getShort(2).toInt() != 42) throw IOException("unsupported TIFF variant")
        val tags = Tags(buf, buf.getInt(4).toLong() and 0xFFFF_FFFFL)

        val width = tags.int(256) ?: throw IOException("no width")
        val height = tags.int(257) ?: throw IOException("no height")
        if (width <= 0 || height <= 0 || width.toLong() * height > MAX_PIXELS) throw IOException("unsupported size ${width}x$height")
        if (tags.longs(258)?.all { it == 32L } != true) throw IOException("not 32-bit samples")
        if ((tags.int(339) ?: 1) != 3) throw IOException("not floating point samples")
        if ((tags.int(277) ?: 1) != 1) throw IOException("more than one band")
        if ((tags.int(284) ?: 1) != 1) throw IOException("unsupported planar configuration")
        if ((tags.int(317) ?: 1) != 1) throw IOException("unsupported predictor")
        val compression = tags.int(259) ?: 1
        if (compression != 1 && compression != 8 && compression != 32946) throw IOException("unsupported compression $compression")

        val values = FloatArray(width * height)
        val tileWidth = tags.int(322)
        if (tileWidth != null) {
            val tileHeight = tags.int(323) ?: throw IOException("no tile height")
            if (tileWidth <= 0 || tileHeight <= 0 || tileWidth.toLong() * tileHeight > MAX_PIXELS) throw IOException("bad tile size")
            val across = (width + tileWidth - 1) / tileWidth
            val down = (height + tileHeight - 1) / tileHeight
            val offsets = tags.longs(324) ?: throw IOException("no tile offsets")
            val counts = tags.longs(325) ?: throw IOException("no tile sizes")
            if (offsets.size != across * down || counts.size != offsets.size) throw IOException("tile count mismatch")
            for (t in offsets.indices) {
                val chunk = samples(bytes, offsets[t], counts[t], tileWidth * tileHeight, compression, order)
                val x0 = t % across * tileWidth
                val y0 = t / across * tileHeight
                for (row in 0 until minOf(tileHeight, height - y0)) {
                    System.arraycopy(chunk, row * tileWidth, values, (y0 + row) * width + x0, minOf(tileWidth, width - x0))
                }
            }
        } else {
            val rowsPerStrip = (tags.long(278) ?: height.toLong()).coerceIn(1L, height.toLong()).toInt()
            val offsets = tags.longs(273) ?: throw IOException("no strip offsets")
            val counts = tags.longs(279) ?: throw IOException("no strip sizes")
            if (offsets.size != (height + rowsPerStrip - 1) / rowsPerStrip || counts.size != offsets.size) throw IOException("strip count mismatch")
            for (s in offsets.indices) {
                val rows = minOf(rowsPerStrip, height - s * rowsPerStrip)
                val chunk = samples(bytes, offsets[s], counts[s], rows * width, compression, order)
                System.arraycopy(chunk, 0, values, s * rowsPerStrip * width, rows * width)
            }
        }

        val noData = tags.ascii(42113)?.trim()?.toFloatOrNull()
        for (i in values.indices) {
            val v = values[i]
            // GDAL writes -3.4028235E38 as text, which may not parse back to exactly the stored float.
            if (v == noData || v < -1e30f || v > 1e30f) values[i] = Float.NaN
        }

        val transform = tags.doubles(34264)
        var left: Double
        var top: Double
        val pixelWidth: Double
        val pixelHeight: Double
        if (transform != null && transform.size >= 16) {
            if (transform[1] != 0.0 || transform[4] != 0.0) throw IOException("rotated rasters are not supported")
            pixelWidth = transform[0]
            pixelHeight = -transform[5]
            left = transform[3]
            top = transform[7]
        } else {
            val tie = tags.doubles(33922) ?: throw IOException("no georeferencing")
            val scale = tags.doubles(33550) ?: throw IOException("no pixel scale")
            if (tie.size < 6 || scale.size < 2) throw IOException("bad georeferencing")
            pixelWidth = scale[0]
            pixelHeight = scale[1]
            left = tie[3] - tie[0] * pixelWidth
            top = tie[4] + tie[1] * pixelHeight
        }
        if (!(pixelWidth > 0) || !(pixelHeight > 0)) throw IOException("bad pixel size")
        // GTRasterTypeGeoKey 2 (PixelIsPoint) puts the tie point on the pixel's centre rather than its corner.
        if (tags.geoKey(1025) == 2) {
            left -= pixelWidth / 2
            top += pixelHeight / 2
        }
        return Raster(width, height, values, left, top, pixelWidth, pixelHeight)
    }

    private fun samples(bytes: ByteArray, offset: Long, count: Long, pixels: Int, compression: Int, order: ByteOrder): FloatArray {
        if (offset < 0 || count < 0 || offset + count > bytes.size) throw IOException("chunk outside the file")
        val expected = pixels * 4
        val raw = if (compression == 1) {
            if (count < expected) throw IOException("short chunk")
            ByteBuffer.wrap(bytes, offset.toInt(), expected).slice()
        } else {
            val out = ByteArray(expected)
            val inflater = Inflater()
            try {
                inflater.setInput(bytes, offset.toInt(), count.toInt())
                var done = 0
                while (done < expected) {
                    val n = inflater.inflate(out, done, expected - done)
                    if (n == 0 && (inflater.finished() || inflater.needsInput() || inflater.needsDictionary())) break
                    done += n
                }
                if (done < expected) throw IOException("short compressed chunk")
            } catch (e: DataFormatException) {
                throw IOException("corrupt compressed chunk", e)
            } finally {
                inflater.end()
            }
            ByteBuffer.wrap(out)
        }
        val floats = FloatArray(pixels)
        raw.order(order).asFloatBuffer().get(floats)
        return floats
    }

    private class Tags(private val buf: ByteBuffer, ifd: Long) {
        private class Entry(val type: Int, val count: Long, val at: Int)
        private val entries = HashMap<Int, Entry>()

        init {
            if (ifd < 8 || ifd + 2 > buf.limit()) throw IOException("bad directory offset")
            val n = buf.getShort(ifd.toInt()).toInt() and 0xFFFF
            for (i in 0 until n) {
                val p = ifd.toInt() + 2 + i * 12
                val tag = buf.getShort(p).toInt() and 0xFFFF
                val type = buf.getShort(p + 2).toInt() and 0xFFFF
                val count = buf.getInt(p + 4).toLong() and 0xFFFF_FFFFL
                val size = typeSize(type) * count
                val at = if (size <= 4) p + 8 else (buf.getInt(p + 8).toLong() and 0xFFFF_FFFFL).toInt()
                if (size > 4 && (at < 0 || at + size > buf.limit())) throw IOException("tag $tag outside the file")
                entries[tag] = Entry(type, count, at)
            }
        }

        private fun typeSize(type: Int): Long = when (type) {
            1, 2, 6, 7 -> 1
            3, 8 -> 2
            4, 9, 11 -> 4
            5, 10, 12 -> 8
            else -> 1
        }

        fun longs(tag: Int): LongArray? {
            val e = entries[tag] ?: return null
            if (e.count > 1_000_000) throw IOException("tag $tag too long")
            return LongArray(e.count.toInt()) { i ->
                when (e.type) {
                    3 -> (buf.getShort(e.at + i * 2).toInt() and 0xFFFF).toLong()
                    4 -> buf.getInt(e.at + i * 4).toLong() and 0xFFFF_FFFFL
                    1 -> (buf.get(e.at + i).toInt() and 0xFF).toLong()
                    else -> throw IOException("tag $tag is not an integer")
                }
            }
        }

        fun long(tag: Int): Long? = longs(tag)?.firstOrNull()
        fun int(tag: Int): Int? = long(tag)?.let { if (it > Int.MAX_VALUE) throw IOException("tag $tag too large") else it.toInt() }

        fun doubles(tag: Int): DoubleArray? {
            val e = entries[tag] ?: return null
            if (e.count > 1_000) throw IOException("tag $tag too long")
            return DoubleArray(e.count.toInt()) { i ->
                when (e.type) {
                    12 -> buf.getDouble(e.at + i * 8)
                    11 -> buf.getFloat(e.at + i * 4).toDouble()
                    else -> throw IOException("tag $tag is not a real number")
                }
            }
        }

        fun ascii(tag: Int): String? {
            val e = entries[tag] ?: return null
            if (e.type != 2 || e.count > 1_000) return null
            val text = ByteArray(e.count.toInt()) { buf.get(e.at + it) }
            return String(text, Charsets.US_ASCII).trimEnd('\u0000')
        }

        /** A value from the GeoKeyDirectory stored directly in it (TIFFTagLocation 0), or null. */
        fun geoKey(key: Int): Int? {
            val dir = longs(34735) ?: return null
            if (dir.size < 4) return null
            val keys = dir[3].toInt()
            for (k in 0 until keys) {
                val base = 4 + k * 4
                if (base + 3 >= dir.size) break
                if (dir[base].toInt() == key && dir[base + 1] == 0L) return dir[base + 3].toInt()
            }
            return null
        }
    }
}
