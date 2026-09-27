package com.trailmind.app.ui

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

object Notifications {
    const val CH_TRACKING = "tracking"
    const val CH_ALERTS = "alerts"
    const val CH_DOWNLOADS = "downloads"
    const val CH_WATCH = "watch"
    const val CH_CHECK_IN = "check_in"
    const val CH_OFFLINE = "offline_renewal"

    const val ID_TRACKING = 1
    const val ID_OFF_ROUTE = 2
    const val ID_DOWNLOAD = 3
    const val ID_DOWNLOAD_DONE = 4
    const val ID_WEATHER = 5
    const val ID_WATCH_LINK = 6
    const val ID_DAYLIGHT = 7
    const val ID_DUSK = 8
    const val ID_CHECK_IN = 9
    const val ID_RENEW = 10

    fun manager(ctx: Context): NotificationManager = ctx.getSystemService(NotificationManager::class.java)

    fun createChannels(ctx: Context) {
        val m = manager(ctx)
        m.createNotificationChannel(NotificationChannel(CH_TRACKING, "Hike recording", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shown while a hike is being recorded"
            setShowBadge(false)
        })
        m.createNotificationChannel(NotificationChannel(CH_ALERTS, "Navigation alerts", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Off-route, weather and daylight warnings"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 400, 200, 400)
        })
        m.createNotificationChannel(NotificationChannel(CH_CHECK_IN, "Check-in reminders", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Return-time reminders and overdue follow-ups"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 400, 200, 400)
        })
        m.createNotificationChannel(NotificationChannel(CH_DOWNLOADS, "Offline map downloads", NotificationManager.IMPORTANCE_LOW).apply {
            setShowBadge(false)
        })
        m.createNotificationChannel(NotificationChannel(CH_OFFLINE, "Offline map renewal", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Asks before 24-hour Explorer detail expires, so you can renew it"
        })
        m.createNotificationChannel(NotificationChannel(CH_WATCH, "Watch link", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shown while TrailMind keeps your watch connected in the background"
            setShowBadge(false)
        })
    }
}
