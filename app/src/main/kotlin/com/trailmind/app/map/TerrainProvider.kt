package com.trailmind.app.map

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.ColorSpace
import android.util.LruCache
import com.trailmind.app.Async
import com.trailmind.app.TrailMindApp
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.WebMercator
import com.trailmind.core.map.Terrain
import com.trailmind.core.map.TileCoverage
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicInteger

/** Permanent, bounded cache and shared access to the Mapzen Terrarium terrain tiles. */
class TerrainProvider(private val app: TrailMindApp) {
    private val root = File(app.filesDir, "terrain")
    private val permits = Semaphore(2)
    private val writes = AtomicInteger()
    private val slopeWorkers = Executors.newFixedThreadPool(2) { r -> Thread(r, "terrain-slope").apply { isDaemon = true } }
    private val pendingSlopes = ConcurrentHashMap.newKeySet<TileKey>()
    private val slopeRetryAt = ConcurrentHashMap<TileKey, Long>()
    private val listeners = ConcurrentHashMap.newKeySet<() -> Unit>()
    private val grids = object : LruCache<TileKey, FloatArray>(GRID_CACHE_BYTES) {
        override fun sizeOf(key: TileKey, value: FloatArray) = value.size * 4
    }
    private val slopes = object : LruCache<TileKey, Bitmap>(SLOPE_CACHE_BYTES) {
        override fun sizeOf(key: TileKey, value: Bitmap) = value.byteCount
    }

    fun addListener(listener: () -> Unit) { listeners.add(listener) }
    fun removeListener(listener: () -> Unit) { listeners.remove(listener) }

    fun sample(at: LatLon, allowNetwork: Boolean = true): Double? =
        Terrain.heightAt(at.lat, at.lon) { key -> grid(key, allowNetwork) }

    fun fill(points: List<TrackPoint>, allowNetwork: Boolean = true): List<TrackPoint> =
        Terrain.fillMissingHeights(points) { sample(it, allowNetwork) }

    fun grid(key: TileKey, allowNetwork: Boolean = true): FloatArray? {
        if (key.z != Terrain.ZOOM || key.x !in 0 until (1 shl key.z) || key.y !in 0 until (1 shl key.z)) return null
        grids.get(key)?.let { return it }
        val file = file(key)
        if (file.exists()) {
            file.setLastModified(System.currentTimeMillis())
            return decode(file)?.also { grids.put(key, it) }
        }
        if (!allowNetwork || !app.tiles.networkAllowed()) return null
        val bytes = fetch(key) ?: return null
        if (!write(file, bytes)) return null
        return decode(file)?.also { grids.put(key, it) }
    }

    fun slopeTile(key: TileKey): Bitmap? = slopes.get(key)

    /** Grows the slope cache to hold [visible] tiles plus a margin; a smaller cache would rebuild on-screen tiles forever. */
    fun keepSlopeTiles(visible: Int) {
        val bytes = (visible.coerceAtMost(MAX_SLOPE_TILES) + 12) * SLOPE_TILE_BYTES
        if (bytes > slopes.maxSize()) slopes.resize(bytes)
    }

    fun requestSlopeTile(key: TileKey) {
        if (key.z != Terrain.ZOOM || slopes.get(key) != null) return
        // Without this, every redraw would retry a tile that is not on the phone and cannot be fetched.
        if ((slopeRetryAt[key] ?: 0L) > System.currentTimeMillis() || !pendingSlopes.add(key)) return
        slopeWorkers.execute {
            try {
                val bitmap = buildSlopeTile(key)
                if (bitmap == null) slopeRetryAt[key] = System.currentTimeMillis() + SLOPE_RETRY_MS
                else {
                    slopes.put(key, bitmap)
                    slopeRetryAt.remove(key)
                    Async.main.post { listeners.forEach { it() } }
                }
            } finally {
                pendingSlopes.remove(key)
            }
        }
    }

    /** Saves the terrain tiles for an offline pack; already saved tiles are skipped without decoding them. */
    fun download(keys: Sequence<TileKey>, cancelled: () -> Boolean = { false }): Pair<Int, Int> {
        var saved = 0
        var failed = 0
        for (key in keys) {
            if (cancelled()) break
            if (file(key).exists() || grid(key, allowNetwork = true) != null) saved++ else failed++
        }
        return saved to failed
    }

    fun trimDiskCache() {
        val files = root.walkTopDown().filter { it.isFile }.toList()
        var bytes = files.sumOf { it.length() }
        if (bytes <= MAX_DISK_BYTES) return
        for (file in files.sortedBy { it.lastModified() }) {
            if (bytes <= MAX_DISK_BYTES * 9 / 10) break
            bytes -= file.length()
            file.delete()
        }
    }

    private fun buildSlopeTile(key: TileKey): Bitmap? {
        val worldTiles = 1 shl key.z
        val network = app.tiles.networkAllowed()
        val centre = grid(key, network) ?: return null
        val padded = Terrain.padded(centre) { dx, dy ->
            val y = key.y + dy
            if (y !in 0 until worldTiles) null else grid(TileKey(key.z, Math.floorMod(key.x + dx, worldTiles), y), network)
        }
        val classes = Terrain.slopeClasses(padded, Terrain.TILE_SIZE) { row ->
            Terrain.metresPerPixel(WebMercator.yToLat(key.y * Terrain.TILE_SIZE + row + 0.5, key.z.toDouble()), key.z)
        }
        val colours = IntArray(classes.size) { SLOPE_COLOURS[classes[it].toInt()] }
        return Bitmap.createBitmap(colours, Terrain.TILE_SIZE, Terrain.TILE_SIZE, Bitmap.Config.ARGB_8888)
    }

    private fun decode(file: File): FloatArray? {
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
            inPremultiplied = false
            inScaled = false
            inDither = false
        }
        val bitmap = BitmapFactory.decodeFile(file.absolutePath, options) ?: return null
        return try {
            if (bitmap.width != Terrain.TILE_SIZE || bitmap.height != Terrain.TILE_SIZE) return null
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            Terrain.decodeTerrarium(pixels)
        } finally {
            bitmap.recycle()
        }
    }

    private fun fetch(key: TileKey): ByteArray? {
        permits.acquireUninterruptibly()
        try {
            if (!app.tiles.networkAllowed()) return null
            val url = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/${key.z}/${key.x}/${key.y}.png"
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
            try {
                if (connection.responseCode != 200) return null
                val output = ByteArrayOutputStream()
                connection.inputStream.use { input ->
                    val buffer = ByteArray(8192)
                    var total = 0
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_TILE_BYTES) throw IOException("terrain tile too large")
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
        val temp = File.createTempFile("terrain", ".tmp", file.parentFile)
        try {
            temp.writeBytes(bytes)
            if (!temp.renameTo(file)) throw IOException("could not save terrain tile")
        } finally {
            temp.delete()
        }
        if (writes.incrementAndGet() % 32 == 0) trimDiskCache()
    }.isSuccess

    private fun file(key: TileKey) = File(root, "${key.z}/${key.x}/${key.y}.png")

    companion object {
        const val CREDIT = "Terrain: Mapzen Terrain Tiles on AWS · Environment Agency · Copernicus · USGS · NOAA"
        const val REQUIRED_ATTRIBUTION = """* ArcticDEM terrain data DEM(s) were created from DigitalGlobe, Inc., imagery and
    funded under National Science Foundation awards 1043681, 1559691, and 1542736;
* Australia terrain data © Commonwealth of Australia (Geoscience Australia) 2017;
* Austria terrain data © offene Daten Österreichs – Digitales Geländemodell (DGM)
    Österreich;
* Canada terrain data contains information licensed under the Open Government
    Licence – Canada;
* Europe terrain data produced using Copernicus data and information funded by the
    European Union - EU-DEM layers;
* Global ETOPO1 terrain data U.S. National Oceanic and Atmospheric Administration
* Mexico terrain data source: INEGI, Continental relief, 2016;
* New Zealand terrain data Copyright 2011 Crown copyright (c) Land Information New
    Zealand and the New Zealand Government (All rights reserved);
* Norway terrain data © Kartverket;
* United Kingdom terrain data © Environment Agency copyright and/or database right
    2015. All rights reserved;
* United States 3DEP (formerly NED) and global GMTED2010 and SRTM terrain data
    courtesy of the U.S. Geological Survey."""
        private const val MAX_DISK_BYTES = 200L * 1024 * 1024
        private const val MAX_TILE_BYTES = 2 * 1024 * 1024
        private const val SLOPE_RETRY_MS = 30_000L
        /** By [Terrain.SlopeClass] ordinal: 25° yellow, 30° orange, 35° red, 40° purple. */
        private val SLOPE_COLOURS = intArrayOf(Color.TRANSPARENT, Color.argb(88, 255, 213, 0), Color.argb(96, 255, 128, 0),
            Color.argb(104, 220, 35, 35), Color.argb(112, 120, 45, 170))
        private const val GRID_CACHE_BYTES = 20 * 256 * 256 * 4
        private const val SLOPE_TILE_BYTES = 256 * 256 * 4
        private const val SLOPE_CACHE_BYTES = 16 * SLOPE_TILE_BYTES
        private const val MAX_SLOPE_TILES = 100

        fun packTiles(routePoints: List<LatLon>?, bounds: BoundingBox?, bufferM: Double): Sequence<TileKey> {
            val points = routePoints.orEmpty()
            return if (points.isNotEmpty()) {
                TileCoverage.corridor(points, bufferM.coerceAtLeast(100.0), Terrain.ZOOM).asSequence()
            } else {
                val area = bounds ?: return emptySequence()
                TileCoverage.box(area.expandedByMetres(100.0), Terrain.ZOOM, Terrain.ZOOM)
            }
        }
    }
}