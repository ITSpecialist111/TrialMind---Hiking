package com.trailmind.app.frontier.group

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Notifications
import com.trailmind.core.frontier.group.GroupFrames
import com.trailmind.core.frontier.group.PeerTable
import com.trailmind.core.frontier.group.RangeFrame
import com.trailmind.core.frontier.group.UwbSession
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArraySet
import kotlin.math.abs

/**
 * Finding one member up close with UWB. The finder's phone asks in the group's sealed adverts; the other phone answers,
 * and each starts a UWB session with settings it works out from the group's key, so Bluetooth only carries the ask.
 * Everything runs on the trip-group thread; the UI reads [state] and listens for changes.
 */
class GroupFinder(private val app: TrailMindApp, private val handler: Handler, private val host: Host) : UwbRadio.Listener {
    interface Host {
        fun group(): TripGroup?
        fun nowS(): Long
        fun peer(memberId: Int): PeerTable.Peer?
        fun inRange(peer: PeerTable.Peer): Boolean
        fun nameOf(peer: PeerTable.Peer): String
        /** What this phone advertises changed: the next adverts must carry it. */
        fun changed()
    }

    enum class Role { FINDING, FOUND }
    enum class Phase { ASKING, STARTING, RANGING, ENDED }

    data class State(
        val role: Role,
        val memberId: Int,
        val nonce: Long,
        val phase: Phase,
        val startedMs: Long,
        /** Why it ended, or what is wrong while it runs. */
        val note: String? = null,
        val measurement: UwbRadio.Measurement? = null,
        /** When [measurement] arrived (elapsed realtime), 0 before the first. */
        val measuredAt: Long = 0,
    ) {
        val active: Boolean get() = phase != Phase.ENDED
    }

    val uwb = UwbRadio(app, handler, this)

    @Volatile var state: State? = null; private set
    val active: Boolean get() = state?.active == true
    /** A find is running, or its last Stop or Decline is still going out: the radio and the process must stay up. */
    val needsRadio: Boolean get() = active || (reply != null && System.currentTimeMillis() < replyUntilMs)
    /** What the last one-phone UWB test found, for the diagnostics page. */
    @Volatile var selfTest: String? = null; private set

    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private val random = SecureRandom()
    private var request: RangeFrame? = null
    @Volatile private var reply: RangeFrame? = null
    @Volatile private var replyUntilMs = 0L
    /** Requests already answered or ended, so repeats of their adverts are ignored. */
    private val handled = LinkedHashMap<Long, Long>()
    private var session: UwbRadio.Session? = null
    private var retries = 0
    private var lastResultPublishMs = 0L
    private val retry = Runnable { restartSession() }
    private var testing: String? = null
    private var testStarted = false
    private val endTest = Runnable { finishSelfTest() }
    private var serviceOn = false
    private var serviceTriedFor: Long? = null
    private var notified: Any? = null
    private var notifiedAt = 0L

    fun addListener(l: () -> Unit) = listeners.add(l)
    fun removeListener(l: () -> Unit) = listeners.remove(l)

    fun refresh() { handler.post { uwb.refresh() } }

    /** Whether this phone could find [peer] now: both phones have UWB and the peer is in direct Bluetooth range. */
    fun canFind(peer: PeerTable.Peer): Boolean =
        UwbRadio.supported(app) && host.inRange(peer) && (peer.position?.capabilities ?: 0) and PEER_UWB != 0

    fun find(memberId: Int) { handler.post { startFinding(memberId, 0) } }

    fun stop() { handler.post { end(if (state?.role == Role.FOUND) "You stopped it." else "Stopped.", tellPeer = true) } }

    /**
     * Starts UWB for a few seconds as a finder with nobody to answer, to show whether this phone accepts TrailMind's
     * settings. Needs no second phone and sends nothing over Bluetooth.
     */
    fun selfTest() { handler.post { startSelfTest(0) } }

    private fun startSelfTest(attempt: Int) {
        val g = host.group()
        val c = uwb.capabilities
        if (g == null || active || testing != null) return
        if ((c.state == UwbRadio.State.CHECKING || c.state == UwbRadio.State.NO_PERMISSION) && attempt < CHECK_ATTEMPTS) {
            uwb.refresh()
            handler.postDelayed({ startSelfTest(attempt + 1) }, CHECK_MS)
            return
        }
        val config = listOf(UwbSession.CONFIG_PROVISIONED, UwbSession.CONFIG_STATIC).firstOrNull { usable(c, it) }
        if (config == null) {
            selfTest = unavailable(c)
            publish()
            return
        }
        val preamble = UwbSession.PREAMBLES.first { c.supports(config, UwbSession.CHANNEL, it, UPDATE_RATE) }
        val derived = UwbSession.derive(g.keys, g.memberId, random.nextInt(), random.nextLong())
        val settings = "${if (config == UwbSession.CONFIG_PROVISIONED) "provisioned" else "static"} STS, channel ${UwbSession.CHANNEL}, preamble $preamble"
        testing = settings
        testStarted = false
        selfTest = "Testing UWB with $settings…"
        val ok = uwb.start(UwbRadio.Session(initiator = true, sessionId = derived.sessionId, configId = config, channel = UwbSession.CHANNEL,
            preamble = preamble, updateRate = UPDATE_RATE, localAddress = derived.localAddress(initiator = true),
            peerAddress = derived.peerAddress(initiator = true), key = derived.keyFor(config)!!, angle = c.azimuth))
        if (!ok) {
            testing = null
            selfTest = "UWB refused $settings straight away."
        } else handler.postDelayed(endTest, SELF_TEST_MS)
        publish()
    }

    private fun finishSelfTest() {
        val settings = testing ?: return
        testing = null
        uwb.stop()
        if (selfTest?.startsWith("Testing") == true) selfTest = if (testStarted)
            "UWB started with $settings, so this phone accepts TrailMind's settings. No phone answered, as expected."
        else "UWB didn't report starting with $settings within ${SELF_TEST_MS / 1_000} s."
        publish()
    }

    /** A real find or answer needs the UWB the test was using. */
    private fun cancelSelfTest() {
        if (testing == null) return
        handler.removeCallbacks(endTest)
        testing = null
        selfTest = null
        uwb.stop()
    }

    /** The frame to add to this phone's adverts, if any. */
    fun outgoing(): RangeFrame? {
        if (reply != null && System.currentTimeMillis() >= replyUntilMs) reply = null
        return reply ?: request
    }

    /** The capability bits this phone's position frames carry. */
    fun capabilityBits(): Int {
        if (!app.prefs.groupUwbFindable) return 0
        val c = uwb.capabilities
        var bits = 0
        if (usable(c, UwbSession.CONFIG_PROVISIONED)) bits = bits or GroupFrames.CAP_UWB
        if (usable(c, UwbSession.CONFIG_STATIC)) bits = bits or GroupFrames.CAP_UWB_STATIC
        return bits
    }

    fun onFrame(frame: RangeFrame) {
        val g = host.group() ?: return
        if (frame.targetId != g.memberId) return
        val s = state
        val ours = s != null && s.active && s.memberId == frame.memberId && s.nonce == frame.nonce
        when (frame.kind) {
            RangeFrame.REQUEST -> answer(g, frame)
            RangeFrame.ACCEPT -> if (ours && s!!.role == Role.FINDING && s.phase == Phase.ASKING) startInitiator(g, s)
            RangeFrame.DECLINE -> if (ours && s!!.role == Role.FINDING) end(declined(frame.reason), tellPeer = false)
            RangeFrame.STOP -> if (ours) end(if (s!!.role == Role.FINDING) "${name(s.memberId)} stopped it on their phone." else "${name(s.memberId)} stopped finding you.", tellPeer = false)
        }
    }

    fun tick() {
        val now = System.currentTimeMillis()
        handled.entries.removeAll { now - it.value > HANDLED_MS }
        sync()
        val s = state ?: return
        if (!s.active) return
        val quietMs = SystemClock.elapsedRealtime() - s.measuredAt
        when {
            s.role == Role.FINDING && s.phase == Phase.ASKING && now - s.startedMs > ASK_MS ->
                end("No answer from ${name(s.memberId)}'s phone. It needs TrailMind open or a hike recording, with UWB on.", tellPeer = true)
            s.role == Role.FOUND && s.measuredAt == 0L && now - s.startedMs > FOUND_WAIT_MS ->
                end("${name(s.memberId)}'s phone didn't start UWB.", tellPeer = true)
            s.role == Role.FOUND && s.measuredAt > 0L && quietMs > FOUND_WAIT_MS -> end("Lost touch with ${name(s.memberId)}'s phone.", tellPeer = true)
            now - s.startedMs > MAX_SESSION_MS -> end("Stopped after ${MAX_SESSION_MS / 60_000} minutes to save battery.", tellPeer = true)
        }
    }

    /** Leaving the group: stop at once, with no one left to tell. */
    fun leave() {
        handler.removeCallbacks(retry)
        uwb.stop()
        request = null
        reply = null
        session = null
        state = null
        publish()
    }

    // ---------------------------------------------------------------- UWB callbacks (group thread)

    override fun onUwbCapabilities() {
        host.changed()
        publish()
    }

    override fun onUwbEvent(event: UwbRadio.Event) {
        testing?.let { settings ->
            when (event) {
                UwbRadio.Event.Started -> testStarted = true
                is UwbRadio.Event.Result -> selfTest = "UWB measured ${event.measurement.distanceM?.let { "%.2f m".format(it) } ?: "something"} " +
                    "with $settings: another phone answered."
                is UwbRadio.Event.Stopped -> if (!testStarted) selfTest = "UWB stopped with $settings: ${uwb.reasonText(event.reason)}."
                is UwbRadio.Event.OpenFailed -> selfTest = "UWB refused $settings: ${uwb.reasonText(event.reason)}."
            }
            if (event is UwbRadio.Event.OpenFailed || (event is UwbRadio.Event.Stopped && !testStarted)) {
                handler.removeCallbacks(endTest)
                testing = null
            }
            publish()
            return
        }
        val s = state ?: return
        if (!s.active) return
        when (event) {
            UwbRadio.Event.Started -> update(s.copy(phase = Phase.RANGING, note = null))
            is UwbRadio.Event.Result -> {
                retries = 0
                state = s.copy(phase = Phase.RANGING, note = null, measurement = event.measurement, measuredAt = SystemClock.elapsedRealtime())
                // Results come every quarter of a second; the notification and pages needn't redraw that often.
                val now = SystemClock.elapsedRealtime()
                if (now - lastResultPublishMs >= RESULT_PUBLISH_MS) {
                    lastResultPublishMs = now
                    publish()
                }
            }
            is UwbRadio.Event.Stopped -> {
                val byPeer = uwb.stoppedByPeer(event.reason)
                // A finder keeps trying while its user waits; the found phone only waits for a finder that hasn't started.
                val again = !byPeer && retries < MAX_RETRIES && (s.role == Role.FINDING || s.measuredAt == 0L)
                when {
                    again -> {
                        retries++
                        update(s.copy(phase = Phase.STARTING, note = "No UWB reply yet (${uwb.reasonText(event.reason)}). Move closer, in the open."))
                        handler.removeCallbacks(retry)
                        handler.postDelayed(retry, RETRY_MS)
                    }
                    s.role == Role.FOUND -> end("${name(s.memberId)} stopped finding you.", tellPeer = !byPeer)
                    byPeer -> end("Their phone stopped answering.", tellPeer = false)
                    else -> end("UWB stopped: ${uwb.reasonText(event.reason)}.", tellPeer = true)
                }
            }
            is UwbRadio.Event.OpenFailed -> {
                val g = host.group()
                if (s.role == Role.FOUND && g != null) {
                    // A decline tells the finder why, where a plain stop would only say the phone went quiet.
                    end("UWB wouldn't start: ${uwb.reasonText(event.reason)}.", tellPeer = false)
                    send(RangeFrame(g.memberId, s.memberId, RangeFrame.DECLINE, s.nonce, host.nowS(), reason = RangeFrame.REASON_FAILED), STOP_REPEAT_MS)
                } else end("UWB wouldn't start: ${uwb.reasonText(event.reason)}.", tellPeer = true)
            }
        }
    }

    // ---------------------------------------------------------------- internals (group thread)

    private fun startFinding(memberId: Int, attempt: Int) {
        val g = host.group() ?: return
        val peer = host.peer(memberId) ?: return
        val c = uwb.capabilities
        // Just after the permission is granted the module takes a moment to report what the phone can do.
        if ((c.state == UwbRadio.State.CHECKING || c.state == UwbRadio.State.NO_PERMISSION) && attempt < CHECK_ATTEMPTS) {
            uwb.refresh()
            handler.postDelayed({ startFinding(memberId, attempt + 1) }, CHECK_MS)
            return
        }
        if (state?.active == true) end(null, tellPeer = true)
        cancelSelfTest()
        val now = System.currentTimeMillis()
        val peerBits = peer.position?.capabilities ?: 0
        val config = when {
            peerBits and GroupFrames.CAP_UWB != 0 && usable(c, UwbSession.CONFIG_PROVISIONED) -> UwbSession.CONFIG_PROVISIONED
            peerBits and GroupFrames.CAP_UWB_STATIC != 0 && usable(c, UwbSession.CONFIG_STATIC) -> UwbSession.CONFIG_STATIC
            else -> null
        }
        val preambles = config?.let { cfg -> UwbSession.PREAMBLES.filter { c.supports(cfg, UwbSession.CHANNEL, it, UPDATE_RATE) } }.orEmpty()
        val nonce = random.nextLong()
        if (config == null || preambles.isEmpty()) {
            state = State(Role.FINDING, memberId, nonce, Phase.ENDED, now, note = unavailable(c))
            publish()
            return
        }
        retries = 0
        request = RangeFrame(g.memberId, memberId, RangeFrame.REQUEST, nonce, host.nowS(), configId = config,
            channel = UwbSession.CHANNEL, preambleIndex = preambles[random.nextInt(preambles.size)], updateRate = UPDATE_RATE)
        reply = null
        state = State(Role.FINDING, memberId, nonce, Phase.ASKING, now)
        host.changed()
        publish()
    }

    private fun answer(g: TripGroup, f: RangeFrame) {
        if (abs(host.nowS() - f.timeS) > MAX_REQUEST_AGE_S || f.nonce in handled) return
        val s = state
        if (s != null && s.active) {
            if (s.role == Role.FOUND && s.memberId == f.memberId && s.nonce == f.nonce) return
            decline(g, f, RangeFrame.REASON_BUSY)
            return
        }
        val c = uwb.capabilities
        when {
            !app.prefs.groupUwbFindable -> return decline(g, f, RangeFrame.REASON_NOT_ALLOWED)
            c.state != UwbRadio.State.READY -> return decline(g, f, RangeFrame.REASON_UWB_OFF)
            !c.supports(f.configId, f.channel, f.preambleIndex, f.updateRate) -> return decline(g, f, RangeFrame.REASON_UNSUPPORTED)
        }
        val derived = UwbSession.derive(g.keys, f.memberId, g.memberId, f.nonce)
        val key = derived.keyFor(f.configId) ?: return decline(g, f, RangeFrame.REASON_UNSUPPORTED)
        val start = UwbRadio.Session(initiator = false, sessionId = derived.sessionId, configId = f.configId, channel = f.channel,
            preamble = f.preambleIndex, updateRate = f.updateRate, localAddress = derived.localAddress(initiator = false),
            peerAddress = derived.peerAddress(initiator = false), key = key, angle = false)
        handled[f.nonce] = System.currentTimeMillis()
        cancelSelfTest()
        if (!uwb.start(start)) return decline(g, f, RangeFrame.REASON_FAILED)
        session = start
        state = State(Role.FOUND, f.memberId, f.nonce, Phase.STARTING, System.currentTimeMillis())
        send(RangeFrame(g.memberId, f.memberId, RangeFrame.ACCEPT, f.nonce, host.nowS()), ACCEPT_REPEAT_MS)
        publish()
    }

    private fun startInitiator(g: TripGroup, s: State) {
        val req = request ?: return
        request = null
        val derived = UwbSession.derive(g.keys, g.memberId, s.memberId, s.nonce)
        val start = UwbRadio.Session(initiator = true, sessionId = derived.sessionId, configId = req.configId, channel = req.channel,
            preamble = req.preambleIndex, updateRate = req.updateRate, localAddress = derived.localAddress(initiator = true),
            peerAddress = derived.peerAddress(initiator = true), key = derived.keyFor(req.configId) ?: return,
            angle = uwb.capabilities.azimuth)
        session = start
        handled[s.nonce] = System.currentTimeMillis()
        if (!uwb.start(start)) {
            end("UWB wouldn't start on this phone.", tellPeer = true)
            return
        }
        update(s.copy(phase = Phase.STARTING))
    }

    private fun restartSession() {
        val s = state ?: return
        val start = session ?: return
        if (!s.active) return
        if (!uwb.start(start)) end("UWB wouldn't start on this phone.", tellPeer = true)
    }

    private fun end(note: String?, tellPeer: Boolean) {
        handler.removeCallbacks(retry)
        val s = state ?: return
        if (!s.active) return
        uwb.stop()
        session = null
        request = null
        val g = host.group()
        if (tellPeer && g != null) send(RangeFrame(g.memberId, s.memberId, RangeFrame.STOP, s.nonce, host.nowS()), STOP_REPEAT_MS)
        handled[s.nonce] = System.currentTimeMillis()
        state = s.copy(phase = Phase.ENDED, note = note)
        host.changed()
        publish()
    }

    private fun decline(g: TripGroup, f: RangeFrame, reason: Int) {
        handled[f.nonce] = System.currentTimeMillis()
        Log.i(TAG, "declined a UWB request: reason $reason")
        send(RangeFrame(g.memberId, f.memberId, RangeFrame.DECLINE, f.nonce, host.nowS(), reason = reason), STOP_REPEAT_MS)
    }

    private fun send(frame: RangeFrame, forMs: Long) {
        reply = frame
        replyUntilMs = System.currentTimeMillis() + forMs
        host.changed()
    }

    private fun update(s: State) {
        state = s
        publish()
    }

    private fun publish() {
        sync()
        Async.ui { listeners.forEach { it() } }
    }

    private fun name(memberId: Int): String = host.peer(memberId)?.let(host::nameOf) ?: "Hiker ${"%04X".format(memberId and 0xFFFF)}"

    private fun usable(c: UwbRadio.Capabilities, config: Int): Boolean =
        UwbSession.PREAMBLES.any { c.supports(config, UwbSession.CHANNEL, it, UPDATE_RATE) }

    private fun declined(reason: Int): String = when (reason) {
        RangeFrame.REASON_NOT_ALLOWED -> "They've turned off being found with UWB."
        RangeFrame.REASON_UWB_OFF -> "UWB is off on their phone (or it's in flight mode)."
        RangeFrame.REASON_BUSY -> "Their phone is already ranging with someone else. Try again in a minute."
        RangeFrame.REASON_UNSUPPORTED -> "Their phone can't use the UWB settings this one asked for."
        else -> "Their phone couldn't start UWB."
    }

    private fun unavailable(c: UwbRadio.Capabilities): String = when (c.state) {
        UwbRadio.State.UNSUPPORTED -> "This phone doesn't have UWB that TrailMind can use (it needs Android 16)."
        UwbRadio.State.NO_PERMISSION -> "Allow Nearby devices so TrailMind can use UWB."
        UwbRadio.State.CHECKING -> "Still checking this phone's UWB. Try again in a moment."
        UwbRadio.State.OFF -> "UWB is off. Turn on Ultra-wideband (UWB) in Settings."
        UwbRadio.State.BLOCKED -> "UWB isn't allowed here or in flight mode."
        UwbRadio.State.READY -> "These two phones have no UWB settings in common."
    }

    /** Keeps the foreground service and its notification in step with the find. */
    private fun sync() {
        val want = needsRadio
        val s = state
        if (want && !serviceOn && s != null && serviceTriedFor != s.nonce) {
            // Once per find: from the background Android refuses, and the find still runs while TrailMind does.
            serviceTriedFor = s.nonce
            serviceOn = GroupFindService.start(app)
        } else if (!want && serviceOn) {
            GroupFindService.stop(app)
            serviceOn = false
        }
        val nm = Notifications.manager(app)
        if (!want || s == null) {
            if (notified != null) runCatching { nm.cancel(Notifications.ID_GROUP_FIND) }
            notified = null
            return
        }
        val key = listOf(s.role, s.phase, s.memberId, s.nonce, s.note)
        val now = SystemClock.elapsedRealtime()
        if (key == notified && now - notifiedAt < NOTIFY_MS) return
        notified = key
        notifiedAt = now
        notification()?.let { n -> runCatching { nm.notify(Notifications.ID_GROUP_FIND, n) } }
    }

    /** The ongoing notification for the find in progress, with a Stop button, or null when there is none. */
    fun notification(): Notification? {
        val s = state ?: return null
        val who = name(s.memberId)
        val distance = s.measurement?.distanceM?.takeIf { s.active }?.let { uwbDistance(it, app.prefs.imperial) }
        val title = when {
            !s.active -> "UWB finding ended"
            s.role == Role.FOUND -> "$who is finding you with UWB"
            else -> "Finding $who with UWB"
        }
        val text = when {
            !s.active -> s.note ?: "Stopped."
            distance != null -> if (s.role == Role.FOUND) "$distance away · tap to see it" else "$distance away"
            s.phase == Phase.ASKING -> "Asking their phone…"
            else -> "Starting UWB…"
        }
        val open = PendingIntent.getActivity(app, 31, Intent(app, MainActivity::class.java)
            .setAction(MainActivity.ACTION_GROUP_FIND).putExtra(MainActivity.EXTRA_MEMBER, s.memberId)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(app, 32, Intent(app, GroupFindService::class.java).setAction(GroupFindService.ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(app, Notifications.CH_GROUP_FIND)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(s.active)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .apply { if (s.active) addAction(Notification.Action.Builder(null, "Stop", stop).build()) }
            .build()
    }

    companion object {
        private const val TAG = "GroupFinder"
        private const val PEER_UWB = GroupFrames.CAP_UWB or GroupFrames.CAP_UWB_STATIC
        /** RawRangingDevice.UPDATE_RATE_NORMAL: a measurement every 240 ms. */
        private const val UPDATE_RATE = 1
        private const val ASK_MS = 30_000L
        /** How long the found phone waits for the finder's first measurement, or for the next after one. */
        private const val FOUND_WAIT_MS = 60_000L
        private const val ACCEPT_REPEAT_MS = 20_000L
        private const val STOP_REPEAT_MS = 6_000L
        private const val RETRY_MS = 3_000L
        private const val MAX_RETRIES = 100
        private const val RESULT_PUBLISH_MS = 200L
        private const val HANDLED_MS = 10 * 60_000L
        private const val MAX_REQUEST_AGE_S = 120L
        private const val CHECK_ATTEMPTS = 10
        private const val CHECK_MS = 300L
        private const val SELF_TEST_MS = 8_000L
        private const val NOTIFY_MS = 2_000L
        const val MAX_SESSION_MS = 15 * 60_000L

        /** "3.4 m" close in, "27 m" further; feet for imperial. */
        fun uwbDistance(m: Double, imperial: Boolean): String = if (imperial) {
            val ft = m * 3.28084
            if (ft < 10) "%.1f ft".format(ft) else "${Math.round(ft)} ft"
        } else if (m < 10) "%.1f m".format(m) else "${Math.round(m)} m"
    }
}
