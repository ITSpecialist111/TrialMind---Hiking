package com.trailmind.app.map

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.data.PackMeta
import com.trailmind.app.data.PackStatus
import com.trailmind.app.frontier.SatelliteNetworkManager
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Notifications
import com.trailmind.app.ui.atTimeText
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.TileKey
import com.trailmind.core.map.Lidar
import com.trailmind.core.map.TilePolicy
import com.trailmind.core.map.TileCoverage
import java.util.concurrent.CopyOnWriteArraySet

/** Live progress for the UI. */
object DownloadState {
    @Volatile var packId: Long? = null
    @Volatile var done: Long = 0
    @Volatile var total: Long = 0
    @Volatile var failed: Long = 0
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    fun addListener(l: () -> Unit) = listeners.add(l)
    fun removeListener(l: () -> Unit) = listeners.remove(l)
    fun changed() = Async.main.post { listeners.forEach { it() } }
}

/**
 * Downloads an offline pack as a dataSync foreground service so it survives the screen turning
 * off. Resumable: tiles already present are skipped. Only sources whose terms permit offline
 * storage can be downloaded, and a polite delay is applied between requests.
 */
class DownloadService : Service() {
    @Volatile private var cancelled = false
    private var worker: Thread? = null
    /** Packs waiting behind the current download, such as a renewal tapped in a notification. Guards [busy] too. */
    private val queue = ArrayDeque<Long>()
    private var busy = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> {
                // Pauses only the map being downloaded: a queued renewal was the user's own choice, so it still runs.
                cancelled = true
                if (synchronized(queue) { !busy }) stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val id = intent.getLongExtra(EXTRA_PACK, -1)
                PremiumRenewal.dismiss(this, id)
                val wasBusy = synchronized(queue) {
                    if (busy && id != DownloadState.packId && id !in queue) queue.addLast(id)
                    busy.also { busy = true }
                }
                if (wasBusy) {
                    // Every startForegroundService() call needs a startForeground(); this just refreshes the running one.
                    startAsForeground(progressNotification("Downloading offline maps…", DownloadState.done, DownloadState.total))
                    return START_NOT_STICKY
                }
                startAsForeground(progressNotification("Preparing download…", 0, 0))
                cancelled = false
                worker = Thread({ drain(id) }, "pack-download").also { it.start() }
            }
            else -> if (synchronized(queue) { !busy }) stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun drain(first: Long) {
        var id: Long? = first
        while (id != null) {
            run(id)
            runCatching { PremiumRenewal.reschedule(this) }.onFailure { Log.e("DownloadService", "renewal reminder failed", it) }
            id = synchronized(queue) {
                cancelled = false
                queue.removeFirstOrNull().also { if (it == null) busy = false }
            }
        }
        Async.main.post {
            if (synchronized(queue) { busy }) return@post
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun startAsForeground(n: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(Notifications.ID_DOWNLOAD, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(Notifications.ID_DOWNLOAD, n)
        }
    }

    private fun run(packId: Long) {
        val app = TrailMindApp.instance
        val db = app.db
        var meta = db.pack(packId)
        try {
            if (meta == null) return
            val source = TileSources.byId(meta.sourceId, app.prefs, app.tiles.packs)
            val template = source.template
            if (template == null || !source.offlineDownloadAllowed || TilePolicy.isBulkDownloadForbidden(template) ||
                source.id != meta.sourceId
            ) {
                db.updatePackProgress(packId, meta.tileDone, meta.tileFailed, meta.bytes, PackStatus.FAILED,
                    "This source does not permit offline downloads.")
                return
            }
            if (meta.maxZoom > source.downloadMaxZoom || meta.premiumMaxZoom > source.maxZoom || meta.tileTotal > TilePolicy.MAX_TILES_PER_DOWNLOAD) {
                db.updatePackProgress(packId, meta.tileDone, meta.tileFailed, meta.bytes, PackStatus.FAILED, "Download exceeds this source's limits.")
                return
            }
            val tiles = tilesFor(meta, source, meta.minZoom, meta.maxZoom) ?: run {
                db.updatePackProgress(packId, 0, 0, 0, PackStatus.FAILED, "The route for this pack was deleted.")
                return
            }
            val premiumFrom = maxOf(meta.maxZoom + 1, source.premiumFromZoom ?: Int.MAX_VALUE)
            val premiumTiles = if (meta.premiumMaxZoom >= premiumFrom) tilesFor(meta, source, premiumFrom, meta.premiumMaxZoom).orEmpty() else emptySequence()
            val mb = app.tiles.openPack(meta) ?: run {
                db.updatePackProgress(packId, 0, 0, 0, PackStatus.FAILED, "Pack file missing.")
                return
            }
            DownloadState.packId = packId
            DownloadState.total = meta.tileTotal
            var done = 0L
            var failed = 0L
            var bytes = meta.bytes
            var authFailures = 0
            var noNetwork = 0
            var message: String? = null
            progress(packId, meta.name, 0, 0, bytes, meta.tileTotal)
            app.tiles.reloadPacks()
            for (k in tiles) {
                if (cancelled) break
                if (!source.canStoreInPack(k.z)) {
                    message = "This source does not permit saving this zoom in an offline pack."
                    break
                }
                if (mb.hasTile(k)) { done++; continue }
                when (val r = app.tiles.fetchNetwork(source, k)) {
                    is TileProvider.Fetch.Ok -> {
                        mb.putTile(k, r.bytes)
                        bytes += r.bytes.size
                        done++
                        authFailures = 0; noNetwork = 0
                    }
                    is TileProvider.Fetch.Http -> {
                        failed++
                        if (r.code == 401 || r.code == 403) authFailures++
                        if (r.code == 429) Thread.sleep(5_000)
                    }
                    TileProvider.Fetch.NoKey -> { message = "OS Data Hub API key missing."; break }
                    TileProvider.Fetch.NoNetwork -> {
                        failed++
                        noNetwork++
                        Thread.sleep(2_000)
                    }
                    is TileProvider.Fetch.Error -> failed++
                }
                if (authFailures >= 3) { message = "Access denied by the tile server. Check your API key and plan."; break }
                if (noNetwork >= 5) { message = noNetworkMessage(); break }
                if ((done + failed) % 25 == 0L) progress(packId, meta.name, done, failed, bytes, meta.tileTotal)
                Thread.sleep(POLITE_DELAY_MS)
            }
            // Premium zooms go to the browse cache, which OS allows to keep them for 24 hours; the pack keeps OpenData only.
            var premiumFailed = 0L
            var premiumNote: String? = null
            var earliestPremiumMs = Long.MAX_VALUE
            if (!cancelled && message == null) for (k in premiumTiles) {
                if (cancelled) break
                val cachedAt = app.tiles.premiumCachedAt(source, k)
                if (TilePolicy.premiumReusable(cachedAt, System.currentTimeMillis())) {
                    earliestPremiumMs = minOf(earliestPremiumMs, cachedAt)
                    done++; continue
                }
                when (val r = app.tiles.fetchNetwork(source, k)) {
                    is TileProvider.Fetch.Ok -> {
                        app.tiles.storePremium(source, k, r.bytes, r.fetchedAtMs)
                        earliestPremiumMs = minOf(earliestPremiumMs, app.tiles.premiumCachedAt(source, k))
                        done++; noNetwork = 0
                    }
                    is TileProvider.Fetch.Http -> {
                        if (r.code == 401) { message = "OS rejected your API key. Check it in Settings."; break }
                        if (r.code == 403) { premiumNote = "Your OS plan doesn't include closer detail, so only the overview map was saved."; break }
                        premiumFailed++
                        if (r.code == 429) Thread.sleep(5_000)
                    }
                    TileProvider.Fetch.NoNetwork -> { premiumFailed++; noNetwork++; Thread.sleep(2_000) }
                    TileProvider.Fetch.NoKey -> { message = "OS Data Hub API key missing."; break }
                    else -> premiumFailed++
                }
                if (noNetwork >= 5) { message = noNetworkMessage(); break }
                if ((done + failed + premiumFailed) % 25 == 0L) progress(packId, meta.name, done, failed + premiumFailed, bytes, meta.tileTotal)
                Thread.sleep(POLITE_DELAY_MS)
            }
            if (meta.premiumMaxZoom >= premiumFrom && !cancelled && message == null && premiumNote == null && premiumFailed == 0L) {
                db.updatePack(packId, ContentValues().apply { put("premium_ms", earliestPremiumMs.takeIf { it != Long.MAX_VALUE } ?: 0L) })
            }
            var lidarFailed = 0
            if (!cancelled && message == null) {
                val routePoints = meta.routeId?.let { db.routeData(it)?.points?.map { point -> point.latLon() } }
                val terrainResult = app.terrain.download(TerrainProvider.packTiles(routePoints, meta.bounds, meta.bufferM)) { cancelled }
                Log.i("DownloadService", "saved ${terrainResult.first} terrain tiles; ${terrainResult.second} unavailable")
                if (routePoints != null && app.prefs.packLidar) {
                    val squares = Lidar.corridor(routePoints.map { OsGrid.project(it) }, LidarProvider.PACK_CORRIDOR_M)
                    val packName = meta.name
                    val lidarResult = app.lidar.download(squares, { cancelled }) { saved ->
                        if (saved % 8 == 1) Notifications.manager(this).notify(Notifications.ID_DOWNLOAD,
                            progressNotification("Saving 1 m LiDAR for $packName", saved.toLong(), squares.size.toLong()))
                    }
                    Log.i("DownloadService", "saved ${lidarResult.first} LiDAR squares; ${lidarResult.second} unavailable")
                    lidarFailed = lidarResult.second
                }
            }
            failed += premiumFailed
            if (message == null) message = premiumNote
            val status = when {
                message != null && message != premiumNote && done == 0L -> PackStatus.FAILED
                cancelled || (message != null && message != premiumNote) -> PackStatus.PAUSED
                premiumNote != null || failed > 0 || lidarFailed > 0 -> PackStatus.PARTIAL
                else -> PackStatus.COMPLETE
            }
            val lidarNote = if (lidarFailed > 0) "$lidarFailed LiDAR squares failed; tap Resume to retry." else null
            db.updatePackProgress(packId, done, failed, bytes, status, when {
                message != null && message == premiumNote && lidarNote != null -> "$message $lidarNote"
                message != null -> message
                failed > 0 && lidarFailed > 0 -> "$failed tiles and $lidarFailed LiDAR squares failed; tap Resume to retry."
                failed > 0 -> "$failed tiles failed; tap Resume to retry."
                else -> lidarNote
            })
            meta = db.pack(packId)
            val detailUntil = earliestPremiumMs.takeIf { status == PackStatus.COMPLETE && it != Long.MAX_VALUE }?.plus(TilePolicy.PREMIUM_CACHE_MS)
            val summary = "${status.name.lowercase().replaceFirstChar { it.uppercase() }} – $done tiles" + when {
                detailUntil != null && meta != null -> ". ${PremiumRenewal.label(meta)} until ${atTimeText(this, detailUntil)}."
                status != PackStatus.COMPLETE && meta?.message != null -> ". ${meta.message}"
                else -> ""
            }
            val open = PendingIntent.getActivity(this, 76, Intent(this, MainActivity::class.java).setAction(MainActivity.ACTION_OFFLINE),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            Notifications.manager(this).notify(Notifications.ID_DOWNLOAD_DONE, Notification.Builder(this, Notifications.CH_DOWNLOADS)
                .setSmallIcon(R.drawable.ic_stat_hike)
                .setContentTitle("Offline map: ${meta?.name ?: ""}")
                .setContentText(summary)
                .setStyle(Notification.BigTextStyle().bigText(summary))
                .setContentIntent(open)
                .setAutoCancel(true)
                .apply { if (status == PackStatus.PAUSED && !cancelled) addAction(Notification.Action.Builder(null, "Try again", startPending(this@DownloadService, packId)).build()) }
                .build())
        } catch (t: Throwable) {
            Log.e("DownloadService", "download failed", t)
            meta?.let { db.updatePackProgress(packId, it.tileDone, it.tileFailed, it.bytes, PackStatus.PAUSED, t.message) }
        } finally {
            DownloadState.packId = null
            DownloadState.changed()
            app.tiles.reloadPacks()
        }
    }

    private fun noNetworkMessage() = if (SatelliteNetworkManager.onSatellite(this))
        "On satellite: map downloads wait for normal signal." else "No internet connection (or offline-only mode is on)."

    private fun progress(packId: Long, name: String, done: Long, failed: Long, bytes: Long, total: Long) {
        DownloadState.done = done; DownloadState.failed = failed
        TrailMindApp.instance.db.updatePackProgress(packId, done, failed, bytes, PackStatus.DOWNLOADING)
        DownloadState.changed()
        Notifications.manager(this).notify(Notifications.ID_DOWNLOAD, progressNotification("Downloading $name", done, total))
    }

    private fun progressNotification(text: String, done: Long, total: Long): Notification {
        val cancel = PendingIntent.getService(this, 1, Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, Notifications.CH_DOWNLOADS)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("TrailMind offline maps")
            .setContentText(if (total > 0) "$text ($done / $total)" else text)
            .setProgress(total.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), done.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), total == 0L)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "Pause", cancel).build())
            .build()
    }

    companion object {
        const val ACTION_START = "com.trailmind.app.download.START"
        const val ACTION_CANCEL = "com.trailmind.app.download.CANCEL"
        const val EXTRA_PACK = "pack"
        private const val POLITE_DELAY_MS = 60L

        /** The tiles [meta] covers at these zooms, or null when its route was deleted. */
        fun tilesFor(meta: PackMeta, source: TileSource, minZoom: Int, maxZoom: Int): Sequence<TileKey>? {
            val routeId = meta.routeId
            if (routeId != null) {
                val route = TrailMindApp.instance.db.routeData(routeId) ?: return null
                val points = route.points.map { it.latLon() }
                return if (source.grid == TileGrid.BRITISH_NATIONAL_GRID) TileCoverage.bngCorridor(points, meta.bufferM, minZoom, maxZoom)
                    else TileCoverage.corridor(points, meta.bufferM, minZoom, maxZoom)
            }
            val b = meta.bounds ?: return emptySequence()
            return if (source.grid == TileGrid.BRITISH_NATIONAL_GRID) TileCoverage.bngBox(b, minZoom, maxZoom)
                else TileCoverage.box(b, minZoom, maxZoom)
        }

        private fun startIntent(context: Context, packId: Long) = Intent(context, DownloadService::class.java).setAction(ACTION_START)
            .setData(Uri.parse("trailmind://pack/$packId")).putExtra(EXTRA_PACK, packId)

        /** Starts (or queues) [packId] when the user taps a notification action. */
        fun startPending(context: Context, packId: Long): PendingIntent = PendingIntent.getForegroundService(context, 78,
            startIntent(context, packId), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        fun start(context: Context, packId: Long) {
            context.startForegroundService(startIntent(context, packId))
        }

        fun pause(context: Context) {
            context.startService(Intent(context, DownloadService::class.java).setAction(ACTION_CANCEL))
        }
    }
}
