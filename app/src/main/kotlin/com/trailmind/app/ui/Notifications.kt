package com.trailmind.app.ui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.RingtoneManager

object Notifications {
    const val CH_TRACKING = "tracking"
    const val CH_ALERTS = "alerts"
    const val CH_DOWNLOADS = "downloads"
    const val CH_WATCH = "watch"
    const val CH_CHECK_IN = "check_in"
    const val CH_OFFLINE = "offline_renewal"
    const val CH_FALL = "fall_alarm"
    const val CH_SOS = "sos_status"
    const val CH_GROUP = "trip_group"
    const val CH_GROUP_FIND = "trip_group_find"

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
    const val ID_FALL = 11
    const val ID_GROUP_HELP = 12
    const val ID_GROUP_FIND = 13
    const val ID_AUTO_PAUSE = 14

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
        m.createNotificationChannel(NotificationChannel(CH_FALL, "Fall alarm and SOS", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Sounds an alarm after a possible fall and shows the SOS text to your emergency contact"
            setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 800, 400, 800, 400, 800)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        })
        m.createNotificationChannel(NotificationChannel(CH_SOS, "SOS text progress", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Whether your SOS text has been sent"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        })
        m.createNotificationChannel(NotificationChannel(CH_GROUP, "Trip group alerts", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "When someone in your trip group may have fallen or asks for help"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 600)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        })
        m.createNotificationChannel(NotificationChannel(CH_GROUP_FIND, "Being found by your group", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shown while someone in your trip group finds this phone up close with UWB"
            setShowBadge(false)
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
