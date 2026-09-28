package com.trailmind.app.map

import android.graphics.Bitmap
import android.util.Log
import android.util.LruCache
import com.trailmind.app.Async
import com.trailmind.app.TrailMindApp
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.map.GeoTiff
import com.trailmind.core.map.Lidar
import com.trailmind.core.map.LidarRouteCheck
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicInteger

/**
 * The Environment Agency's 1 m LiDAR terrain for England, in 256 m grid squares: saved as the service sends them,
 * decoded on demand, and turned into hill shading with crags for the map.
 */
class LidarProvider(private val app: TrailMindApp) {
    private val root = File(app.filesDir, "lidar")
    private val permits = Semaphore(2)
    private val workers = Executors.newFixedThreadPool(2) { r -> Thread(r, "lidar").apply { isDaemon = true } }
    private val pending = ConcurrentHashMap.newKeySet<Lidar.Square>()
    private val retryAt = ConcurrentHashMap<Lidar.Square, Long>()
    private val wantedAt = ConcurrentHashMap<Lidar.Square, Long>()
    private val saved = ConcurrentHashMap.newKeySet<Lidar.Square>()
    private val stale = ConcurrentHashMap.newKeySet<Lidar.Square>()
    @Volatile private var indexed = false
    @Volatile private var frameMs = 0L
    private val listeners = ConcurrentHashMap.newKeySet<() -> Unit>()
    private val writes = AtomicInteger()
    private val heights = object : LruCache<Lidar.Square, FloatArray>(HEIGHT_CACHE_BYTES) {
        override fun sizeOf(key: Lidar.Square, value: FloatArray) = maxOf(1, value.size * 4)
    }
    private val crags = object : LruCache<Lidar.Square, BooleanArray>(CRAG_CACHE_BYTES) {
        override fun sizeOf(key: Lidar.Square, value: BooleanArray) = maxOf(1, value.size)
    }
    private val overlays = object : LruCache<Lidar.Square, Bitmap>(OVERLAY_BYTES * 24) {
        override fun sizeOf(key: Lidar.Square, value: Bitmap) = value.byteCount
    }

    init {
        Async.io {
            root.listFiles()?.forEach { file -> squareOf(file.name)?.let { saved += it } }
            indexed = true
        }
    }

    fun addListener(listener: () -> Unit) { listeners.add(listener) }
    fun removeListener(listener: () -> Unit) { listeners.remove(listener) }

    fun isSaved(square: Lidar.Square) = !square.inExtent || square in saved

    /** The square's heights ([NO_DATA] where LiDAR doesn't cover it) from memory, the phone or the network; null if unavailable. */
    fun heights(square: Lidar.Square, allowNetwork: Boolean): FloatArray? {
        if (!square.inExtent) return NO_DATA
        heights.get(square)?.let { return it }
        val file = file(square)
        if (square in saved || !indexed && file.exists()) {
            val values = runCatching { decode(file.readBytes(), square) }.getOrNull()
            if (values != null) {
                file.setLastModified(System.currentTimeMillis())
                saved += square
                heights.put(square, values)
                return values
            }
            file.delete()
            saved -= square
        }
        if (!allowNetwork || !app.tiles.networkAllowed()) return null
        val bytes = fetch(square) ?: return null
        val values = decode(bytes, square) ?: return null
        if (write(file, bytes)) saved += square
        heights.put(square, values)
        // Neighbours shaded before this square arrived repeated their own edge. Shade them again with its heights,
        // showing the old shading until then, including any being shaded right now.
        for (dy in -1..1) for (dx in -1..1) {
            val near = Lidar.Square(square.col + dx, square.row + dy)
            crags.remove(near)
            if (near != square && (near in pending || overlays.get(near) != null)) stale += near
        }
        return values
    }

    /** Height at [at] from LiDAR already on the phone, or null. */
    fun sample(at: LatLon): Double? {
        val grid = OsGrid.fromWgs84(at) ?: return null
        val square = Lidar.squareAt(grid.easting, grid.northing)
        val values = heights(square, allowNetwork = false)?.takeIf { it !== NO_DATA } ?: return null
        return Lidar.height(values, square, grid.easting, grid.northing)
    }

    /** Heights and crags from LiDAR on the phone, for checking a route. */
    fun ground(): LidarRouteCheck.Ground = object : LidarRouteCheck.Ground {
        override fun height(easting: Double, northing: Double): Double? {
            val square = Lidar.squareAt(easting, northing)
            val values = heights(square, allowNetwork = false)?.takeIf { it !== NO_DATA } ?: return null
            return Lidar.height(values, square, easting, northing)
        }

        override fun crag(easting: Double, northing: Double): Boolean {
            val square = Lidar.squareAt(easting, northing)
            val mask = cragMask(square) ?: return false
            val col = (easting - square.east).toInt().coerceIn(0, Lidar.SIZE - 1)
            val row = (square.north + Lidar.SIZE - northing).toInt().coerceIn(0, Lidar.SIZE - 1)
            return mask[row * Lidar.SIZE + col]
        }
    }

    fun overlay(square: Lidar.Square): Bitmap? = overlays.get(square)

    /** True when a neighbour arrived after the square was shaded, so its edges need shading again. */
    fun isStale(square: Lidar.Square) = square in stale

    /** Called as the map starts drawing: squares it doesn't ask for again from now on have gone off the screen. */
    fun beginFrame() { frameMs = System.currentTimeMillis() }

    /** Grows the overlay cache to hold [visible] squares plus a margin; a smaller one would rebuild on-screen squares forever. */
    fun keepOverlays(visible: Int) {
        val bytes = (visible.coerceAtMost(MAX_VISIBLE) + 16) * OVERLAY_BYTES
        if (bytes > overlays.maxSize()) overlays.resize(bytes)
    }

    /** Builds the square's shading in the background, downloading it first if [allowNetwork]; listeners hear when it is ready. */
    fun requestOverlay(square: Lidar.Square, allowNetwork: Boolean) {
        if (overlays.get(square) != null && square !in stale) return
        if (!square.inExtent) { overlays.put(square, EMPTY); return }
        if (!allowNetwork && heights.get(square) == null && square !in saved) return
        val now = System.currentTimeMillis()
        wantedAt[square] = now
        if ((retryAt[square] ?: 0L) > now || !pending.add(square)) return
        workers.execute {
            // Cleared before shading starts, so a neighbour arriving while it runs marks the result stale again.
            val wasStale = stale.remove(square)
            var built = false
            try {
                // Squares the map has moved away from since they were asked for are not worth a download.
                val network = allowNetwork && (wantedAt[square] ?: 0L) >= frameMs
                val bitmap = build(square, network)
                if (bitmap == null) {
                    if (network) retryAt[square] = System.currentTimeMillis() + RETRY_MS
                } else {
                    overlays.put(square, bitmap)
                    built = true
                    retryAt.remove(square)
                    Async.main.post { listeners.forEach { it() } }
                }
            } catch (t: Throwable) {
                Log.w("LidarProvider", "could not shade $square", t)
                retryAt[square] = System.currentTimeMillis() + RETRY_MS
            } finally {
                // The old shading on screen still lacks its neighbour's edge until a rebuild succeeds.
                if (wasStale && !built) stale += square
                wantedAt.remove(square)
                pending.remove(square)
            }
        }
    }

    /** Saves [squares] for offline use, skipping saved ones; returns how many are on the phone and how many failed. */
    fun download(squares: List<Lidar.Square>, cancelled: () -> Boolean = { false }, progress: (done: Int) -> Unit = {}): Pair<Int, Int> {
        var ok = 0
        var failed = 0
        squares.forEachIndexed { i, square ->
            if (cancelled()) return ok to failed
            if (isSaved(square) || heights(square, allowNetwork = true) != null) ok++ else failed++
            progress(i + 1)
        }
        return ok to failed
    }

    fun missing(squares: List<Lidar.Square>): Int = squares.count { !isSaved(it) }

    fun diskBytes(): Long = root.listFiles()?.sumOf { it.length() } ?: 0L

    fun trimDiskCache() {
        val files = root.listFiles()?.filter { it.isFile } ?: return
        var bytes = files.sumOf { it.length() }
        if (bytes <= MAX_DISK_BYTES) return
        for (file in files.sortedBy { it.lastModified() }) {
            if (bytes <= MAX_DISK_BYTES * 9 / 10) break
            bytes -= file.length()
            squareOf(file.name)?.let { saved -= it; heights.remove(it) }
            file.delete()
        }
    }

    private fun build(square: Lidar.Square, allowNetwork: Boolean): Bitmap? {
        val centre = heights(square, allowNetwork) ?: return null
        if (centre === NO_DATA) return EMPTY
        val padded = padded(square, centre)
        // Always worked out afresh: a cached mask may predate a neighbour that has just arrived.
        val mask = Lidar.crags(padded).also { crags.put(square, it) }
        return Bitmap.createBitmap(Lidar.overlay(padded, mask), Lidar.SIZE, Lidar.SIZE, Bitmap.Config.ARGB_8888)
    }

    private fun cragMask(square: Lidar.Square): BooleanArray? {
        crags.get(square)?.let { return it }
        val centre = heights(square, allowNetwork = false)?.takeIf { it !== NO_DATA } ?: return null
        return Lidar.crags(padded(square, centre)).also { crags.put(square, it) }
    }

    private fun padded(square: Lidar.Square, centre: FloatArray): FloatArray = Lidar.padded(centre) { dx, dy ->
        // Rows run south, so the square above (dy = -1) is the next one north.
        heights(Lidar.Square(square.col + dx, square.row - dy), allowNetwork = false)?.takeIf { it !== NO_DATA }
    }

    private fun decode(bytes: ByteArray, square: Lidar.Square): FloatArray? {
        val raster = try { GeoTiff.read(bytes) } catch (_: IOException) { return null }
        val values = Lidar.place(raster, square) ?: return null
        return if (Lidar.clean(values)) values else NO_DATA
    }

    private fun fetch(square: Lidar.Square): ByteArray? {
        permits.acquireUninterruptibly()
        try {
            if (!app.tiles.networkAllowed()) return null
            val connection = URL(url(square)).openConnection() as HttpURLConnection
            connection.connectTimeout = 10_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
            try {
                if (connection.responseCode != 200) return null
                val output = ByteArrayOutputStream()
                connection.inputStream.use { input ->
                    val buffer = ByteArray(16_384)
                    var total = 0
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_SQUARE_BYTES) throw IOException("LiDAR square too large")
                        output.write(buffer, 0, count)
                    }
                }
                return output.toByteArray()
            } finally {
                connection.disconnect()
            }
        } catch (_: IOException) {
            return null
        } finally {
            permits.release()
        }
    }

    private fun write(file: File, bytes: ByteArray): Boolean = runCatching {
        file.parentFile?.mkdirs()
        val temp = File.createTempFile("lidar", ".tmp", file.parentFile)
        try {
            temp.writeBytes(bytes)
            if (!temp.renameTo(file)) throw IOException("could not save LiDAR square")
        } finally {
            temp.delete()
        }
        if (writes.incrementAndGet() % 32 == 0) trimDiskCache()
    }.isSuccess

    private fun file(square: Lidar.Square) = File(root, "${square.col}_${square.row}.tif")

    private fun squareOf(name: String): Lidar.Square? {
        val parts = name.removeSuffix(".tif").split('_')
        if (!name.endsWith(".tif") || parts.size != 2) return null
        return Lidar.Square(parts[0].toIntOrNull() ?: return null, parts[1].toIntOrNull() ?: return null)
    }

    companion object {
        /** The Environment Agency's attribution statement, word for word, as the Open Government Licence asks. */
        const val CREDIT = "LiDAR: © Environment Agency copyright and/or database right 2022. All rights reserved."
        const val DATASET_URL = "https://environment.data.gov.uk/dataset/13787b9a-26a4-4775-8523-806d13af58fc"
        const val LICENCE_URL = "https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/"
        /** Typical size of one square, for download estimates: about 100 KB in the lowlands and 180 KB on the fells. */
        const val SQUARE_BYTES_ESTIMATE = 150 * 1024L
        /** The corridor saved with a route's offline map: wide enough to see the ground either side of the path. */
        const val PACK_CORRIDOR_M = 150.0
        /** Beyond this many squares on the screen the map is zoomed too far out to show 1 m detail. */
        const val MAX_VISIBLE = 144
        /** Marks a square with no LiDAR. */
        val NO_DATA = FloatArray(0)
        /** The shading for a square with no LiDAR: nothing to draw. */
        val EMPTY: Bitmap by lazy { Bitmap.createBitmap(1, 1, Bitmap.Config.ALPHA_8) }
        private const val MAX_DISK_BYTES = 300L * 1024 * 1024
        private const val MAX_SQUARE_BYTES = 2 * 1024 * 1024
        private const val HEIGHT_CACHE_BYTES = 48 * Lidar.SIZE * Lidar.SIZE * 4
        private const val CRAG_CACHE_BYTES = 64 * Lidar.SIZE * Lidar.SIZE
        private const val OVERLAY_BYTES = Lidar.SIZE * Lidar.SIZE * 4
        private const val RETRY_MS = 30_000L
        private const val COVERAGE_ID = "13787b9a-26a4-4775-8523-806d13af58fc__Lidar_Composite_Elevation_DTM_1m"

        fun url(square: Lidar.Square): String =
            "https://environment.data.gov.uk/spatialdata/lidar-composite-digital-terrain-model-dtm-1m/wcs?service=WCS&version=2.0.1" +
                "&request=GetCoverage&coverageId=$COVERAGE_ID&format=image/tiff&geotiff:compression=Deflate" +
                "&subset=E(${square.east},${square.east + Lidar.SIZE})&subset=N(${square.north},${square.north + Lidar.SIZE})"
    }
}
