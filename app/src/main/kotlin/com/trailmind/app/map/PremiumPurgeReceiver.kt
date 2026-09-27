package com.trailmind.app.map

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.trailmind.app.TrailMindApp

class PremiumPurgeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "Premium expiry alarm received")
        val pending = goAsync()
        Thread({
            try {
                val tiles = (context.applicationContext as TrailMindApp).tiles
                // Batch nearby expiries because Doze rate-limits successive allow-while-idle alarms.
                tiles.purgeExpiredPremium(15 * 60_000L)
                tiles.reschedulePremiumExpiry()
                Log.i(TAG, "Premium expiry purge completed")
            } finally {
                pending.finish()
            }
        }, "premium-expiry-alarm").start()
    }

    companion object {
        private const val TAG = "PremiumPurge"

        private fun operation(context: Context) = PendingIntent.getBroadcast(context, 27700,
            Intent(context, PremiumPurgeReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        fun schedule(context: Context, expiryMs: Long) {
            val alarms = context.getSystemService(AlarmManager::class.java)
            val operation = operation(context)
            if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
                try {
                    alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, expiryMs, operation)
                    return
                } catch (_: SecurityException) {
                    // Exact-alarm access can be revoked between checking and scheduling.
                }
            }
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, expiryMs, operation)
        }

        fun cancel(context: Context) {
            context.getSystemService(AlarmManager::class.java).cancel(operation(context))
        }
    }
}