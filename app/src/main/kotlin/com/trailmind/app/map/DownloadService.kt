package com.trailmind.app.map

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.data.PackMeta
import com.trailmind.app.data.PackStatus
import com.trailmind.app.ui.Notifications
import com.trailmind.core.geo.TileKey
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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> {
                cancelled = true
                if (worker?.isAlive != true) stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val id = intent.getLongExtra(EXTRA_PACK, -1)
                if (worker?.isAlive == true) return START_NOT_STICKY
                startAsForeground(progressNotification("Preparing download…", 0, 0))
                cancelled = false
                worker = Thread({ run(id) }, "pack-download").also { it.start() }
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
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
                if (noNetwork >= 5) { message = "No internet connection (or offline-only mode is on)."; break }
                if ((done + failed) % 25 == 0L) progress(packId, meta.name, done, failed, bytes, meta.tileTotal)
                Thread.sleep(POLITE_DELAY_MS)
            }
            // Premium zooms go to the browse cache, which OS allows to keep them for 24 hours; the pack keeps OpenData only.
            var premiumFailed = 0L
            var premiumNote: String? = null
            var earliestPremiumMs = Long.MAX_VALUE
            if (!cancelled && message == null) for (k in premiumTiles) {
                if (cancelled) break
                if (app.tiles.hasFreshPremium(source, k)) {
                    earliestPremiumMs = minOf(earliestPremiumMs, app.tiles.premiumCachedAt(source, k))
                    done++; continue
                }
                when (val r = app.tiles.fetchNetwork(source, k)) {
                    is TileProvider.Fetch.Ok -> {
                        app.tiles.storePremium(source, k, r.bytes, r.fetchedAtMs)
                        earliestPremiumMs = minOf(earliestPremiumMs, app.tiles.premiumCachedAt(source, k))
                        done++; noNetwork = 0
                    }
                    is TileProvider.Fetch.Http -> {
                        if (r.code == 401 || r.code == 403) { premiumNote = "Your OS plan doesn't include closer detail, so only the overview map was saved."; break }
                        premiumFailed++
                        if (r.code == 429) Thread.sleep(5_000)
                    }
                    TileProvider.Fetch.NoNetwork -> { premiumFailed++; noNetwork++; Thread.sleep(2_000) }
                    else -> premiumFailed++
                }
                if (noNetwork >= 5) { message = "No internet connection (or offline-only mode is on)."; break }
                if ((done + failed + premiumFailed) % 25 == 0L) progress(packId, meta.name, done, failed + premiumFailed, bytes, meta.tileTotal)
                Thread.sleep(POLITE_DELAY_MS)
            }
            if (meta.premiumMaxZoom >= premiumFrom && !cancelled && message == null && premiumNote == null && premiumFailed == 0L) {
                db.updatePack(packId, ContentValues().apply { put("premium_ms", earliestPremiumMs.takeIf { it != Long.MAX_VALUE } ?: 0L) })
            }
            failed += premiumFailed
            if (message == null) message = premiumNote
            val status = when {
                message != null && message != premiumNote && done == 0L -> PackStatus.FAILED
                cancelled || (message != null && message != premiumNote) -> PackStatus.PAUSED
                failed > 0 -> PackStatus.PARTIAL
                else -> PackStatus.COMPLETE
            }
            db.updatePackProgress(packId, done, failed, bytes, status,
                message ?: if (failed > 0) "$failed tiles failed; tap Resume to retry." else null)
            meta = db.pack(packId)
            Notifications.manager(this).notify(Notifications.ID_DOWNLOAD_DONE, Notification.Builder(this, Notifications.CH_DOWNLOADS)
                .setSmallIcon(R.drawable.ic_stat_hike)
                .setContentTitle("Offline map: ${meta?.name ?: ""}")
                .setContentText("${status.name.lowercase().replaceFirstChar { it.uppercase() }} – $done tiles")
                .setAutoCancel(true)
                .build())
        } catch (t: Throwable) {
            Log.e("DownloadService", "download failed", t)
            meta?.let { db.updatePackProgress(packId, it.tileDone, it.tileFailed, it.bytes, PackStatus.PAUSED, t.message) }
        } finally {
            DownloadState.packId = null
            DownloadState.changed()
            app.tiles.reloadPacks()
            Async.main.post {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    private fun progress(packId: Long, name: String, done: Long, failed: Long, bytes: Long, total: Long) {
        DownloadState.done = done; DownloadState.failed = failed
        TrailMindApp.instance.db.updatePackProgress(packId, done, failed, bytes, PackStatus.DOWNLOADING)
        DownloadState.changed()
        Notifications.manager(this).notify(Notifications.ID_DOWNLOAD, progressNotification("Downloading $name", done, total))
    }

    private fun tilesFor(meta: PackMeta, source: TileSource, minZoom: Int, maxZoom: Int): Sequence<TileKey>? {
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

        fun start(context: Context, packId: Long) {
            context.startForegroundService(
                Intent(context, DownloadService::class.java).setAction(ACTION_START).putExtra(EXTRA_PACK, packId),
            )
        }

        fun pause(context: Context) {
            context.startService(Intent(context, DownloadService::class.java).setAction(ACTION_CANCEL))
        }
    }
}
