package com.trailmind.app.ui

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

object Notifications {
    const val CH_TRACKING = "tracking"
    const val CH_ALERTS = "alerts"
    const val CH_DOWNLOADS = "downloads"

    const val ID_TRACKING = 1
    const val ID_OFF_ROUTE = 2
    const val ID_DOWNLOAD = 3
    const val ID_DOWNLOAD_DONE = 4

    fun manager(ctx: Context): NotificationManager = ctx.getSystemService(NotificationManager::class.java)

    fun createChannels(ctx: Context) {
        val m = manager(ctx)
        m.createNotificationChannel(NotificationChannel(CH_TRACKING, "Hike recording", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shown while a hike is being recorded"
            setShowBadge(false)
        })
        m.createNotificationChannel(NotificationChannel(CH_ALERTS, "Navigation alerts", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Off-route warnings while following a route"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 400, 200, 400)
        })
        m.createNotificationChannel(NotificationChannel(CH_DOWNLOADS, "Offline map downloads", NotificationManager.IMPORTANCE_LOW).apply {
            setShowBadge(false)
        })
    }
}
