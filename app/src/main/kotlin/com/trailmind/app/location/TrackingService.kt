package com.trailmind.app.location

import android.annotation.SuppressLint
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.data.HikeStatus
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Notifications
import com.trailmind.core.format.Units
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.nav.TrackFilter
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/**
 * Records a hike as a `location` foreground service, so tracking continues with the screen off
 * or the app in the background. Started only from the visible UI (Android 14+ requirement); it
 * needs "while in use" location permission, not background location.
 *
 * Every accepted fix is written to SQLite immediately, so a crash or reboot loses at most one fix.
 */
class TrackingService : Service(), LocationListener {
    private lateinit var thread: HandlerThread
    private lateinit var handler: Handler
    private val app get() = TrailMindApp.instance
    private val lm by lazy { getSystemService(Context.LOCATION_SERVICE) as LocationManager }

    private var hikeId = -1L
    private var seq = 0
    private var segment = 0
    private val filter = TrackFilter()
    private var lastCheckpointMs = 0L
    private var lastNotifyMs = 0L
    private var updatesActive = false
    private var weatherAlertMs = 0L
    @Volatile private var notificationText = "Starting GPS…"
    // TrackingState is updated asynchronously on the main thread, so the service keeps its own copy.
    @Volatile private var paused = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        thread = HandlerThread("tracking").apply { start() }
        handler = Handler(thread.looper)
    }

    override fun onDestroy() {
        stopUpdates()
        thread.quitSafely()
        running = false
        app.group.setRecording(false)
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Must call startForeground promptly after startForegroundService, and nothing is recorded if it's refused.
        if (!running) {
            if (!goForeground(buildNotification("Starting GPS…"))) return START_NOT_STICKY
            running = true
            app.group.setRecording(true)
        }
        when (intent?.action) {
            ACTION_START -> handler.post { startNew(intent.getStringExtra(EXTRA_NAME)) }
            ACTION_RESUME_HIKE -> handler.post { resumeExisting(intent.getLongExtra(EXTRA_HIKE, -1)) }
            ACTION_PAUSE -> handler.post { pause() }
            ACTION_RESUME -> handler.post { resume() }
            ACTION_REFRESH_FRONTIER -> {
                // A trip group joined mid-hike adds the connected-device type; the user is in the app, so this is allowed.
                runCatching { startForegroundTyped(buildNotification(notificationText)) }
                handler.post { refreshFallMonitoring() }
            }
            ACTION_STOP -> handler.post { finish() }
            null -> {
                // Restarted by the system after the process was killed: continue the unfinished hike.
                handler.post {
                    val h = app.db.unfinishedHike()
                    if (h != null && h.status == HikeStatus.RECORDING) resumeExisting(h.id) else stopSelf()
                }
            }
        }
        return START_STICKY
    }

    private fun goForeground(n: Notification): Boolean = try {
        startForegroundTyped(n)
        true
    } catch (e: Exception) {
        // e.g. ForegroundServiceStartNotAllowedException / missing permission when restarted from background.
        Log.w(TAG, "cannot start location foreground service", e)
        handler.post {
            app.db.unfinishedHike()?.let { app.db.setHikeStatus(it.id, HikeStatus.PAUSED) }
            TrackingState.end()
        }
        stopSelf()
        false
    }

    /**
     * Location always; connected device too while the user is in a trip group, because the recording then also keeps
     * the group's Bluetooth exchange going. If Android refuses the extra type, recording carries on without it.
     */
    private fun startForegroundTyped(n: Notification) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            startForeground(Notifications.ID_TRACKING, n)
            return
        }
        val location = ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        if (app.group.needsConnectedDeviceType()) {
            try {
                startForeground(Notifications.ID_TRACKING, n, location or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
                return
            } catch (e: SecurityException) {
                Log.w(TAG, "connected-device foreground type refused", e)
            }
        }
        startForeground(Notifications.ID_TRACKING, n, location)
    }

    private fun startNew(name: String?) {
        if (hikeId > 0) return
        val now = System.currentTimeMillis()
        val title = name?.takeIf { it.isNotBlank() }
            ?: "Hike " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(now))
        val routeId = app.prefs.activeRouteId.takeIf { it > 0 }
        hikeId = app.db.createHike(title, now, routeId)
        seq = 0
        segment = 0
        paused = false
        filter.reset()
        TrackingState.begin(hikeId, title, now, emptyList(), 0)
        startUpdates()
    }

    private fun resumeExisting(id: Long) {
        val h = app.db.hike(id) ?: run { stopSelf(); return }
        if (hikeId == id) return
        hikeId = id
        val last = app.db.lastHikePointInfo(id)
        seq = (last?.first ?: -1) + 1
        segment = (last?.second ?: -1) + 1
        val segments = app.db.hikeSegments(id)
        filter.reset()
        paused = false
        app.db.setHikeStatus(id, HikeStatus.RECORDING)
        TrackingState.begin(id, h.name, h.startMs, segments, h.durationMs)
        startUpdates()
    }

    private fun pause() {
        if (hikeId < 0) return
        stopUpdates()
        paused = true
        app.db.setHikeStatus(hikeId, HikeStatus.PAUSED)
        TrackingState.pause()
        checkpoint(force = true)
        Notifications.manager(this).notify(Notifications.ID_TRACKING, buildNotification("Paused"))
    }

    private fun resume() {
        if (hikeId < 0) return
        segment++
        filter.reset()
        paused = false
        app.db.setHikeStatus(hikeId, HikeStatus.RECORDING)
        TrackingState.resume()
        startUpdates()
    }

    private fun finish() {
        stopUpdates()
        CheckIn.clear(this)
        if (hikeId > 0) {
            val id = hikeId
            val active = TrackingState.activeMs()
            app.db.finalizeHike(id, System.currentTimeMillis(), active)
            finishedHikeId = id
        }
        hikeId = -1
        TrackingState.end()
        Async.main.post {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    @SuppressLint("MissingPermission")
    private fun startUpdates() {
        if (updatesActive) return
        if (!LocationHub.hasPermission(this)) {
            Log.w(TAG, "no location permission")
            Notifications.manager(this).notify(Notifications.ID_TRACKING, buildNotification("Location permission missing"))
            return
        }
        try {
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 2_000L, 0f, this, thread.looper)
            updatesActive = true
            app.baro.acquire()
            refreshFallMonitoring()
        } catch (e: Exception) {
            Log.w(TAG, "requestLocationUpdates failed", e)
        }
        Notifications.manager(this).notify(Notifications.ID_TRACKING, buildNotification("Waiting for GPS fix…"))
    }

    private fun stopUpdates() {
        if (!updatesActive) return
        runCatching { lm.removeUpdates(this) }
        updatesActive = false
        app.baro.release()
        app.fallMonitor.setActive(false)
    }

    private fun refreshFallMonitoring() {
        app.fallMonitor.setActive(
            updatesActive && app.prefs.frontierEnabled && app.prefs.frontierFallDetectionEnabled,
        )
    }

    override fun onLocationChanged(location: Location) {
        val fix = LocationHub.toFix(this, location)
        app.location.publish(fix)
        CheckIn.check(this)
        if (hikeId < 0 || paused) return
        val p = TrackPoint(location.latitude, location.longitude, fix.altitudeM, location.time, fix.accuracyM)
        if (filter.accept(p)) {
            try {
                app.db.appendHikePoint(hikeId, seq++, segment, p)
            } catch (e: Exception) {
                Log.e(TAG, "failed to store point", e)
            }
            TrackingState.add(p)
        }
        checkpoint(force = false)
        checkWeather()
        val now = System.currentTimeMillis()
        if (now - lastNotifyMs > 5_000) {
            lastNotifyMs = now
            Async.main.post {
                val imperial = app.prefs.imperial
                val text = "${Units.distance(TrackingState.distanceM, imperial)} · ${Units.duration(TrackingState.activeMs())} · " +
                    "↑${Units.elevation(TrackingState.ascentM, imperial)} · ±${Units.distance(fix.accuracyM.toDouble(), imperial)}" +
                    (app.group.summary()?.let { " · $it" } ?: "")
                Notifications.manager(this).notify(Notifications.ID_TRACKING, buildNotification(text))
            }
        }
    }

    private fun checkpoint(force: Boolean) {
        val now = System.currentTimeMillis()
        if (!force && now - lastCheckpointMs < 30_000) return
        lastCheckpointMs = now
        val id = hikeId
        Async.main.post {
            if (id < 0) return@post
            val active = TrackingState.activeMs()
            val d = TrackingState.distanceM
            val up = TrackingState.ascentM
            val down = TrackingState.descentM
            val n = TrackingState.points.size
            Async.io { app.db.updateHikeLive(id, active, d, up, down, n) }
        }
    }

    /** The barometer's storm alarm: warns at most every 3 hours while sea-level pressure falls fast. */
    private fun checkWeather() {
        val change = app.baro.change3hHpa() ?: return
        val now = System.currentTimeMillis()
        if (change > -app.baro.stormDropHpa || now - weatherAlertMs < 3 * 3_600_000L) return
        weatherAlertMs = now
        val text = String.format(Locale.ROOT, "Air pressure has fallen %.1f hPa in 3 hours, so the weather may be turning. " +
            "Check the forecast and your way off the hill.", -change)
        val open = PendingIntent.getActivity(this, 11, Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, Notifications.CH_ALERTS)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("Weather warning")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { Notifications.manager(this).notify(Notifications.ID_WEATHER, n) }
        app.watch.weatherAlert(text)
    }

    private fun buildNotification(text: String): Notification {
        notificationText = text
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val toggle = PendingIntent.getService(this, 2, Intent(this, TrackingService::class.java)
            .setAction(if (paused) ACTION_RESUME else ACTION_PAUSE), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 3, Intent(this, TrackingService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, Notifications.CH_TRACKING)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle(if (paused) "Hike paused" else "Recording hike")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .apply { if (Build.VERSION.SDK_INT >= 31) setCategory(Notification.CATEGORY_WORKOUT) }
            .addAction(Notification.Action.Builder(null, if (paused) "Resume" else "Pause", toggle).build())
            .addAction(Notification.Action.Builder(null, "Finish", stop).build())
            .build()
    }

    @Deprecated("Deprecated in Java")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
    override fun onProviderEnabled(provider: String) = Unit
    override fun onProviderDisabled(provider: String) {
        if (provider == LocationManager.GPS_PROVIDER) {
            Notifications.manager(this).notify(Notifications.ID_TRACKING, buildNotification("GPS is switched off – turn on Location"))
        }
    }

    companion object {
        private const val TAG = "TrackingService"
        const val ACTION_START = "com.trailmind.app.track.START"
        const val ACTION_RESUME_HIKE = "com.trailmind.app.track.RESUME_HIKE"
        const val ACTION_PAUSE = "com.trailmind.app.track.PAUSE"
        const val ACTION_RESUME = "com.trailmind.app.track.RESUME"
        const val ACTION_REFRESH_FRONTIER = "com.trailmind.app.track.REFRESH_FRONTIER"
        const val ACTION_STOP = "com.trailmind.app.track.STOP"
        const val EXTRA_NAME = "name"
        const val EXTRA_HIKE = "hike"

        @Volatile var running = false
            private set

        /** Set when a hike finishes so the UI can open its summary. */
        @Volatile var finishedHikeId: Long? = null

        fun start(ctx: Context, name: String? = null) =
            ctx.startForegroundService(Intent(ctx, TrackingService::class.java).setAction(ACTION_START).putExtra(EXTRA_NAME, name))

        fun resumeHike(ctx: Context, id: Long) =
            ctx.startForegroundService(Intent(ctx, TrackingService::class.java).setAction(ACTION_RESUME_HIKE).putExtra(EXTRA_HIKE, id))

        fun send(ctx: Context, action: String) {
            if (!running) return
            ctx.startService(Intent(ctx, TrackingService::class.java).setAction(action))
        }
    }
}
