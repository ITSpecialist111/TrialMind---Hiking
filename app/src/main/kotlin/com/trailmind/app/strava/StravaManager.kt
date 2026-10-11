package com.trailmind.app.strava

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.data.HikeMeta
import com.trailmind.app.data.StravaPostRow
import com.trailmind.app.frontier.SatelliteNetworkManager
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Notifications
import com.trailmind.core.gpx.GpxWriter
import com.trailmind.core.strava.StravaActivityKind
import com.trailmind.core.strava.StravaAthlete
import com.trailmind.core.strava.StravaOAuth
import com.trailmind.core.strava.StravaPolicy
import com.trailmind.core.strava.StravaPostState
import com.trailmind.core.strava.StravaTokens
import com.trailmind.core.strava.StravaUploadResult
import java.io.StringWriter
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArraySet
import org.json.JSONObject

/**
 * Links TrailMind to the user's Strava account and posts each finished hike to it.
 *
 * The user registers their own Strava API application once (strava.com/settings/api) and pastes its Client ID and
 * secret in; Strava's sign-in then runs in the browser or the Strava app and comes back to TrailMind, which keeps the
 * tokens encrypted on the phone. Each hike gets one row in the database, so a retry, a restart or a second tap can never
 * post it twice, and a hike recorded without signal is posted when there is some.
 */
class StravaManager(private val app: TrailMindApp) {
    private val prefs get() = app.prefs
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private val queueLock = Any()
    private val random = SecureRandom()

    fun addListener(l: () -> Unit) = listeners.add(l)
    fun removeListener(l: () -> Unit) = listeners.remove(l)
    private fun changed() = Async.ui { listeners.forEach { it() } }

    // ---------------------------------------------------------------- the link

    /** The Client ID and secret of the user's own Strava application are saved. */
    val hasApp: Boolean get() = prefs.stravaClientId.isNotBlank() && prefs.hasStravaSecret

    /** Signed in to Strava, and Strava still accepts it. */
    val linked: Boolean get() = prefs.hasStravaRefreshToken && !prefs.stravaNeedsReconnect

    /** Signed in once, but Strava has refused the saved link since (revoked, or uploading was switched off). */
    val needsReconnect: Boolean get() = prefs.hasStravaRefreshToken && prefs.stravaNeedsReconnect

    /** Who is linked, for "Linked as …". */
    fun athlete(): StravaAthlete? = prefs.stravaAthleteId.takeIf { it != 0L }?.let {
        StravaAthlete(it, prefs.stravaAthleteUsername.ifBlank { null }, prefs.stravaAthleteFirstName.ifBlank { null }, prefs.stravaAthleteLastName.ifBlank { null })
    }

    /**
     * Starts the sign-in with the application's [clientId] and [clientSecret] (a blank secret keeps the one saved), and
     * returns the address to open in the browser, or null with the problem in [error]. Everything that touches the
     * keystore waits for a background thread: making its key can take seconds on some phones.
     */
    fun beginConnect(clientId: String, clientSecret: String, error: (String) -> Unit): String? {
        val id = clientId.trim()
        val secret = clientSecret.trim()
        linkNote = null
        if (id.isBlank() || !id.all { it.isDigit() }) { error("The Client ID is the number at the top of your Strava application's page."); return null }
        if (secret.isEmpty() && !(prefs.hasStravaSecret && id == prefs.stravaClientId)) { error("Paste the Client Secret from your Strava application's page."); return null }
        // A different application means the old sign-in is no use.
        if (id != prefs.stravaClientId) clearLink()
        prefs.stravaClientId = id
        if (secret.isNotEmpty()) Async.io { prefs.stravaClientSecret = secret }
        val state = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        prefs.stravaPendingState = state
        return StravaOAuth.authorizeUrl(StravaApi.baseUrl, id, state)
    }

    /** What the last attempt to link ended in, kept so the Strava page can show a failure after the toast has gone. */
    @Volatile var linkNote: String? = null
        private set

    /** Strava sent the user back to the app. [done] gets what to tell them. */
    fun handleRedirect(url: String, done: (String) -> Unit) {
        val finish: (String) -> Unit = { message -> linkNote = message; done(message) }
        val expected = prefs.stravaPendingState.takeIf { it.isNotEmpty() }
        when (val r = StravaOAuth.parseRedirect(url, expected)) {
            is StravaOAuth.Redirect.Invalid -> finish(r.reason)
            is StravaOAuth.Redirect.Refused -> { prefs.stravaPendingState = ""; finish(r.reason) }
            is StravaOAuth.Redirect.Granted -> {
                // The state is good for one answer.
                prefs.stravaPendingState = ""
                if (!r.canUpload) {
                    finish("Strava didn't give TrailMind permission to post activities, so nothing was linked. Connect again and leave \"Upload your activities\" ticked.")
                    return
                }
                Async.run({ completeLink(r) }) { result -> finish(result.getOrElse { "Couldn't finish linking: ${it.message}" }) }
            }
        }
    }

    /** Swaps the sign-in code for tokens and saves them. Runs on a background thread; returns what to tell the user. */
    private fun completeLink(r: StravaOAuth.Redirect.Granted): String {
        return when (val reply = StravaApi.exchangeCode(prefs.stravaClientId, prefs.stravaClientSecret, r.code)) {
            is StravaApi.Reply.Ok -> {
                storeTokens(reply.body, r.scopes.joinToString(","))
                reply.body.optJSONObject("athlete")?.let(::storeAthlete)
                prefs.stravaNeedsReconnect = false
                changed()
                resume()
                "Linked to Strava as ${athlete()?.display ?: "your account"}."
            }
            is StravaApi.Reply.Http ->
                if (reply.code == 400 || reply.code == 401) "Strava didn't accept the Client ID and secret. Check them on your application's page at strava.com/settings/api. (${reply.message})"
                else "Strava said no (HTTP ${reply.code}): ${reply.message}"
            is StravaApi.Reply.Offline -> "Couldn't reach Strava: ${reply.message}"
        }
    }

    /**
     * Unlinks, and tells Strava so it drops TrailMind from the user's connected apps. Hikes already posted stay on Strava;
     * hikes still waiting to be posted are let go, so they can't end up on whichever account is linked next.
     * With [forget], the application's Client ID and secret go too.
     */
    fun disconnect(forget: Boolean = false) {
        Async.io {
            // Under the queue's lock, so a post in progress can't store a token after this has cleared them.
            val token = synchronized(queueLock) {
                val fresh = tokenForRevoking()
                clearLink()
                app.db.dropWaitingStravaPosts()
                if (forget) { prefs.stravaClientId = ""; prefs.stravaClientSecret = "" }
                fresh
            }
            changed()
            if (token.isNotBlank()) StravaApi.deauthorize(token)
        }
    }

    /** An access token lasts six hours, and Strava can't drop an app on an expired one, so renew it first if need be. */
    private fun tokenForRevoking(): String {
        val refresh = prefs.stravaRefreshToken
        val tokens = StravaTokens(prefs.stravaAccessToken, refresh, prefs.stravaExpiresAtS, prefs.stravaScope)
        if (refresh.isBlank() || (tokens.accessToken.isNotBlank() && !tokens.needsRefresh(System.currentTimeMillis() / 1000))) return tokens.accessToken
        val reply = StravaApi.refresh(prefs.stravaClientId, prefs.stravaClientSecret, refresh) as? StravaApi.Reply.Ok
        return reply?.body?.optString("access_token").orEmpty().ifBlank { tokens.accessToken }
    }
    private fun clearLink() {
        linkNote = null
        prefs.stravaAccessToken = ""
        prefs.stravaRefreshToken = ""
        prefs.stravaExpiresAtS = 0
        prefs.stravaScope = ""
        prefs.stravaAthleteId = 0
        prefs.stravaAthleteUsername = ""
        prefs.stravaAthleteFirstName = ""
        prefs.stravaAthleteLastName = ""
        prefs.stravaNeedsReconnect = false
        prefs.stravaPendingState = ""
    }

    private fun storeTokens(body: JSONObject, scope: String? = null) {
        prefs.stravaAccessToken = body.optString("access_token")
        body.optString("refresh_token").takeIf { it.isNotBlank() }?.let { prefs.stravaRefreshToken = it }
        prefs.stravaExpiresAtS = body.optLong("expires_at", System.currentTimeMillis() / 1000 + body.optLong("expires_in", 21_600))
        scope?.let { prefs.stravaScope = it }
    }

    private fun storeAthlete(a: JSONObject) {
        prefs.stravaAthleteId = a.optLong("id")
        prefs.stravaAthleteUsername = if (a.isNull("username")) "" else a.optString("username")
        prefs.stravaAthleteFirstName = if (a.isNull("firstname")) "" else a.optString("firstname")
        prefs.stravaAthleteLastName = if (a.isNull("lastname")) "" else a.optString("lastname")
    }

    // ---------------------------------------------------------------- posting

    fun post(hikeId: Long): StravaPostRow? = app.db.stravaPost(hikeId)

    /** A hike has just been finished: post it if the user links Strava and wants that, and it was a real hike. */
    fun onHikeFinished(hikeId: Long) {
        if (!linked || !prefs.stravaAuto) return
        Async.io {
            val hike = app.db.hike(hikeId) ?: return@io
            if (StravaPolicy.worthPosting(hike.distanceM, hike.pointCount)) enqueue(hikeId)
            else {
                app.db.saveStravaPost(StravaPostRow(hikeId, StravaPostState.SKIPPED, null, null,
                    "Too short to be a hike (under ${StravaPolicy.MIN_DISTANCE_M.toInt()} m).", 0, 0, System.currentTimeMillis()))
                changed()
            }
        }
    }

    /** The user asked to post this hike (or to try again), whatever its length. */
    fun postNow(hikeId: Long) {
        if (!linked) return
        Async.io { enqueue(hikeId) }
    }

    private fun enqueue(hikeId: Long) {
        synchronized(queueLock) {
            val now = System.currentTimeMillis()
            val earlier = app.db.stravaPost(hikeId)
            if (earlier?.state == StravaPostState.POSTED) return
            // A hike already uploaded and being processed keeps its upload, so asking again can't upload it twice.
            val keep = earlier?.takeIf { it.state == StravaPostState.QUEUED || it.state == StravaPostState.PROCESSING }?.uploadId
            app.db.saveStravaPost(StravaPostRow(hikeId, StravaPostState.QUEUED, keep, null, null, 0, now, now))
        }
        changed()
        StravaUploadJob.schedule(app, 0)
    }

    /** Called at start-up: anything still waiting gets its turn. */
    fun resume() {
        Async.io { if (linked && app.db.stravaNextTry() != null) StravaUploadJob.schedule(app, 0) }
    }

    /**
     * Sends what is due. Runs on the upload job's thread. Returns how long until something else is due, or null when
     * nothing is waiting (or nothing can be sent until the user reconnects).
     */
    fun runQueue(): Long? = synchronized(queueLock) {
        if (!hasApp || !linked) return null
        val now = System.currentTimeMillis()
        if (!online()) return OFFLINE_WAIT_MS
        for (row in app.db.stravaDue(now)) {
            if (!linked) break
            process(row)
        }
        val next = app.db.stravaNextTry() ?: return null
        (next - System.currentTimeMillis()).coerceAtLeast(MIN_WAIT_MS)
    }

    private fun process(first: StravaPostRow) {
        var row = first
        val hike = app.db.hike(row.hikeId) ?: return
        val token = when (val auth = accessToken()) {
            is Auth.Token -> auth.access
            Auth.Reconnect -> return
            is Auth.Later -> { later(row, auth.reply); return }
        }
        var reply: StravaApi.Reply
        var uploadId = row.uploadId
        if (uploadId == null) {
            val segments = app.db.hikeSegments(hike.id)
            if (segments.sumOf { it.size } < 2) { save(row, StravaPostState.SKIPPED, message = "This hike has no track to post."); return }
            val kind = StravaActivityKind.of(prefs.stravaKind)
            val gpx = StringWriter().also {
                GpxWriter.writeTrack(it, hike.name, segments, description = StravaPolicy.DESCRIPTION,
                    activityType = if (kind == StravaActivityKind.WALK) "walking" else "hiking")
            }.toString().toByteArray(Charsets.UTF_8)
            reply = StravaApi.upload(token, gpx, "trailmind-${hike.id}.gpx", StravaPolicy.activityName(hike.name), kind,
                StravaPolicy.externalId(hike.startMs, hike.id))
            reply = retryOnceIfRefused(reply) { fresh -> StravaApi.upload(fresh, gpx, "trailmind-${hike.id}.gpx", StravaPolicy.activityName(hike.name), kind,
                StravaPolicy.externalId(hike.startMs, hike.id)) } ?: return
            if (reply !is StravaApi.Reply.Ok) { later(row, reply); return }
            uploadId = reply.body.optLong("id").takeIf { it > 0 }
            if (uploadId == null) { save(row, StravaPostState.FAILED, message = "Strava didn't say what became of the upload."); return }
            save(row, StravaPostState.PROCESSING, uploadId = uploadId)
            // From here every later save keeps the upload's id, so a failed check can't make the file go up again.
            row = row.copy(uploadId = uploadId)
        } else {
            reply = StravaApi.uploadStatus(token, uploadId)
            if (reply !is StravaApi.Reply.Ok) { later(row, reply); return }
        }
        // Strava processes a file in a couple of seconds; check on it for a while before leaving it for later.
        for (i in 0 until StravaPolicy.POLL_TRIES) {
            val body = (reply as? StravaApi.Reply.Ok)?.body
            if (body != null) {
                val result = StravaPolicy.classify(
                    body.optString("status").takeIf { !body.isNull("status") },
                    body.optString("error").takeIf { !body.isNull("error") },
                    body.optLong("activity_id").takeIf { !body.isNull("activity_id") },
                )
                when (result) {
                    is StravaUploadResult.Ready -> { finished(row, hike, result.activityId); return }
                    is StravaUploadResult.Duplicate -> {
                        save(row, StravaPostState.POSTED, uploadId = uploadId, message = "Already on Strava.")
                        return
                    }
                    is StravaUploadResult.Failed -> { save(row, StravaPostState.FAILED, uploadId = uploadId, message = result.message); return }
                    StravaUploadResult.Processing -> Unit
                }
            } else {
                later(row, reply)
                return
            }
            try { Thread.sleep(StravaPolicy.POLL_MS) } catch (_: InterruptedException) { Thread.currentThread().interrupt(); return }
            reply = StravaApi.uploadStatus(token, uploadId)
        }
        // Still processing: ask again soon, without counting it as a failure.
        save(row, StravaPostState.PROCESSING, uploadId = uploadId, nextTryMs = System.currentTimeMillis() + 60_000)
    }

    private fun finished(row: StravaPostRow, hike: HikeMeta, activityId: Long) {
        app.db.saveStravaPost(StravaPostRow(row.hikeId, StravaPostState.POSTED, row.uploadId, activityId, null, row.attempts, 0, System.currentTimeMillis()))
        changed()
        notifyPosted(hike, activityId)
    }

    private fun save(row: StravaPostRow, state: StravaPostState, uploadId: Long? = row.uploadId, message: String? = null, nextTryMs: Long = 0) {
        app.db.saveStravaPost(StravaPostRow(row.hikeId, state, uploadId, null, message, row.attempts, nextTryMs, System.currentTimeMillis()))
        changed()
    }

    /** A call that didn't succeed: wait and try again, or give up, depending on why. */
    private fun later(row: StravaPostRow, reply: StravaApi.Reply) {
        val now = System.currentTimeMillis()
        when {
            reply is StravaApi.Reply.Http && reply.code == 429 ->
                app.db.saveStravaPost(StravaPostRow(row.hikeId, StravaPostState.QUEUED, row.uploadId, null, "Strava's limit was reached; trying again later.",
                    row.attempts, now + StravaPolicy.RATE_LIMIT_WAIT_MS, now))
            reply is StravaApi.Reply.Http && reply.code == 403 -> markReconnect()
            reply is StravaApi.Reply.Http && reply.code in 400..499 && reply.code != 408 ->
                save(row, StravaPostState.FAILED, message = "Strava refused it (HTTP ${reply.code}): ${reply.message}")
            else -> {
                val attempts = row.attempts + 1
                val why = when (reply) {
                    is StravaApi.Reply.Offline -> "No connection to Strava: ${reply.message}"
                    is StravaApi.Reply.Http -> "Strava had a problem (HTTP ${reply.code})."
                    is StravaApi.Reply.Ok -> "Strava's answer wasn't understood."
                }
                if (attempts >= StravaPolicy.MAX_ATTEMPTS) {
                    app.db.saveStravaPost(StravaPostRow(row.hikeId, StravaPostState.FAILED, row.uploadId, null, "$why Gave up after $attempts tries.", attempts, 0, now))
                } else {
                    app.db.saveStravaPost(StravaPostRow(row.hikeId, StravaPostState.QUEUED, row.uploadId, null, why, attempts, now + StravaPolicy.retryDelayMs(attempts), now))
                }
            }
        }
        changed()
    }

    // ---------------------------------------------------------------- tokens

    private sealed interface Auth {
        data class Token(val access: String) : Auth
        data object Reconnect : Auth
        data class Later(val reply: StravaApi.Reply) : Auth
    }

    private fun accessToken(force: Boolean = false): Auth {
        val refresh = prefs.stravaRefreshToken
        if (refresh.isBlank()) return Auth.Reconnect
        val tokens = StravaTokens(prefs.stravaAccessToken, refresh, prefs.stravaExpiresAtS, prefs.stravaScope)
        if (!force && tokens.accessToken.isNotBlank() && !tokens.needsRefresh(System.currentTimeMillis() / 1000)) return Auth.Token(tokens.accessToken)
        return when (val r = StravaApi.refresh(prefs.stravaClientId, prefs.stravaClientSecret, refresh)) {
            is StravaApi.Reply.Ok -> { storeTokens(r.body); Auth.Token(prefs.stravaAccessToken) }
            is StravaApi.Reply.Http -> if (r.code in 400..403) { markReconnect(); Auth.Reconnect } else Auth.Later(r)
            is StravaApi.Reply.Offline -> Auth.Later(r)
        }
    }

    /** If Strava says the token is no good, gets a fresh one and sends the same request once more. Null: the user must reconnect. */
    private fun retryOnceIfRefused(first: StravaApi.Reply, again: (String) -> StravaApi.Reply): StravaApi.Reply? {
        if (first !is StravaApi.Reply.Http || first.code != 401) return first
        return when (val auth = accessToken(force = true)) {
            is Auth.Token -> again(auth.access)
            Auth.Reconnect -> null
            is Auth.Later -> auth.reply
        }
    }

    private fun markReconnect() {
        if (prefs.stravaNeedsReconnect) return
        prefs.stravaNeedsReconnect = true
        changed()
        val open = PendingIntent.getActivity(app, 40, Intent(app, MainActivity::class.java).setAction(MainActivity.ACTION_STRAVA)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(app, Notifications.CH_STRAVA)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("Strava needs you to connect again")
            .setContentText("Hikes are waiting to be posted. Tap to reconnect.")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { Notifications.manager(app).notify(Notifications.ID_STRAVA, n) }
    }

    private fun notifyPosted(hike: HikeMeta, activityId: Long) {
        val view = PendingIntent.getActivity(app, 41, Intent(Intent.ACTION_VIEW, Uri.parse(StravaPolicy.activityUrl(activityId))),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(app, Notifications.CH_STRAVA)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("Posted to Strava")
            .setContentText(hike.name)
            .setContentIntent(view)
            .setAutoCancel(true)
            .build()
        runCatching { Notifications.manager(app).notify(Notifications.ID_STRAVA_POSTED, n) }
    }

    // ---------------------------------------------------------------- network

    /** Strava needs normal signal: a satellite link only carries texts and small updates. */
    private fun online(): Boolean {
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && !SatelliteNetworkManager.isSatellite(caps)
    }

    private companion object {
        const val OFFLINE_WAIT_MS = 5 * 60_000L
        const val MIN_WAIT_MS = 5_000L
    }
}
