package com.trailmind.app.watch

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.location.ForegroundLocation
import com.trailmind.app.location.LocationHub
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Notifications

/**
 * Keeps the watch link up while TrailMind is in the background, so the watch keeps working with the phone
 * in a pocket or another app open. GPS runs for the watch only while the watch app is on screen.
 * Must be started while the UI is visible: Android blocks foreground services started from the background.
 */
class WatchLinkService : Service() {
    private val app get() = TrailMindApp.instance
    private var location: ForegroundLocation? = null
    private val onChange: () -> Unit = { update() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (!goForeground()) { stopSelf(); return }
        running = true
        app.watch.addListener(onChange)
        app.watch.refresh()
        update()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) stopSelf()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (running) {
            running = false
            app.watch.removeListener(onChange)
            setLocation(false)
            app.watch.refresh()
        }
        super.onDestroy()
    }

    private fun goForeground(): Boolean = try {
        if (Build.VERSION.SDK_INT >= 29) {
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            if (LocationHub.hasPermission(this)) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            startForeground(Notifications.ID_WATCH_LINK, build(), types)
        } else {
            startForeground(Notifications.ID_WATCH_LINK, build())
        }
        true
    } catch (e: Exception) {
        Log.w(TAG, "cannot keep the watch link in the background", e)
        false
    }

    private fun update() {
        setLocation(app.watch.watchActive)
        Notifications.manager(this).notify(Notifications.ID_WATCH_LINK, build())
    }

    private fun setLocation(on: Boolean) {
        if (on == (location != null)) return
        if (on) {
            location = ForegroundLocation(this, app.location).also { it.start() }
            app.baro.acquire()
        } else {
            location?.stop()
            location = null
            app.baro.release()
        }
    }

    private fun build(): Notification {
        val open = PendingIntent.getActivity(this, 20, Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 21, Intent(this, WatchLinkService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, Notifications.CH_WATCH)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("Watch link")
            .setContentText(app.watch.statusText())
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    companion object {
        private const val TAG = "WatchLinkService"
        private const val ACTION_STOP = "com.trailmind.app.watch.STOP"

        @Volatile var running = false
            private set

        /** Call only while TrailMind is on screen. */
        fun start(ctx: Context) {
            try {
                ctx.startForegroundService(Intent(ctx, WatchLinkService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "cannot start the watch link service", e)
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, WatchLinkService::class.java))
        }
    }
}
