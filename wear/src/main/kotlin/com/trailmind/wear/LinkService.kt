package com.trailmind.wear

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import com.trailmind.core.watch.WatchProtocol
import com.trailmind.core.watch.WatchState
import java.io.IOException

/**
 * Holds the phone link while TrailMind isn't on screen (display off, or another app open), so the watch has
 * current data the moment you look and still buzzes for alerts. Shown on the watch face as an ongoing activity.
 */
class LinkService : Service(), PhoneLink.Listener {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var link: PhoneLink
    @Volatile private var status = PhoneLink.Status.CONNECTING
    @Volatile private var lastState: WatchProtocol.Frame? = null
    @Volatile private var lastRoute: WatchProtocol.Frame? = null
    @Volatile private var lastTrack: WatchProtocol.Frame? = null
    @Volatile private var recording = WatchState.IDLE
    @Volatile private var offRouteWhileAway = false
    private val idleStop = Runnable { if (client == null && recording == WatchState.IDLE) stopSelf() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannels()
        link = PhoneLink(this, this)
        if (!goForeground()) { stopSelf(); return }
        service = this
        link.start()
        client?.let { onAttach(it) } ?: scheduleIdleStop()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_NOT_STICKY

    override fun onDestroy() {
        if (service === this) {
            service = null
            link.stop()
        }
        main.removeCallbacks(idleStop)
        super.onDestroy()
    }

    private fun onAttach(c: PhoneLink.Listener) {
        main.removeCallbacks(idleStop)
        getSystemService(NotificationManager::class.java).cancel(ID_ALERT)
        c.onLinkStatus(status)
        listOfNotNull(lastRoute, lastTrack, lastState).forEach { c.onFrame(it) }
        sendVisibility()
    }

    private fun onDetach() {
        sendVisibility()
        scheduleIdleStop()
    }

    private fun sendVisibility() {
        val code = if (client != null) WatchProtocol.CMD_WATCH_VISIBLE else WatchProtocol.CMD_WATCH_HIDDEN
        link.send(WatchProtocol.COMMAND, WatchProtocol.command(code))
    }

    private fun scheduleIdleStop() {
        main.removeCallbacks(idleStop)
        if (client == null && recording == WatchState.IDLE) main.postDelayed(idleStop, IDLE_STOP_MS)
    }

    // ---------------------------------------------------------------- link thread

    override fun onLinkStatus(status: PhoneLink.Status) {
        this.status = status
        if (status == PhoneLink.Status.CONNECTED) sendVisibility()
        client?.onLinkStatus(status)
    }

    override fun onFrame(frame: WatchProtocol.Frame) {
        when (frame.type) {
            WatchProtocol.STATE -> { lastState = frame; noteRecording(frame) }
            WatchProtocol.ROUTE -> lastRoute = frame
            WatchProtocol.TRACK -> lastTrack = frame
        }
        val c = client
        if (c != null) c.onFrame(frame) else if (frame.type == WatchProtocol.ALERT) alertWhileAway(frame)
    }

    private fun noteRecording(frame: WatchProtocol.Frame) {
        val r = try { WatchState.decode(frame.payload).recording } catch (_: IOException) { return }
        if (r == recording) return
        recording = r
        main.post {
            getSystemService(NotificationManager::class.java).notify(ID_LINK, buildNotification())
            scheduleIdleStop()
        }
    }

    private fun alertWhileAway(frame: WatchProtocol.Frame) {
        val (kind, text) = try {
            WatchProtocol.reader(frame.payload).let { it.readUnsignedByte() to it.readUTF() }
        } catch (_: IOException) { return }
        Alerts.pattern(kind)?.let { vibrate(it) }
        val nm = getSystemService(NotificationManager::class.java)
        if (kind == WatchProtocol.ALERT_BACK_ON_ROUTE) { offRouteWhileAway = false; nm.cancel(ID_ALERT); return }
        if (kind == WatchProtocol.ALERT_OFF_ROUTE) offRouteWhileAway = true
        nm.notify(ID_ALERT, NotificationCompat.Builder(this, CH_ALERTS)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("TrailMind")
            .setContentText(text)
            .setContentIntent(openApp())
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_NAVIGATION)
            .build())
    }

    // ---------------------------------------------------------------- notification

    private fun createChannels() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH_LINK, "Phone link", NotificationManager.IMPORTANCE_LOW))
        // The service vibrates with a pattern per alert, so the channel itself stays silent.
        nm.createNotificationChannel(NotificationChannel(CH_ALERTS, "Navigation alerts", NotificationManager.IMPORTANCE_HIGH).apply {
            enableVibration(false)
            setSound(null, null)
        })
    }

    private fun openApp() = PendingIntent.getActivity(this, 0, Intent(this, WatchActivity::class.java), PendingIntent.FLAG_IMMUTABLE)

    private fun buildNotification(): Notification {
        val text = when (recording) {
            WatchState.RECORDING -> "Recording"
            WatchState.PAUSED -> "Paused"
            else -> "Linked to your phone"
        }
        val builder = NotificationCompat.Builder(this, CH_LINK)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("TrailMind")
            .setContentText(text)
            .setContentIntent(openApp())
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_WORKOUT)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        OngoingActivity.Builder(applicationContext, ID_LINK, builder)
            .setStaticIcon(R.drawable.ic_stat_hike)
            .setTouchIntent(openApp())
            .setStatus(Status.Builder().addTemplate(text).build())
            .build()
            .apply(applicationContext)
        return builder.build()
    }

    private fun goForeground(): Boolean = try {
        startForeground(ID_LINK, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        true
    } catch (e: Exception) {
        Log.w(TAG, "cannot keep the phone link in the background", e)
        false
    }

    companion object {
        private const val TAG = "LinkService"
        private const val CH_LINK = "link"
        private const val CH_ALERTS = "alerts"
        private const val ID_LINK = 1
        private const val ID_ALERT = 2
        // Not recording and not looked at for this long: let go of the link to save battery.
        private const val IDLE_STOP_MS = 15 * 60_000L

        @Volatile private var service: LinkService? = null
        @Volatile private var client: PhoneLink.Listener? = null

        /** The on-screen app receives the link's status and frames, starting with the latest ones. Main thread. */
        fun attach(ctx: Context, c: PhoneLink.Listener) {
            client = c
            val s = service
            if (s != null) s.onAttach(c)
            else try {
                ctx.startForegroundService(Intent(ctx, LinkService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "cannot start the phone link", e)
            }
        }

        fun detach(c: PhoneLink.Listener) {
            if (client !== c) return
            client = null
            service?.onDetach()
        }

        fun send(type: Int, payload: ByteArray) {
            service?.link?.send(type, payload)
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, LinkService::class.java))
        }

        val recording: Int get() = service?.recording ?: WatchState.IDLE

        /** True once after an off-route alert arrived while the app was off screen. */
        fun takeOffRouteNotice(): Boolean {
            val s = service ?: return false
            return s.offRouteWhileAway.also { s.offRouteWhileAway = false }
        }
    }
}

/** Vibration patterns for phone alerts, shared by the app and the background link. */
object Alerts {
    fun pattern(kind: Int): LongArray? = when (kind) {
        WatchProtocol.ALERT_OFF_ROUTE -> longArrayOf(0, 400, 200, 400, 200, 400)
        WatchProtocol.ALERT_BACK_ON_ROUTE -> longArrayOf(0, 80)
        WatchProtocol.ALERT_WEATHER -> longArrayOf(0, 600, 300, 600)
        else -> null
    }
}

fun Context.vibrate(pattern: LongArray) {
    val v: Vibrator? = if (Build.VERSION.SDK_INT >= 31) getSystemService(VibratorManager::class.java)?.defaultVibrator
    else @Suppress("DEPRECATION") (getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)
    runCatching { v?.vibrate(VibrationEffect.createWaveform(pattern, -1)) }
}
