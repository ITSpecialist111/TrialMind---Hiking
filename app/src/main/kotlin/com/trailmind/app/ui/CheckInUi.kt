package com.trailmind.app.ui

import android.Manifest
import android.app.NotificationManager
import android.app.TimePickerDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.trailmind.app.location.CheckIn
import com.trailmind.core.stats.TripReadiness
import java.util.Calendar

internal fun pickCheckIn(host: MainActivity, route: String, planningMinutes: Double, routeId: Long = 0L, onChange: () -> Unit = {}) {
    val active = host.app.prefs.checkInDueMs
    val suggested = if (active > System.currentTimeMillis()) active else
        TripReadiness.defaultReturnMs(System.currentTimeMillis(), planningMinutes)
    val time = clockTime(host, suggested)
    val choices = arrayOf("Set for $time", "$time +30 min", "$time +1 hour", "Choose return time")
    host.ui.dialog().setTitle("Set check-in for $route").setItems(choices) { _, which ->
        if (which < 3) {
            CheckIn.set(host, route, suggested + when (which) { 1 -> 30 * 60_000L; 2 -> 60 * 60_000L; else -> 0L }, routeId)
            host.requestNotificationPermissionIfNeeded()
            showCheckInStatus(host)
            onChange()
        } else {
            val calendar = Calendar.getInstance().apply { timeInMillis = suggested }
            TimePickerDialog(host, { _, hour, minute ->
                calendar.set(Calendar.HOUR_OF_DAY, hour)
                calendar.set(Calendar.MINUTE, minute)
                calendar.set(Calendar.SECOND, 0)
                calendar.set(Calendar.MILLISECOND, 0)
                if (calendar.timeInMillis <= System.currentTimeMillis()) calendar.add(Calendar.DAY_OF_YEAR, 1)
                CheckIn.set(host, route, calendar.timeInMillis, routeId)
                host.requestNotificationPermissionIfNeeded()
                showCheckInStatus(host)
                onChange()
            }, calendar.get(Calendar.HOUR_OF_DAY), calendar.get(Calendar.MINUTE), android.text.format.DateFormat.is24HourFormat(host)).show()
        }
    }.show()
}

internal fun requestExactCheckInAlarm(host: MainActivity) {
    if (Build.VERSION.SDK_INT >= 31) runCatching {
        host.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${host.packageName}")))
    }.onFailure { host.toast("Open Alarms & reminders in system settings to allow exact check-ins") }
}

private fun showCheckInStatus(host: MainActivity) {
    when {
        Build.VERSION.SDK_INT >= 33 && host.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED ->
            host.toast("Check-in saved, but notifications are off. Allow notifications to receive reminders.")
        !Notifications.manager(host).areNotificationsEnabled() ||
            Notifications.manager(host).getNotificationChannel(Notifications.CH_CHECK_IN)?.importance == NotificationManager.IMPORTANCE_NONE ->
            host.ui.dialog().setTitle("Check-in notifications are off")
                .setMessage("Allow check-in reminders in Android notification settings to receive this alert.")
                .setPositiveButton("Fix", { _, _ -> host.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, host.packageName)) })
                .setNegativeButton("Later", null).show()
        CheckIn.delayedAlarm(host) -> host.ui.dialog().setTitle("Check-in may be late")
            .setMessage("Android has not allowed exact alarms. Allow Alarms & reminders for an on-time check-in.")
            .setPositiveButton("Fix", { _, _ -> requestExactCheckInAlarm(host) })
            .setNegativeButton("Later", null).show()
        else -> host.toast("Check-in set for ${clockTime(host, host.app.prefs.checkInDueMs)}")
    }
}