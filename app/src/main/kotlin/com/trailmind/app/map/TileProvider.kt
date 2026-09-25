package com.trailmind.app.map

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import android.util.LruCache
import com.trailmind.app.Async
import com.trailmind.app.TrailMindApp
import com.trailmind.app.data.PackKind
import com.trailmind.app.data.PackMeta
import com.trailmind.core.geo.TileKey
import com.trailmind.core.map.TilePolicy
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.Semaphore

/**
 * Loads raster tiles: offline packs first, then the on-disk browse cache, then (if allowed) the
 * network. Requests are served newest-first so panning stays responsive.
 */
class TileProvider(private val app: TrailMindApp) {

    sealed class Fetch {
        class Ok(val bytes: ByteArray) : Fetch()
        class Http(val code: Int) : Fetch()
        class Error(val message: String) : Fetch()
        object NoNetwork : Fetch()
        object NoKey : Fetch()
    }

    private data class Req(val source: TileSource, val key: TileKey) {
        val id = "${source.id}/${key.z}/${key.x}/${key.y}"
    }

    private val mem = object : LruCache<String, Bitmap>((Runtime.getRuntime().maxMemory() / 6).toInt()) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }
    private val retryAfter = ConcurrentHashMap<String, Long>()
    private val inFlight: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val queue = LinkedBlockingDeque<Req>()
    private val netPermits = Semaphore(2)
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private val packHandles = ConcurrentHashMap<Long, MbTiles>()
    private val cacheRoot = File(app.cacheDir, "tiles")

    @Volatile var packs: List<PackMeta> = emptyList()
        private set

    /** Most recent user-visible problem (e.g. rejected API key); null when fine. */
    @Volatile var lastError: String? = null
        private set

    init {
        repeat(4) { i ->
            Thread({ workLoop() }, "tile-worker-$i").apply { isDaemon = true; start() }
        }
        Async.io { reloadPacks() }
    }

    fun addListener(l: () -> Unit) = listeners.add(l)
    fun removeListener(l: () -> Unit) = listeners.remove(l)
    private fun notifyListeners() = Async.main.post { listeners.forEach { it() } }

    fun reloadPacks() {
        packs = app.db.packs()
        notifyListeners()
    }

    fun cached(source: TileSource, key: TileKey): Bitmap? = mem.get(Req(source, key).id)

    fun request(source: TileSource, key: TileKey) {
        val r = Req(source, key)
        val until = retryAfter[r.id]
        if (until != null && until > System.currentTimeMillis()) return
        if (!inFlight.add(r.id)) return
        queue.addLast(r)
        while (queue.size > 300) {
            val old = queue.pollFirst() ?: break
            inFlight.remove(old.id)
        }
    }

    /** Drop queued work, e.g. after switching base map. */
    fun cancelPending() {
        queue.clear()
        inFlight.clear()
    }

    fun clearErrors() {
        retryAfter.clear()
        lastError = null
    }

    private fun workLoop() {
        while (true) {
            val r = try { queue.takeLast() } catch (_: InterruptedException) { return }
            try {
                val bytes = loadBytes(r.source, r.key, allowNetwork = true)
                val bmp = bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                if (bmp != null) {
                    mem.put(r.id, bmp)
                    notifyListeners()
                } else {
                    retryAfter[r.id] = System.currentTimeMillis() + 30_000
                }
            } catch (t: Throwable) {
                Log.w(TAG, "tile ${r.id} failed", t)
                retryAfter[r.id] = System.currentTimeMillis() + 30_000
            } finally {
                inFlight.remove(r.id)
            }
        }
    }

    fun loadBytes(source: TileSource, key: TileKey, allowNetwork: Boolean): ByteArray? {
        // 1. Offline packs.
        for (p in packsFor(source)) {
            if (key.z < p.minZoom || key.z > p.maxZoom) continue
            val b = runCatching { openPack(p)?.getTile(key) }.getOrNull()
            if (b != null) return b
        }
        if (!source.isOnline) return null
        // 2. Disk cache of browsed tiles.
        val f = diskFile(source, key)
        val fresh = f.exists() && System.currentTimeMillis() - f.lastModified() < CACHE_FRESH_MS
        if (fresh) return runCatching { f.readBytes() }.getOrNull()
        // 3. Network.
        if (allowNetwork) {
            when (val r = fetchNetwork(source, key)) {
                is Fetch.Ok -> {
                    writeDisk(f, r.bytes)
                    return r.bytes
                }
                is Fetch.Http -> if (r.code == 404) retryAfter["${source.id}/${key.z}/${key.x}/${key.y}"] = System.currentTimeMillis() + 3_600_000
                else -> Unit
            }
        }
        return if (f.exists()) runCatching { f.readBytes() }.getOrNull() else null
    }

    fun packsFor(source: TileSource): List<PackMeta> {
        val list = packs
        return if (source.packId != null) list.filter { it.id == source.packId }
        else list.filter { it.kind == PackKind.DOWNLOAD && it.sourceId == source.id }
    }

    fun openPack(p: PackMeta): MbTiles? {
        packHandles[p.id]?.let { return it }
        val file = packFile(app, p.fileName)
        if (!file.exists()) return null
        return synchronized(packHandles) {
            packHandles[p.id] ?: MbTiles.open(file).also { packHandles[p.id] = it }
        }
    }

    fun closePack(id: Long) {
        synchronized(packHandles) { packHandles.remove(id)?.close() }
        mem.evictAll()
    }

    fun networkAllowed(): Boolean {
        if (app.prefs.offlineOnly) return false
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    fun fetchNetwork(source: TileSource, key: TileKey): Fetch {
        val template = source.template ?: return Fetch.Error("offline source")
        if (!networkAllowed()) return Fetch.NoNetwork
        val apiKey = if (source.requiresKey) app.prefs.osApiKey else null
        if (source.requiresKey && apiKey.isNullOrBlank()) {
            setError("Add your OS Data Hub API key in Settings to load ${source.name}.")
            return Fetch.NoKey
        }
        val url = TilePolicy.fillTemplate(template, key, apiKey)
        netPermits.acquireUninterruptibly()
        try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            conn.instanceFollowRedirects = true
            try {
                val code = conn.responseCode
                if (code != 200) {
                    if (code == 401 || code == 403) setError("${source.name}: access denied (HTTP $code). Check your API key/plan.")
                    if (code == 429) setError("${source.name}: rate limited (HTTP 429). Slow down or try later.")
                    return Fetch.Http(code)
                }
                val bytes = conn.inputStream.use { input ->
                    val out = ByteArrayOutputStream()
                    val buf = ByteArray(16 * 1024)
                    var total = 0
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_TILE_BYTES) throw IOException("tile too large")
                        out.write(buf, 0, n)
                    }
                    out.toByteArray()
                }
                if (lastError != null) { lastError = null; notifyListeners() }
                return Fetch.Ok(bytes)
            } finally {
                conn.disconnect()
            }
        } catch (e: IOException) {
            return Fetch.Error(e.message ?: "network error")
        } finally {
            netPermits.release()
        }
    }

    private fun setError(msg: String) {
        if (lastError != msg) {
            lastError = msg
            notifyListeners()
        }
    }

    private fun diskFile(source: TileSource, key: TileKey) =
        File(cacheRoot, "${source.id}/${key.z}/${key.x}/${key.y}.tile")

    private fun writeDisk(f: File, bytes: ByteArray) {
        runCatching {
            f.parentFile?.mkdirs()
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(f)) tmp.delete()
        }
    }

    fun diskCacheBytes(): Long = cacheRoot.walkBottomUp().filter { it.isFile }.sumOf { it.length() }

    fun clearDiskCache() {
        cacheRoot.deleteRecursively()
        mem.evictAll()
    }

    /** Keeps the browse cache under [MAX_DISK_CACHE] by deleting least-recently-fetched tiles. */
    fun trimDiskCache() {
        val files = cacheRoot.walkBottomUp().filter { it.isFile }.toList()
        var total = files.sumOf { it.length() }
        if (total <= MAX_DISK_CACHE) return
        for (f in files.sortedBy { it.lastModified() }) {
            if (total <= MAX_DISK_CACHE * 8 / 10) break
            total -= f.length()
            f.delete()
        }
    }

    companion object {
        private const val TAG = "TileProvider"
        const val USER_AGENT = "TrailMind/0.1 (Android; personal offline-first hiking app)"
        private const val CACHE_FRESH_MS = 7L * 24 * 3600 * 1000
        private const val MAX_DISK_CACHE = 300L * 1024 * 1024
        private const val MAX_TILE_BYTES = 2 * 1024 * 1024

        fun packDir(context: Context) = File(context.filesDir, "packs").apply { mkdirs() }
        fun packFile(context: Context, name: String) = File(packDir(context), name)
    }
}
