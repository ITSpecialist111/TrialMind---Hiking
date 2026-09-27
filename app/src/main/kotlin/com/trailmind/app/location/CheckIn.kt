package com.trailmind.app.location

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.map.PremiumRenewal
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Notifications
import com.trailmind.app.ui.clockTime
import com.trailmind.core.geo.LatLon
import com.trailmind.core.stats.TripReadiness

object CheckIn {
    private const val ACTION_ALARM = "com.trailmind.app.checkin.ALARM"
    private const val ACTION_OK = "com.trailmind.app.checkin.OK"
    private const val ACTION_BACK = "com.trailmind.app.checkin.BACK"
    private const val EXTRA_DUE = "check_in_due"
    private const val HALF_HOUR = 30 * 60_000L

    private fun saveBootAlarm(context: Context, due: Long, stage: Int) {
        context.createDeviceProtectedStorageContext().getSharedPreferences("check_in_alarm", Context.MODE_PRIVATE)
            .edit().putLong("due", due).putInt("stage", stage).apply()
    }

    fun set(context: Context, route: String, dueMs: Long, routeId: Long = 0L) {
        val prefs = (context.applicationContext as TrailMindApp).prefs
        if (prefs.checkInDueMs > 0) context.getSystemService(AlarmManager::class.java).cancel(alarmIntent(context, prefs.checkInDueMs))
        prefs.checkInRoute = route
        prefs.checkInRouteId = routeId
        prefs.checkInStage = 0
        prefs.checkInDueMs = dueMs
        saveBootAlarm(context, dueMs, 0)
        Notifications.manager(context).cancel(Notifications.ID_CHECK_IN)
        arm(context)
    }

    fun clear(context: Context) {
        val prefs = (context.applicationContext as TrailMindApp).prefs
        if (prefs.checkInDueMs > 0) context.getSystemService(AlarmManager::class.java).cancel(alarmIntent(context, prefs.checkInDueMs))
        prefs.checkInDueMs = 0
        prefs.checkInRoute = ""
        prefs.checkInRouteId = 0L
        prefs.checkInStage = 0
        saveBootAlarm(context, 0L, 0)
        Notifications.manager(context).cancel(Notifications.ID_CHECK_IN)
    }

    fun arm(context: Context) {
        val prefs = (context.applicationContext as TrailMindApp).prefs
        val due = prefs.checkInDueMs
        if (due <= 0) return
        val now = System.currentTimeMillis()
        if (prefs.checkInStage >= 2) {
            restoreMissingNotification(context, true)
            return
        }
        val next = if (prefs.checkInStage == 1) TripReadiness.followUpMs(due) else due
        if (next <= now) { check(context); return }
        if (prefs.checkInStage == 1) restoreMissingNotification(context, false)
        schedule(context, due, next)
    }

    private fun restoreMissingNotification(context: Context, overdue: Boolean) {
        val manager = Notifications.manager(context)
        if ((Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            manager.areNotificationsEnabled() && manager.getNotificationChannel(Notifications.CH_CHECK_IN)?.importance != NotificationManager.IMPORTANCE_NONE &&
            manager.activeNotifications.none { it.id == Notifications.ID_CHECK_IN }) postNotification(context, overdue)
    }

    fun armBeforeUnlock(context: Context) {
        val saved = context.createDeviceProtectedStorageContext().getSharedPreferences("check_in_alarm", Context.MODE_PRIVATE)
        val due = saved.getLong("due", 0L)
        val stage = saved.getInt("stage", 0)
        if (due <= 0 || stage >= 2) return
        val next = if (stage == 1) TripReadiness.followUpMs(due) else due
        schedule(context, due, maxOf(next, System.currentTimeMillis() + 1_000L))
    }

    private fun schedule(context: Context, due: Long, next: Long) {
        val alarm = context.getSystemService(AlarmManager::class.java)
        if (Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms())
            alarm.setAlarmClock(AlarmManager.AlarmClockInfo(next, safetyIntent(context)), alarmIntent(context, due))
        else alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, alarmIntent(context, due))
    }

    @Synchronized fun check(context: Context) {
        val prefs = (context.applicationContext as TrailMindApp).prefs
        val due = prefs.checkInDueMs
        val stage = prefs.checkInStage
        if (due <= 0 || stage >= 2 || System.currentTimeMillis() < if (stage == 1) TripReadiness.followUpMs(due) else due) return
        val overdue = stage == 1 || System.currentTimeMillis() >= TripReadiness.followUpMs(due)
        prefs.checkInStage = if (overdue) 2 else 1
        saveBootAlarm(context, due, prefs.checkInStage)
        postNotification(context, overdue)
        if (!overdue) arm(context)
    }

    private fun postNotification(context: Context, overdue: Boolean) {
        val prefs = (context.applicationContext as TrailMindApp).prefs
        val due = prefs.checkInDueMs
        val body = if (!overdue) "You planned to be back by ${clockTime(context, due)}. Are you OK?" else
            "Still no check-in since ${clockTime(context, due)}. Please check in or contact someone."
        val open = PendingIntent.getActivity(context, 71, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val ok = action(context, ACTION_OK, 72, due)
        val back = action(context, ACTION_BACK, 73, due)
        val phone = prefs.emergencyContact
        val sms = PendingIntent.getActivity(context, 74, Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + Uri.encode(phone)))
            .putExtra("sms_body", smsText(context)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(context, Notifications.CH_CHECK_IN)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle(if (!overdue) "Check in: are you OK?" else "Overdue check-in: please respond")
            .setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(open).setCategory(Notification.CATEGORY_ALARM).setPriority(Notification.PRIORITY_HIGH)
            .addAction(Notification.Action.Builder(null, "I'm OK, +30 min", ok).build())
            .addAction(Notification.Action.Builder(null, "I'm back", back).build())
            .apply { if (phone.isNotBlank()) addAction(Notification.Action.Builder(null, "Text ${prefs.emergencyContactName.ifBlank { "contact" }}", sms).build()) }
            .build()
        runCatching { Notifications.manager(context).notify(Notifications.ID_CHECK_IN, notification) }
    }

    fun smsText(context: Context): String {
        val app = context.applicationContext as TrailMindApp
        val recent = app.location.latest?.takeIf { System.currentTimeMillis() - it.location.time in 0..15 * 60_000L }
            ?.let { LatLon(it.lat, it.lon) }
        val last = if (recent == null && LocationHub.hasPermission(context)) runCatching {
            context.getSystemService(LocationManager::class.java).getLastKnownLocation(LocationManager.GPS_PROVIDER)
                ?.takeIf { System.currentTimeMillis() - it.time in 0..15 * 60_000L }
                ?.let { LatLon(it.latitude, it.longitude) }
        }.getOrNull() else null
        val battery = context.registerReceiver(null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1
        return TripReadiness.sms(app.prefs.checkInRoute, recent ?: last,
            clockTime(context, System.currentTimeMillis()), percent)
    }

    fun delayedAlarm(context: Context): Boolean {
        val alarm = context.getSystemService(AlarmManager::class.java)
        return Build.VERSION.SDK_INT >= 31 && !alarm.canScheduleExactAlarms()
    }

    internal fun onAction(context: Context, intent: Intent) {
        val app = context.applicationContext as TrailMindApp
        if (intent.getLongExtra(EXTRA_DUE, -1) != app.prefs.checkInDueMs) return
        when (intent.action) {
            ACTION_ALARM -> check(context)
            ACTION_BACK -> clear(context)
            ACTION_OK -> {
                if (app.prefs.checkInDueMs > 0) set(context, app.prefs.checkInRoute, System.currentTimeMillis() + HALF_HOUR, app.prefs.checkInRouteId)
            }
        }
    }

    private fun action(context: Context, name: String, request: Int, due: Long) = PendingIntent.getBroadcast(context, request,
        Intent(context, CheckInReceiver::class.java).setAction(name)
            .setData(Uri.parse("trailmind://checkin/$request/$due")).putExtra(EXTRA_DUE, due),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    private fun alarmIntent(context: Context, due: Long) = action(context, ACTION_ALARM, 70, due)

    private fun safetyIntent(context: Context) = PendingIntent.getActivity(context, 75,
        Intent(context, MainActivity::class.java).setAction(MainActivity.ACTION_SAFETY),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
}

class CheckInReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = CheckIn.onAction(context, intent)
}

class CheckInBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in listOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_MY_PACKAGE_REPLACED,
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED)) {
            CheckIn.arm(context)
            val pending = goAsync()
            Thread({
                try {
                    val tiles = (context.applicationContext as TrailMindApp).tiles
                    tiles.purgeExpiredPremium()
                    tiles.reschedulePremiumExpiry()
                    PremiumRenewal.reschedule(context)
                } finally { pending.finish() }
            }, "premium-boot-purge").start()
        }
    }
}

class CheckInEarlyBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_LOCKED_BOOT_COMPLETED) CheckIn.armBeforeUnlock(context)
    }
}