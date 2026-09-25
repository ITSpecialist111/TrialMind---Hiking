package com.trailmind.app.map

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
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
import com.trailmind.core.map.TileCoverage
import com.trailmind.core.map.TilePolicy
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
            val tiles = tilesFor(meta) ?: run {
                db.updatePackProgress(packId, 0, 0, 0, PackStatus.FAILED, "The route for this pack was deleted.")
                return
            }
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
            db.updatePackProgress(packId, meta.tileDone, 0, bytes, PackStatus.DOWNLOADING)
            for (k in tiles) {
                if (cancelled) break
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
                        noNetwork++
                        Thread.sleep(2_000)
                    }
                    is TileProvider.Fetch.Error -> failed++
                }
                if (authFailures >= 3) { message = "Access denied by the tile server. Check your API key and plan."; break }
                if (noNetwork >= 5) { message = "No internet connection (or offline-only mode is on)."; break }
                if ((done + failed) % 25 == 0L) {
                    DownloadState.done = done; DownloadState.failed = failed
                    db.updatePackProgress(packId, done, failed, bytes, PackStatus.DOWNLOADING)
                    DownloadState.changed()
                    Notifications.manager(this).notify(Notifications.ID_DOWNLOAD,
                        progressNotification("Downloading ${meta.name}", done, meta.tileTotal))
                }
                Thread.sleep(POLITE_DELAY_MS)
            }
            val status = when {
                message != null && done == 0L -> PackStatus.FAILED
                cancelled || message != null -> PackStatus.PAUSED
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

    private fun tilesFor(meta: PackMeta): Sequence<TileKey>? {
        val routeId = meta.routeId
        if (routeId != null) {
            val route = TrailMindApp.instance.db.routeData(routeId) ?: return null
            return TileCoverage.corridor(route.points.map { it.latLon() }, meta.bufferM, meta.minZoom, meta.maxZoom)
        }
        val b = meta.bounds ?: return emptySequence()
        return TileCoverage.box(b, meta.minZoom, meta.maxZoom)
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
