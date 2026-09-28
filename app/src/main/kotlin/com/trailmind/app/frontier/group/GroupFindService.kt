package com.trailmind.app.frontier.group

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.ui.Notifications

/**
 * Runs while a UWB find is going on, on either phone, so Android doesn't freeze TrailMind when the screen goes off:
 * it must still hear Stop over Bluetooth, and stop UWB itself after 15 minutes. Its notification says who is finding
 * whom and has a Stop button. It can only start while TrailMind is on screen (or already running a hike).
 */
class GroupFindService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val finder = TrailMindApp.instance.group.finder
        if (intent?.action == ACTION_STOP) {
            finder.stop()
            // Tapped after this service had already gone: nothing more for it to do.
            if (!foreground) stopSelf(startId)
            return START_NOT_STICKY
        }
        // startForegroundService() promised a startForeground(), even if the find ended in the meantime.
        val n = finder.notification() ?: Notification.Builder(this, Notifications.CH_GROUP_FIND)
            .setSmallIcon(R.drawable.ic_stat_hike).setContentTitle("UWB finding ended").build()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(Notifications.ID_GROUP_FIND, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            else startForeground(Notifications.ID_GROUP_FIND, n)
        } catch (e: RuntimeException) {
            Log.w(TAG, "could not run in the foreground", e)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        foreground = true
        // The find may have ended before this ran; stop() left the service to stop itself here.
        if (!finder.needsRadio) stopSelf(startId)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        foreground = false
        super.onDestroy()
    }

    companion object {
        private const val TAG = "GroupFindService"
        const val ACTION_STOP = "com.trailmind.app.GROUP_FIND_STOP"
        /** In the foreground. Before that, stopping it would crash TrailMind: Android still waits for startForeground(). */
        @Volatile private var foreground = false

        /** False if Android wouldn't allow it now (TrailMind in the background); the find still runs while TrailMind does. */
        fun start(context: Context): Boolean = try {
            context.startForegroundService(Intent(context, GroupFindService::class.java))
            true
        } catch (e: RuntimeException) {
            Log.w(TAG, "not allowed to start from the background", e)
            false
        }

        fun stop(context: Context) {
            if (foreground) context.stopService(Intent(context, GroupFindService::class.java))
        }
    }
}
