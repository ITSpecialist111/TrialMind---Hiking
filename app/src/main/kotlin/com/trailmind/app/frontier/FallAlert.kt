package com.trailmind.app.frontier

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.telephony.SmsManager
import android.util.Log
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.location.LocationHub
import com.trailmind.app.ui.Notifications
import com.trailmind.app.ui.clockTime
import com.trailmind.core.frontier.SosText
import com.trailmind.core.geo.LatLon
import java.util.concurrent.CopyOnWriteArraySet
import kotlin.math.roundToInt

/**
 * After a possible fall: an alarm with an "Are you OK?" countdown, then an SOS text to the emergency contact.
 * TrailMind sends the text itself only if the user turned that on; otherwise the text is ready for them to send.
 * A plain text is what O2 Satellite carries, so this still works out of mobile coverage on a satellite phone.
 */
object FallAlert {
    const val COUNTDOWN_MS = 60_000L
    const val MAX_ATTEMPTS = 15
    private const val RETRY_MS = 2 * 60_000L
    private const val ALL_CLEAR_KEEP_MS = 24 * 60 * 60_000L
    private const val FRESH_FIX_MS = 15 * 60_000L
    private const val TAG = "FallAlert"

    const val NO_RESPONSE = "Possible fall, no response"
    const val FALL_HELP = "Fall, I need help"
    const val HELP = "I need help"

    enum class Stage { NONE, COUNTDOWN, TEXT_READY, SENDING, SENT }

    private const val ACTION_ALARM = "com.trailmind.app.fall.ALARM"
    private const val ACTION_OK = "com.trailmind.app.fall.OK"
    private const val ACTION_SEND = "com.trailmind.app.fall.SEND"
    private const val ACTION_SENT = "com.trailmind.app.fall.SENT"
    private const val ACTION_ALL_CLEAR_SENT = "com.trailmind.app.fall.ALL_CLEAR_SENT"
    private const val EXTRA_STARTED = "fall_started"
    private const val EXTRA_NUMBER = "sos_number"
    private const val EXTRA_TIME = "sos_text_ms"

    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    fun addListener(listener: () -> Unit) = listeners.add(listener)
    fun removeListener(listener: () -> Unit) = listeners.remove(listener)
    private fun changed() = Async.ui { listeners.forEach { it() } }

    private fun prefs(context: Context) = (context.applicationContext as TrailMindApp).prefs

    fun stage(context: Context): Stage = Stage.entries.getOrElse(prefs(context).fallStage) { Stage.NONE }
    fun deadlineMs(context: Context) = prefs(context).fallAlertMs + COUNTDOWN_MS
    fun attempts(context: Context) = prefs(context).sosAttempts
    /** An attempt to send the SOS text failed or never reported back; TrailMind is waiting to try again. */
    fun notSentYet(context: Context) = prefs(context).let { it.sosFailed || it.sosAttempts > 1 }
    fun sentMs(context: Context) = prefs(context).sosSentMs
    /** Who the SOS text goes to: once sending has begun, the number it went to, even if the contact changed since. */
    fun recipientNumber(context: Context): String = prefs(context).let { it.sosRecipient.ifBlank { it.emergencyContact } }
    fun contactName(context: Context): String = nameFor(context, recipientNumber(context))

    private fun nameFor(context: Context, number: String): String = prefs(context).let {
        if (number == it.emergencyContact) it.emergencyContactName.ifBlank { number } else number
    }

    fun hasSmsPermission(context: Context) = context.checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED

    /** True when TrailMind may send the SOS text itself: the user chose it, allowed SMS and set a contact. */
    fun canSendItself(context: Context): Boolean = canText(context, prefs(context).emergencyContact)

    /** True when "I'm OK" will text the people who got the SOS that you're fine. */
    fun canTellRecipient(context: Context): Boolean = prefs(context).sosSentTo.any { canText(context, it.substringBefore('|')) }

    private fun canText(context: Context, number: String): Boolean = prefs(context).sosAutoSend && number.isNotBlank() &&
        !SosText.isEmergencyNumber(number) && hasSmsPermission(context) &&
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)

    /** Starts the alarm and countdown after a detected fall, unless one is already running. */
    @Synchronized fun start(context: Context) {
        if (stage(context) in listOf(Stage.COUNTDOWN, Stage.TEXT_READY, Stage.SENDING)) return
        val now = begin(context)
        prefs(context).fallStage = Stage.COUNTDOWN.ordinal
        schedule(context, now + COUNTDOWN_MS, now)
        post(context)
        changed()
    }

    /** The user asked for help: send the SOS text now, or get it ready for them if TrailMind may not send it. */
    @Synchronized fun sendNow(context: Context, situation: String = FALL_HELP) {
        val stage = stage(context)
        if (stage == Stage.SENDING) return
        if (stage == Stage.NONE || stage == Stage.SENT) begin(context)
        prefs(context).sosSituation = situation
        cancelAlarm(context)
        sendOrReady(context)
    }

    /** "I'm OK": stops the alarm. Everyone an SOS text already went to is told you're OK. */
    @Synchronized fun ok(context: Context) {
        val prefs = prefs(context)
        val sentTo = prefs.sosSentTo
        val now = System.currentTimeMillis()
        // Texts handed to the radio but not yet reported may still go: each that does gets its own all-clear.
        if (prefs.sosRecipient.isNotBlank()) prefs.sosAllClearPending = prefs.sosAllClearPending
            .filter { now - (it.toLongOrNull() ?: 0L) < ALL_CLEAR_KEEP_MS }.toSet() + prefs.fallAlertMs.toString()
        cancelAlarm(context)
        Notifications.manager(context).cancel(Notifications.ID_FALL)
        prefs.fallStage = Stage.NONE.ordinal
        prefs.fallAlertMs = 0L
        prefs.sosAttempts = 0
        prefs.sosFailed = false
        prefs.sosSentMs = 0L
        prefs.sosSentTo = emptySet()
        prefs.sosSituation = ""
        prefs.sosRecipient = ""
        (context.applicationContext as TrailMindApp).frontier.clearEmergency()
        sentTo.forEach { entry ->
            val number = entry.substringBefore('|')
            if (canText(context, number)) allClear(context, entry.substringAfter('|').toLongOrNull() ?: now, number)
        }
        changed()
    }

    /** The SOS text as it would be sent now (or at [atMs]). */
    fun message(context: Context, situation: String = prefs(context).sosSituation.ifBlank { NO_RESPONSE }, atMs: Long = System.currentTimeMillis()): String {
        val here = where(context)
        val battery = context.getSystemService(BatteryManager::class.java)?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        return SosText.contact(situation, here?.first, here?.second, clockTime(context, atMs), battery, currentWords(context, here?.first))
    }

    /** For 999 by emergencySMS. Never sent automatically: the user reads it and sends it. */
    fun emergencyMessage(context: Context): String =
        where(context)?.first.let { here ->
            SosText.emergency(prefs(context).sosSituation.ifBlank { HELP }, here, clockTime(context, System.currentTimeMillis()), currentWords(context, here))
        }

    private fun currentWords(context: Context, here: LatLon?): String? {
        val fix = (context.applicationContext as TrailMindApp).location.latest
        return com.trailmind.app.data.What3words.current(fix)?.takeIf { here != null && it.contains(here) }?.words
    }

    fun composeIntent(number: String, body: String): Intent =
        Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + Uri.encode(number))).putExtra("sms_body", body)

    private fun begin(context: Context): Long {
        val prefs = prefs(context)
        val now = System.currentTimeMillis()
        prefs.fallAlertMs = now
        prefs.sosAttempts = 0
        prefs.sosFailed = false
        prefs.sosSentMs = 0L
        prefs.sosSentTo = emptySet()
        prefs.sosSituation = NO_RESPONSE
        prefs.sosRecipient = ""
        return now
    }

    private fun sendOrReady(context: Context) {
        val prefs = prefs(context)
        if (canSendItself(context)) {
            prefs.fallStage = Stage.SENDING.ordinal
            prefs.sosAttempts = 0
            prefs.sosFailed = false
            // Every attempt, and the all-clear, go to this number even if the contact is changed meanwhile.
            prefs.sosRecipient = prefs.emergencyContact
            send(context)
        } else {
            prefs.fallStage = Stage.TEXT_READY.ordinal
            post(context)
        }
        changed()
    }

    private fun send(context: Context) {
        val prefs = prefs(context)
        if (prefs.sosAttempts >= MAX_ATTEMPTS) { failed(context); return }
        if (!canText(context, prefs.sosRecipient)) {
            cancelAlarm(context)
            prefs.fallStage = Stage.TEXT_READY.ordinal
            post(context)
            return
        }
        prefs.sosAttempts = prefs.sosAttempts + 1
        // Also the safety net if the radio never reports back.
        schedule(context, System.currentTimeMillis() + RETRY_MS, prefs.fallAlertMs)
        post(context)
        runCatching {
            val at = System.currentTimeMillis()
            sms(context).sendTextMessage(prefs.sosRecipient, null, message(context, atMs = at),
                sentIntent(context, prefs.fallAlertMs, prefs.sosRecipient, at), null)
        }.onFailure {
            Log.w(TAG, "SOS text not sent", it)
            failed(context)
        }
    }

    private fun failed(context: Context) {
        val prefs = prefs(context)
        prefs.sosFailed = true
        if (prefs.sosAttempts >= MAX_ATTEMPTS) {
            cancelAlarm(context)
            prefs.fallStage = Stage.TEXT_READY.ordinal
        }
        post(context)
    }

    @Synchronized private fun onAlarm(context: Context) {
        when (stage(context)) {
            Stage.COUNTDOWN -> {
                prefs(context).sosSituation = NO_RESPONSE
                sendOrReady(context)
            }
            Stage.SENDING -> send(context)
            else -> Unit
        }
        changed()
    }

    @Synchronized private fun onSent(context: Context, success: Boolean, number: String, textMs: Long) {
        val prefs = prefs(context)
        val stage = stage(context)
        // A report for an earlier recipient records that text, but only the current recipient's report completes this send.
        val current = number == prefs.sosRecipient
        if (success) {
            if (number.isNotBlank() && prefs.sosSentTo.none { it.substringBefore('|') == number })
                prefs.sosSentTo = prefs.sosSentTo + "$number|$textMs"
            // A report after the retries ran out still means the text went.
            if (current && (stage == Stage.SENDING || (stage == Stage.TEXT_READY && prefs.sosRecipient.isNotBlank()))) {
                cancelAlarm(context)
                prefs.sosSentMs = textMs
                prefs.fallStage = Stage.SENT.ordinal
                post(context)
            }
        } else if (current && stage == Stage.SENDING) failed(context)
        changed()
    }

    private fun allClear(context: Context, sentAt: Long, number: String) {
        if (!canText(context, number)) return
        val text = "TrailMind: I'm OK now. Please ignore my SOS text from ${clockTime(context, sentAt)}."
        val sent = PendingIntent.getBroadcast(context, 82,
            Intent(context, FallAlertReceiver::class.java).setAction(ACTION_ALL_CLEAR_SENT)
                .setData(Uri.parse("trailmind://allclear/${System.nanoTime()}")).putExtra(EXTRA_NUMBER, number),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)
        runCatching { sms(context).sendTextMessage(number, null, text, sent, null) }.onFailure { allClearFailed(context, number) }
    }

    private fun allClearFailed(context: Context, number: String) {
        val name = nameFor(context, number)
        val compose = PendingIntent.getActivity(context, 83,
            composeIntent(number, "I'm OK now. Please ignore my SOS text.").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(context, Notifications.CH_SOS)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("Couldn't tell $name you're OK")
            .setContentText("Tap to text them yourself.")
            .setContentIntent(compose).setAutoCancel(true)
            .build()
        runCatching { Notifications.manager(context).notify(Notifications.ID_FALL, n) }
    }

    private fun post(context: Context) {
        val stage = stage(context)
        val manager = Notifications.manager(context)
        if (stage == Stage.NONE) { manager.cancel(Notifications.ID_FALL); return }
        val prefs = prefs(context)
        val started = prefs.fallAlertMs
        val name = contactName(context).ifBlank { "your contact" }
        val sat = (context.applicationContext as TrailMindApp).frontier.satelliteState
        val satNote = if (sat.textsOverSatellite) " On ${sat.operatorName ?: "satellite"} a text can take a few minutes." else ""
        // The alarm channel only while the user must act; sending progress must not sound the alarm again.
        val channel = if (stage == Stage.SENDING || stage == Stage.SENT) Notifications.CH_SOS else Notifications.CH_FALL
        // On a locked phone "I'm OK" needs the owner's PIN or fingerprint, so a stranger or a pocket can't cancel the alarm.
        // Before Android 12 a notification action can't require that, so it opens the alarm screen, which asks for it.
        val okAction = if (Build.VERSION.SDK_INT >= 31)
            Notification.Action.Builder(null, "I'm OK", broadcast(context, ACTION_OK, 85, started)).setAuthenticationRequired(true).build()
        else Notification.Action.Builder(null, "I'm OK", activity(context, FallAlertActivity.ACTION_OK, 85)).build()
        val b = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_sos)
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setContentIntent(activity(context, null, 84))
            .addAction(okAction)
        when (stage) {
            Stage.COUNTDOWN -> {
                val body = "Possible fall. " + if (canSendItself(context)) "If you don't answer, TrailMind texts $name your location."
                else "If you don't answer, TrailMind gets a text to $name ready for you."
                val sendNow = if (canSendItself(context)) broadcast(context, ACTION_SEND, 86, started)
                else activity(context, FallAlertActivity.ACTION_SEND, 86)
                b.setContentTitle("Are you OK?").setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
                    .setWhen(deadlineMs(context)).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true)
                    .setFullScreenIntent(activity(context, null, 87), true)
                    .addAction(Notification.Action.Builder(null, "Send SOS now", sendNow).build())
            }
            Stage.TEXT_READY -> {
                val title = when {
                    prefs.sosAttempts >= MAX_ATTEMPTS -> "Your SOS text didn't send"
                    prefs.sosSituation == NO_RESPONSE -> "No answer to the fall alarm"
                    else -> "Send your SOS text"
                }
                val body = "Text $name your location, or call 999 if you have signal for calls.$satNote"
                val compose = PendingIntent.getActivity(context, 88,
                    composeIntent(recipientNumber(context), message(context)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                b.setContentTitle(title).setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
                    .addAction(Notification.Action.Builder(null, "Text $name", compose).build())
            }
            Stage.SENDING -> {
                val body = (if (notSentYet(context)) "Not sent yet. Trying every 2 minutes, attempt ${prefs.sosAttempts} of $MAX_ATTEMPTS." else "Sending your location.") + satNote
                b.setContentTitle("Sending SOS text to $name").setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
                    .setOnlyAlertOnce(true)
            }
            Stage.SENT -> {
                val body = "Sent at ${clockTime(context, prefs.sosSentMs)} with your location." +
                    if (canTellRecipient(context)) " If you're OK, tap I'm OK and TrailMind tells $name." else ""
                b.setContentTitle("SOS text sent to $name").setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
                    .setOnlyAlertOnce(true)
            }
            Stage.NONE -> Unit
        }
        val n = b.build()
        if (stage == Stage.COUNTDOWN) n.flags = n.flags or Notification.FLAG_INSISTENT
        runCatching { manager.notify(Notifications.ID_FALL, n) }
    }

    // Location is read only after LocationHub.hasPermission, and runCatching covers a permission revoked meanwhile.
    @SuppressLint("MissingPermission")
    private fun where(context: Context): Pair<LatLon, Int?>? {
        val now = System.currentTimeMillis()
        (context.applicationContext as TrailMindApp).location.latest?.takeIf { now - it.location.time in 0..FRESH_FIX_MS }
            ?.let { return LatLon(it.lat, it.lon) to it.altitudeM?.roundToInt() }
        if (!LocationHub.hasPermission(context)) return null
        return runCatching {
            context.getSystemService(LocationManager::class.java).getLastKnownLocation(LocationManager.GPS_PROVIDER)
                ?.takeIf { now - it.time in 0..FRESH_FIX_MS }
                ?.let { LatLon(it.latitude, it.longitude) to (if (it.hasAltitude()) it.altitude.roundToInt() else null) }
        }.getOrNull()
    }

    private fun sms(context: Context): SmsManager =
        if (Build.VERSION.SDK_INT >= 31) context.getSystemService(SmsManager::class.java) else @Suppress("DEPRECATION") SmsManager.getDefault()

    private fun schedule(context: Context, atMs: Long, started: Long) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val op = broadcast(context, ACTION_ALARM, 80, started)
        if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms())
            alarms.setAlarmClock(AlarmManager.AlarmClockInfo(atMs, activity(context, null, 89)), op)
        else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, op)
    }

    private fun cancelAlarm(context: Context) =
        context.getSystemService(AlarmManager::class.java).cancel(broadcast(context, ACTION_ALARM, 80, 0L))

    private fun broadcast(context: Context, action: String, request: Int, started: Long) = PendingIntent.getBroadcast(context, request,
        Intent(context, FallAlertReceiver::class.java).setAction(action).putExtra(EXTRA_STARTED, started),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    /** One per text handed to the radio, carrying its number, so every report lands on the right alert and person. */
    private fun sentIntent(context: Context, started: Long, number: String, textMs: Long) = PendingIntent.getBroadcast(context, 81,
        Intent(context, FallAlertReceiver::class.java).setAction(ACTION_SENT)
            .setData(Uri.parse("trailmind://sos/$started/${System.nanoTime()}"))
            .putExtra(EXTRA_STARTED, started).putExtra(EXTRA_NUMBER, number).putExtra(EXTRA_TIME, textMs),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)

    private fun activity(context: Context, action: String?, request: Int) = PendingIntent.getActivity(context, request,
        Intent(context, FallAlertActivity::class.java).setAction(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    @Synchronized internal fun onAction(context: Context, intent: Intent, resultCode: Int) {
        if (intent.action == ACTION_ALL_CLEAR_SENT) {
            val number = intent.getStringExtra(EXTRA_NUMBER)
            if (resultCode != Activity.RESULT_OK && !number.isNullOrBlank()) allClearFailed(context, number)
            return
        }
        val prefs = prefs(context)
        val started = intent.getLongExtra(EXTRA_STARTED, -1L)
        val number = intent.getStringExtra(EXTRA_NUMBER).orEmpty()
        // The time written in that SOS text, so an all-clear names the text the person actually got.
        val textMs = intent.getLongExtra(EXTRA_TIME, 0L).takeIf { it > 0 } ?: System.currentTimeMillis()
        if (intent.action == ACTION_SENT && started != prefs.fallAlertMs && started.toString() in prefs.sosAllClearPending) {
            // A text from an alert already ended with I'm OK went after all: tell that person too.
            if (resultCode == Activity.RESULT_OK && canText(context, number)) allClear(context, textMs, number)
            return
        }
        // Actions from an alert that has since ended or been replaced are ignored.
        if (started != prefs.fallAlertMs) return
        when (intent.action) {
            ACTION_ALARM -> onAlarm(context)
            ACTION_OK -> ok(context)
            ACTION_SEND -> sendNow(context)
            ACTION_SENT -> onSent(context, resultCode == Activity.RESULT_OK, number, textMs)
        }
    }
}

class FallAlertReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = FallAlert.onAction(context, intent, resultCode)
}
