package com.trailmind.app.map

import android.app.AlarmManager
import android.app.Notification
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.data.PackKind
import com.trailmind.app.data.PackMeta
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Notifications
import com.trailmind.app.ui.atTimeText
import com.trailmind.core.map.RenewalPrompt
import com.trailmind.core.map.TilePolicy
import java.time.ZoneId

/** Asks before a pack's 24-hour Premium detail expires. Only the user's tap renews it; TrailMind never does on its own. */
object PremiumRenewal {
    internal const val ACTION_ALARM = "com.trailmind.app.renew.ALARM"
    internal const val ACTION_DISMISS = "com.trailmind.app.renew.DISMISS"
    internal const val EXTRA_PACK = "pack"

    /** Earliest expiry of the pack's fresh detail tiles (0 when none), whether all are fresh, and how many a download would fetch. */
    data class Detail(val expiresAtMs: Long, val complete: Boolean, val tiles: Int, val toFetch: Int)

    fun label(pack: PackMeta): String = if (pack.sourceId == TileSources.OS_LEISURE) {
        if (pack.premiumMaxZoom == 6) "Landranger detail" else "Explorer detail"
    } else "Closer detail to zoom ${pack.premiumMaxZoom}"

    /** Reads tile files, so not on the main thread. Null without 24-hour detail or when the pack's route was deleted. */
    fun detail(app: TrailMindApp, pack: PackMeta, packs: List<PackMeta>): Detail? {
        if (pack.kind != PackKind.DOWNLOAD || pack.premiumMaxZoom <= 0) return null
        val source = TileSources.byId(pack.sourceId, app.prefs, packs)
        val first = maxOf(pack.maxZoom + 1, source.premiumFromZoom ?: return null)
        val tiles = DownloadService.tilesFor(pack, source, first, pack.premiumMaxZoom) ?: return null
        val now = System.currentTimeMillis()
        var earliest = Long.MAX_VALUE
        var count = 0
        var fresh = 0
        var toFetch = 0
        for (tile in tiles) {
            count++
            val cachedAt = app.tiles.premiumCachedAt(source, tile)
            if (TilePolicy.premiumCacheFresh(cachedAt, now)) {
                fresh++
                earliest = minOf(earliest, cachedAt + TilePolicy.PREMIUM_CACHE_MS)
            }
            if (!TilePolicy.premiumReusable(cachedAt, now)) toFetch++
        }
        return Detail(if (fresh > 0) earliest else 0L, count > 0 && fresh == count, count, toFetch)
    }

    /** Posts the questions that are due and sets the alarm for the next. Reads tile files, so not on the main thread. */
    @Synchronized fun reschedule(context: Context) {
        val app = context.applicationContext as TrailMindApp
        val packs = app.db.packs()
        val now = System.currentTimeMillis()
        val asked = app.prefs.renewAsked.toMutableMap()
        var next = Long.MAX_VALUE
        for (pack in packs) {
            val detail = detail(app, pack, packs)
            if (detail == null || detail.expiresAtMs <= now) { dismiss(context, pack.id); continue }
            // Tiles from one download expire within this window of each other, so one question covers them all.
            val askedFor = asked[pack.id]
            if (askedFor != null && detail.expiresAtMs - askedFor < TilePolicy.PREMIUM_CACHE_MS - TilePolicy.PREMIUM_REUSE_MIN_LEFT_MS) continue
            if (DownloadState.packId == pack.id) continue
            val at = RenewalPrompt.at(detail.expiresAtMs, ZoneId.systemDefault())
            if (at > now) next = minOf(next, at)
            else if (post(context, pack, detail)) asked[pack.id] = detail.expiresAtMs
        }
        asked.keys.retainAll(packs.map { it.id }.toSet())
        app.prefs.renewAsked = asked
        val alarms = context.getSystemService(AlarmManager::class.java)
        if (next == Long.MAX_VALUE) { alarms.cancel(alarm(context)); return }
        // Inexact alarms this far ahead may be an hour late, which could push the question into the night.
        if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
            try {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, alarm(context))
                return
            } catch (_: SecurityException) {
                // Exact-alarm access can be revoked between checking and scheduling.
            }
        }
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, alarm(context))
    }

    private fun post(context: Context, pack: PackMeta, detail: Detail): Boolean {
        val manager = Notifications.manager(context)
        if (!manager.areNotificationsEnabled()) return false
        val body = "${pack.name}: renew it for another 24 hours? This downloads ${detail.toFetch} detail tiles from your OS plan."
        val open = PendingIntent.getActivity(context, 77, Intent(context, MainActivity::class.java).setAction(MainActivity.ACTION_OFFLINE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val letExpire = PendingIntent.getBroadcast(context, 79, Intent(context, PremiumRenewalReceiver::class.java)
            .setAction(ACTION_DISMISS).setData(Uri.parse("trailmind://pack/${pack.id}")).putExtra(EXTRA_PACK, pack.id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(context, Notifications.CH_OFFLINE)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("${label(pack)} expires ${atTimeText(context, detail.expiresAtMs)}")
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setTimeoutAfter((detail.expiresAtMs - System.currentTimeMillis()).coerceAtLeast(1L))
            .addAction(Notification.Action.Builder(null, "Renew", DownloadService.startPending(context, pack.id)).build())
            .addAction(Notification.Action.Builder(null, "Let it expire", letExpire).build())
            .build()
        return runCatching { manager.notify(tag(pack.id), Notifications.ID_RENEW, notification) }.isSuccess
    }

    fun dismiss(context: Context, packId: Long) = Notifications.manager(context).cancel(tag(packId), Notifications.ID_RENEW)

    private fun tag(packId: Long) = "pack:$packId"

    private fun alarm(context: Context) = PendingIntent.getBroadcast(context, 27701,
        Intent(context, PremiumRenewalReceiver::class.java).setAction(ACTION_ALARM),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
}

class PremiumRenewalReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            PremiumRenewal.ACTION_DISMISS -> PremiumRenewal.dismiss(context, intent.getLongExtra(PremiumRenewal.EXTRA_PACK, -1))
            PremiumRenewal.ACTION_ALARM -> {
                val pending = goAsync()
                Thread({
                    try { PremiumRenewal.reschedule(context) } finally { pending.finish() }
                }, "renewal-prompt").start()
            }
        }
    }
}
