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
import com.trailmind.app.frontier.SatelliteNetworkManager
import com.trailmind.core.geo.TileKey
import com.trailmind.core.map.TileFootprint
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
        class Ok(val bytes: ByteArray, val fetchedAtMs: Long = System.currentTimeMillis()) : Fetch()
        class Http(val code: Int) : Fetch()
        class Error(val message: String) : Fetch()
        object NoNetwork : Fetch()
        object NoKey : Fetch()
    }

    private data class Req(val source: TileSource, val key: TileKey) {
        val id = "${source.id}/${key.z}/${key.x}/${key.y}"
    }

    private data class LoadedTile(val bytes: ByteArray, val premiumTime: Long? = null)
    private data class MemoryTile(val bitmap: Bitmap, val premiumTime: Long? = null)

    private val mem = object : LruCache<String, MemoryTile>((Runtime.getRuntime().maxMemory() / 6).toInt()) {
        override fun sizeOf(key: String, value: MemoryTile) = value.bitmap.byteCount
    }
    private val retryAfter = ConcurrentHashMap<String, Long>()
    private val premiumDenied: MutableSet<String> = ConcurrentHashMap.newKeySet()
    // Tiles in memory that are a lower zoom enlarged; the real tile is retried when it may have become available.
    private val approximate: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val inFlight: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val queue = LinkedBlockingDeque<Req>()
    private val netPermits = Semaphore(2)
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private val packHandles = ConcurrentHashMap<Long, MbTiles>()
    private val footprints = ConcurrentHashMap<Long, Pair<String, TileFootprint?>>()
    private val cacheRoot = File(app.cacheDir, "tiles")
    private var nextPremiumExpiry = Long.MAX_VALUE
    private var premiumPurgedThrough = 0L
    private val memoryExpiry = Runnable { expireMemory() }

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

    @Synchronized fun cached(source: TileSource, key: TileKey): Bitmap? {
        val id = Req(source, key).id
        val entry = mem.get(id) ?: return null
        val parentTime = entry.premiumTime
        if ((parentTime != null && !TilePolicy.premiumCacheFresh(parentTime, System.currentTimeMillis())) ||
            (source.isPremium(key.z) && id !in approximate && !hasFreshPremium(source, key))) {
            mem.remove(id)
            approximate.remove(id)
            retryAfter.remove(id)
            return null
        }
        return entry.bitmap
    }

    @Synchronized private fun remember(r: Req, bitmap: Bitmap, premiumTime: Long?, enlarged: Boolean = false) {
        if (premiumTime != null && !TilePolicy.premiumCacheFresh(premiumTime, System.currentTimeMillis())) return
        if (premiumTime != null && premiumTime + TilePolicy.PREMIUM_CACHE_MS <= premiumPurgedThrough) return
        mem.put(r.id, MemoryTile(bitmap, premiumTime))
        if (enlarged) approximate.add(r.id) else approximate.remove(r.id)
        if (premiumTime != null) schedulePremiumExpiry(premiumTime)
        armMemoryExpiry()
        notifyListeners()
    }

    private fun armMemoryExpiry() {
        Async.main.removeCallbacks(memoryExpiry)
        val oldest = mem.snapshot().values.mapNotNull { it.premiumTime }.minOrNull() ?: return
        Async.main.postDelayed(memoryExpiry, (oldest + TilePolicy.PREMIUM_CACHE_MS - System.currentTimeMillis()).coerceAtLeast(0))
    }

    @Synchronized private fun expireMemory(aheadMs: Long = 0L) {
        val now = System.currentTimeMillis()
        mem.snapshot().filterValues { it.premiumTime?.let { time -> TilePolicy.premiumPurgeDue(time, now, aheadMs) } == true }
            .keys.forEach { mem.remove(it); approximate.remove(it); retryAfter.remove(it) }
        armMemoryExpiry()
        notifyListeners()
    }

    /** True if the cached bitmap is an enlarged lower zoom standing in for this tile. */
    fun isApproximate(source: TileSource, key: TileKey) = Req(source, key).id in approximate

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
        premiumDenied.clear()
        lastError = null
    }

    /** True once the OS project refused this source's Premium zooms (the free OpenData plan). */
    fun premiumDenied(source: TileSource) = source.id in premiumDenied

    private fun workLoop() {
        while (true) {
            val r = try { queue.takeLast() } catch (_: InterruptedException) { return }
            purgeExpiredPremiumIfDue()
            try {
                val tile = loadTile(r.source, r.key, allowNetwork = true)
                val bmp = tile?.bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                if (bmp != null) {
                    remember(r, bmp, tile.premiumTime)
                } else {
                    retryAfter[r.id] = System.currentTimeMillis() + 30_000
                    if (mem.get(r.id) == null) enlarge(r.source, r.key)?.let {
                        remember(r, it.first, it.second, enlarged = true)
                        Log.d(TAG, "tile ${r.id} is not on the phone; showing a lower zoom enlarged")
                        notifyListeners()
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "tile ${r.id} failed", t)
                retryAfter[r.id] = System.currentTimeMillis() + 30_000
            } finally {
                inFlight.remove(r.id)
            }
        }
    }

    fun loadBytes(source: TileSource, key: TileKey, allowNetwork: Boolean): ByteArray? =
        loadTile(source, key, allowNetwork)?.bytes

    private fun loadTile(source: TileSource, key: TileKey, allowNetwork: Boolean): LoadedTile? {
        // 1. Offline packs.
        if (source.canReadFromPack(key.z)) {
            for (p in packsFor(source)) {
                if (key.z < p.minZoom || key.z > p.maxZoom) continue
                val b = runCatching { openPack(p)?.getTile(key) }.getOrNull()
                if (b != null) return LoadedTile(b)
            }
        }
        if (!source.isOnline) return null
        // 2. Disk cache of browsed tiles. Premium tiles may be kept for 24 h at most, and are never served stale.
        val f = diskFile(source, key)
        val premium = source.isPremium(key.z)
        val age = if (f.exists()) System.currentTimeMillis() - f.lastModified() else Long.MAX_VALUE
        if (if (premium) hasFreshPremium(source, key) else age < CACHE_FRESH_MS) return readDisk(source, key)
        if (premium && f.exists()) f.delete()
        // 3. Network.
        if (allowNetwork && !(premium && source.id in premiumDenied)) {
            when (val r = fetchNetwork(source, key, if (!premium && f.exists()) f.lastModified() else 0L)) {
                is Fetch.Ok -> {
                    if (premium) storePremium(source, key, r.bytes, r.fetchedAtMs) else writeDisk(f, r.bytes)
                    return LoadedTile(r.bytes, r.fetchedAtMs.takeIf { premium })
                }
                is Fetch.Http -> when (r.code) {
                    304 -> if (f.setLastModified(System.currentTimeMillis())) return readDisk(source, key)
                    404 -> retryAfter["${source.id}/${key.z}/${key.x}/${key.y}"] = System.currentTimeMillis() + 3_600_000
                }
                else -> Unit
            }
        }
        return if (f.exists() && !premium) readDisk(source, key) else null
    }

    /** Watch tiles contain OpenData only, even when the phone has cached Premium detail. */
    fun loadOrEnlargeBytes(source: TileSource, key: TileKey, allowNetwork: Boolean): ByteArray? {
        if (key.z !in source.minZoom..source.maxZoom) return null
        val native = TilePolicy.openDataTile(key, source.premiumFromZoom)
        val bytes = loadBytes(source, native, allowNetwork)
        if (native == key && bytes != null) return bytes
        return enlarge(source, key, source.premiumFromZoom?.minus(1) ?: source.maxZoom)?.let { (bmp, _) ->
            ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        }
    }

    /**
     * Beyond an offline pack's zooms, or with no signal, shows the nearest lower zoom that is on the phone
     * enlarged, instead of an empty grid.
     */
    private fun enlarge(source: TileSource, key: TileKey, maxNativeZoom: Int = source.maxZoom): Pair<Bitmap, Long?>? {
        for (d in maxOf(1, key.z - maxNativeZoom)..MAX_ENLARGE) {
            val pz = key.z - d
            if (pz < source.minZoom) return null
            val pk = TileKey(pz, key.x shr d, key.y shr d)
            val tile = localTile(source, pk) ?: continue
            val parent = BitmapFactory.decodeByteArray(tile.bytes, 0, tile.bytes.size) ?: continue
            val sub = parent.width shr d
            if (sub <= 0) return null
            val crop = Bitmap.createBitmap(parent, (key.x - (pk.x shl d)) * sub, (key.y - (pk.y shl d)) * sub, sub, sub)
            return Bitmap.createScaledBitmap(crop, parent.width, parent.height, true) to
                tile.premiumTime
        }
        return null
    }

    /** A tile already on the phone: an offline pack, or the browse cache (Premium only within 24 hours). */
    private fun localTile(source: TileSource, key: TileKey): LoadedTile? {
        if (source.canReadFromPack(key.z)) {
            for (p in packsFor(source)) {
                if (key.z < p.minZoom || key.z > p.maxZoom) continue
                runCatching { openPack(p)?.getTile(key) }.getOrNull()?.let { return LoadedTile(it) }
            }
        }
        if (!source.isOnline) return null
        return readDisk(source, key)
    }

    @Synchronized private fun readDisk(source: TileSource, key: TileKey): LoadedTile? {
        val file = diskFile(source, key)
        val time = file.lastModified().takeIf { source.isPremium(key.z) }
        if (time != null && !TilePolicy.premiumCacheFresh(time, System.currentTimeMillis())) return null
        return runCatching { LoadedTile(file.readBytes(), time) }.getOrNull()
    }

    /** A Premium tile pre-loaded for offline use that is still inside its 24 hours. */
    fun hasFreshPremium(source: TileSource, key: TileKey): Boolean {
        val f = diskFile(source, key)
        return f.exists() && TilePolicy.premiumCacheFresh(f.lastModified(), System.currentTimeMillis())
    }

    fun premiumCachedAt(source: TileSource, key: TileKey): Long = diskFile(source, key).lastModified()

    /** Keeps a pre-loaded Premium tile in the browse cache, which deletes it after 24 hours. */
    @Synchronized fun storePremium(source: TileSource, key: TileKey, bytes: ByteArray, fetchedAtMs: Long = System.currentTimeMillis()) {
        require(source.isPremium(key.z))
        if (!TilePolicy.premiumCacheFresh(fetchedAtMs, System.currentTimeMillis())) throw IOException("Premium tile has expired")
        val file = diskFile(source, key)
        schedulePremiumExpiry(fetchedAtMs)
        if (!writeDisk(file, bytes) || !file.setLastModified(fetchedAtMs)) {
            file.delete()
            throw IOException("Could not save Premium tile. Check available storage.")
        }
        schedulePremiumExpiry(file.lastModified())
    }

    @Synchronized private fun schedulePremiumExpiry(storedAt: Long) {
        val expiry = storedAt + TilePolicy.PREMIUM_CACHE_MS
        if (expiry >= nextPremiumExpiry) return
        nextPremiumExpiry = expiry
        PremiumPurgeReceiver.schedule(app, expiry)
        PremiumPurgeJob.schedule(app, expiry)
    }

    @Synchronized fun reschedulePremiumExpiry() {
        nextPremiumExpiry = Long.MAX_VALUE
        val diskOldest = TileSources.builtIns().asSequence().mapNotNull { source ->
            source.premiumFromZoom?.let { from ->
                (from..source.maxZoom).asSequence().flatMap { zoom ->
                    File(cacheRoot, "${source.id}/$zoom").walkTopDown().filter { it.isFile }
                }.minOfOrNull { it.lastModified() }
            }
        }.minOrNull()
        val oldest = listOfNotNull(diskOldest, mem.snapshot().values.mapNotNull { it.premiumTime }.minOrNull()).minOrNull()
        if (oldest == null) {
            PremiumPurgeReceiver.cancel(app)
            PremiumPurgeJob.cancel(app)
        } else schedulePremiumExpiry(oldest)
    }

    @Volatile private var lastPremiumPurgeMs = 0L

    private fun purgeExpiredPremiumIfDue() {
        val now = System.currentTimeMillis()
        if (now - lastPremiumPurgeMs < 3_600_000) return
        lastPremiumPurgeMs = now
        purgeExpiredPremium()
    }

    /** Deletes Premium tiles older than 24 h from disk and drops Premium bitmaps from memory. */
    @Synchronized fun purgeExpiredPremium(aheadMs: Long = 0L) {
        val now = System.currentTimeMillis()
        premiumPurgedThrough = now + aheadMs
        for (s in TileSources.builtIns()) {
            val from = s.premiumFromZoom ?: continue
            for (z in from..s.maxZoom) {
                File(cacheRoot, "${s.id}/$z").walkBottomUp()
                    .filter {
                        if (Thread.currentThread().isInterrupted) throw InterruptedException()
                        it.isFile && TilePolicy.premiumPurgeDue(it.lastModified(), now, aheadMs)
                    }
                    .forEach { it.delete() }
            }
        }
        expireMemory(aheadMs)
    }

    fun packsFor(source: TileSource): List<PackMeta> {
        val list = packs
        return if (source.packId != null) list.filter { it.id == source.packId }
        else list.filter { it.kind == PackKind.DOWNLOAD && it.sourceId == source.id }
    }

    /** [p]'s coverage for outlining on the map, cached until its tiles change. Reads the pack file, so not on the main thread. */
    fun footprint(p: PackMeta): TileFootprint? {
        val stamp = "${p.tileDone}:${p.status}"
        footprints[p.id]?.takeIf { it.first == stamp }?.let { return it.second }
        val f = runCatching { openPack(p)?.footprint(MAX_FOOTPRINT_TILES) }.getOrNull()
        footprints[p.id] = stamp to f
        return f
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
        footprints.remove(id)
        synchronized(packHandles) { packHandles.remove(id)?.close() }
        mem.evictAll()
    }

    /** Tiles, terrain and routing need normal signal: satellite links only carry texts and small updates. */
    fun networkAllowed(): Boolean {
        if (app.prefs.offlineOnly) return false
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && !SatelliteNetworkManager.isSatellite(caps)
    }

    fun fetchNetwork(source: TileSource, key: TileKey, ifModifiedSince: Long = 0L): Fetch {
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
            // An expired cached tile is asked for conditionally, as the OSM tile policy expects: 304 means keep it.
            if (ifModifiedSince > 0) conn.ifModifiedSince = ifModifiedSince
            conn.instanceFollowRedirects = true
            try {
                val code = conn.responseCode
                // OSM serves its "Access blocked" image with HTTP 200; it must never be cached as a tile.
                if (conn.getHeaderField("x-blocked") != null) {
                    setError("${source.name}: the tile server blocked this app. Try another map source.")
                    return Fetch.Http(403)
                }
                // Not modified: the cached copy is still current, which is as good as a fresh 200.
                if (code == 304) {
                    if (lastError != null) { lastError = null; notifyListeners() }
                    return Fetch.Http(304)
                }
                if (code != 200) {
                    if (code == 403 && source.isPremium(key.z)) {
                        if (app.prefs.osPremium) app.prefs.osPremium = false
                        if (premiumDenied.add(source.id)) notifyListeners()
                    } else if (code == 401 || code == 403) setError("${source.name}: access denied (HTTP $code). Check your API key/plan.")
                    if (code == 429) setError("${source.name}: rate limited (HTTP 429). Slow down or try later.")
                    return Fetch.Http(code)
                }
                if (source.isPremium(key.z) && source.requiresKey && !app.prefs.osPremium) app.prefs.osPremium = true
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

    private fun writeDisk(f: File, bytes: ByteArray): Boolean =
        runCatching {
            f.parentFile?.mkdirs()
            val tmp = File.createTempFile(f.name, ".tmp", f.parentFile)
            try {
                tmp.writeBytes(bytes)
                tmp.renameTo(f)
            } finally { tmp.delete() }
        }.getOrDefault(false)

    fun diskCacheBytes(): Long = cacheRoot.walkBottomUp().filter { it.isFile }.sumOf { it.length() }

    fun clearDiskCache() {
        cacheRoot.deleteRecursively()
        mem.evictAll()
        reschedulePremiumExpiry()
    }

    /** Keeps the browse cache under [MAX_DISK_CACHE] by deleting least-recently-fetched tiles. */
    fun trimDiskCache() {
        purgeExpiredPremium()
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
        // OSM's tile policy requires an identifying UA with contact details; it blocks UAs mentioning "offline".
        // The Google Play listing carries the developer's contact email, and the version is the installed one.
        val USER_AGENT: String by lazy { TrailMindApp.instance.let { userAgent(it.versionName, it.packageName) } }

        fun userAgent(version: String, packageName: String) =
            "TrailMind/$version (Android; +https://play.google.com/store/apps/details?id=$packageName)"
        private const val CACHE_FRESH_MS = 7L * 24 * 3600 * 1000
        private const val MAX_DISK_CACHE = 300L * 1024 * 1024
        private const val MAX_TILE_BYTES = 2 * 1024 * 1024
        // Up to 16x: zoom 16 stands in for zoom 20.
        private const val MAX_ENLARGE = 4
        private const val MAX_FOOTPRINT_TILES = 100_000

        fun packDir(context: Context) = File(context.filesDir, "packs").apply { mkdirs() }
        fun packFile(context: Context, name: String) = File(packDir(context), name)
    }
}
