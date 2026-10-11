package com.trailmind.app.frontier.group

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.location.LocationManager
import android.os.BatteryManager
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.data.GroupMemberRow
import com.trailmind.app.data.TripGroupRow
import com.trailmind.app.frontier.FallAlert
import com.trailmind.app.location.Fix
import com.trailmind.app.location.TrackingState
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Notifications
import com.trailmind.core.format.Units
import com.trailmind.core.frontier.EmergencyStatus
import com.trailmind.core.frontier.HikerTelemetry
import com.trailmind.core.frontier.group.GroupAdvert
import com.trailmind.core.frontier.group.GroupCode
import com.trailmind.core.frontier.group.GroupFrame
import com.trailmind.core.frontier.group.GroupFrames
import com.trailmind.core.frontier.group.GroupHikeWatch
import com.trailmind.core.frontier.group.GroupKeys
import com.trailmind.core.frontier.group.PeerTable
import com.trailmind.core.frontier.group.PositionFrame
import com.trailmind.core.frontier.group.ProfileFrame
import com.trailmind.core.frontier.group.RadioPlan
import com.trailmind.core.frontier.group.RadioProfile
import com.trailmind.core.frontier.group.RangeFrame
import com.trailmind.core.frontier.group.RelayPolicy
import com.trailmind.core.frontier.group.needsHelp
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import java.security.SecureRandom
import java.text.DateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.concurrent.CopyOnWriteArraySet
import kotlin.math.abs

/** A trip group as this phone holds it. */
class TripGroup(
    val id: String,
    val name: String,
    val code: GroupCode,
    val memberId: Int,
    val displayName: String,
    val colour: Int,
    val createdMs: Long,
    val expiresMs: Long,
) {
    val keys = GroupKeys(code)

    fun with(displayName: String = this.displayName, expiresMs: Long = this.expiresMs) =
        TripGroup(id, name, code, memberId, displayName, colour, createdMs, expiresMs)
}

/**
 * Trip-group sharing. This phone's position goes out sealed with the group's code, and the group's positions come in,
 * directly or passed on by members in between. It runs while TrailMind is on screen or a hike is recording (the
 * recording's foreground service keeps it going with the screen off), and only after the user creates or joins a
 * group. All the work happens on one background thread; the UI reads snapshots and is told when they change.
 */
class GroupSharing(private val app: TrailMindApp) : GroupRadio.Listener {
    enum class Readiness { UNSUPPORTED, NO_GROUP, OFF, PERMISSIONS, BLUETOOTH_OFF, NO_EXTENDED, READY }

    private val thread = HandlerThread("trip-group").apply { start() }
    private val handler = Handler(thread.looper)
    val radio = GroupRadio(app, handler, this)
    private val random = SecureRandom()
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private val relay = RelayPolicy()
    private val hikeWatch = GroupHikeWatch()
    private var table = PeerTable(0)

    /**
     * Told (on the main thread, with the member's name) that someone in the group is recording a group hike that this
     * phone isn't. Set while TrailMind is on screen, which is the only time an idle phone listens to the group.
     */
    @Volatile var groupHikeHandler: ((String) -> Unit)? = null

    /** Finding a member up close with UWB, over this radio. */
    val finder = GroupFinder(app, handler, object : GroupFinder.Host {
        override fun group() = group
        override fun nowS() = this@GroupSharing.nowS()
        override fun peer(memberId: Int) = table.peer(memberId)
        override fun inRange(peer: PeerTable.Peer) = this@GroupSharing.inRange(peer)
        override fun nameOf(peer: PeerTable.Peer) = this@GroupSharing.nameOf(peer)
        override fun changed() {
            reconcile()
            publishSoon()
        }
    })

    @Volatile var group: TripGroup? = null; private set
    @Volatile var members: List<PeerTable.Peer> = emptyList(); private set
    @Volatile var plan: RadioPlan? = null; private set
    /** How far the phone's clock is from GPS time, when that's more than a minute; used for tags and ages. */
    @Volatile var clockSkewMs = 0L; private set
    @Volatile var boostUntilMs = 0L; private set
    @Volatile var opened = 0L; private set
    @Volatile var unreadable = 0L; private set
    @Volatile var ownFrame: PositionFrame? = null; private set

    @Volatile private var uiVisible = false
    @Volatile private var recording = false
    private var lastFix: Fix? = null
    private var ownFrameMs = 0L
    private var profileMs = 0L
    private var epoch = Long.MIN_VALUE
    private var codedHeardMs = 0L
    private var capabilities: GroupRadio.Capabilities? = null
    private val helpAlerted = HashMap<Int, Long>()
    private val savedMs = HashMap<Int, Long>()
    private val log = ArrayDeque<String>()
    private var publishPending = false

    private val tick = object : Runnable {
        override fun run() {
            onTick()
            handler.postDelayed(this, TICK_MS)
        }
    }
    private val onFix: (Fix) -> Unit = { f -> handler.post { fix(f) } }
    private val onFall: () -> Unit = { handler.post { statusChanged() } }

    fun start() {
        handler.post {
            load()
            finder.uwb.refresh()
            handler.post(tick)
        }
        app.location.addListener(onFix)
        FallAlert.addListener(onFall)
    }

    fun addListener(l: () -> Unit) = listeners.add(l)
    fun removeListener(l: () -> Unit) = listeners.remove(l)

    fun setUiVisible(visible: Boolean) {
        handler.post { uiVisible = visible; reconcile() }
    }

    fun setRecording(on: Boolean) {
        handler.post { recording = on; reconcile() }
    }

    /** This phone's hike has ended: the group hikes still going on were its invitation too, so they aren't offered back. */
    fun hikeFinished() {
        handler.post { hikeWatch.handleAll(table.peers(), System.currentTimeMillis()) }
    }

    /** The offer for [memberId] couldn't be shown (the screen went off first), so it may be made again. */
    private fun offerLost(memberId: Int) {
        handler.post { hikeWatch.forget(memberId) }
    }

    fun settingsChanged() {
        handler.post { finder.uwb.refresh(); reconcile(); publish() }
    }

    /** "Find my group": advertise and listen flat out for half an hour. */
    fun boost() {
        handler.post {
            boostUntilMs = System.currentTimeMillis() + RadioProfile.BOOST_MS
            reconcile()
            publish()
        }
    }

    fun create(name: String, displayName: String, done: (TripGroup) -> Unit) {
        handler.post { newGroup(GroupCode.generate(random), name, displayName).also { g -> Async.ui { done(g) } } }
    }

    fun join(code: GroupCode, name: String, displayName: String, done: (TripGroup) -> Unit) {
        handler.post {
            val current = group
            val g = if (current != null && current.code == code) current else newGroup(code, name, displayName)
            Async.ui { done(g) }
        }
    }

    fun leave() {
        handler.post { leaveNow() }
    }

    /** Another day on the trip, up to a week from now. */
    fun extend() {
        handler.post {
            val g = group ?: return@post
            val now = System.currentTimeMillis()
            val expires = minOf(maxOf(g.expiresMs, now) + TRIP_MS, now + MAX_TRIP_MS)
            saveGroup(g.with(expiresMs = expires))
            publish()
        }
    }

    fun rename(displayName: String) {
        handler.post {
            val g = group ?: return@post
            val name = displayName.trim().ifBlank { return@post }
            app.prefs.groupDisplayName = name
            saveGroup(g.with(displayName = name))
            profileMs = 0
            reconcile()
            publish()
        }
    }

    fun readiness(): Readiness {
        if (!GroupRadio.supported()) return Readiness.UNSUPPORTED
        if (group == null) return Readiness.NO_GROUP
        if (!app.prefs.frontierEnabled) return Readiness.OFF
        if (!GroupRadio.hasPermissions(app)) return Readiness.PERMISSIONS
        val caps = radio.capabilities()
        if (!caps.enabled) return Readiness.BLUETOOTH_OFF
        if (caps.maxFrames == 0) return Readiness.NO_EXTENDED
        return Readiness.READY
    }

    /** Whether the recording's foreground service should also declare the connected-device type. */
    fun needsConnectedDeviceType(): Boolean =
        GroupRadio.supported() && group != null && app.prefs.frontierEnabled && GroupRadio.hasPermissions(app)

    /** GPS-corrected time, which the group's tags and ages use. */
    fun nowMs(): Long = System.currentTimeMillis() - clockSkewMs
    fun nowS(): Long = nowMs() / 1_000

    /** Heard from the member's own phone in the last two minutes. */
    fun inRange(peer: PeerTable.Peer): Boolean = System.currentTimeMillis() - peer.lastDirectMs < IN_RANGE_MS

    fun nameOf(peer: PeerTable.Peer): String = peer.name?.takeIf { it.isNotBlank() } ?: "Hiker ${"%04X".format(peer.memberId and 0xFFFF)}"
    fun colourOf(peer: PeerTable.Peer): Int = COLOURS[Math.floorMod(peer.colour ?: peer.memberId, COLOURS.size)]
    fun ownColour(): Int = COLOURS[Math.floorMod(group?.colour ?: 0, COLOURS.size)]

    fun statusLine(): String = when (readiness()) {
        Readiness.UNSUPPORTED -> "Trip groups need Android 12 or newer."
        Readiness.NO_GROUP -> "Not in a trip group."
        Readiness.OFF -> "Frontier safety features are off."
        Readiness.PERMISSIONS -> "Allow Nearby devices so TrailMind can reach your group."
        Readiness.BLUETOOTH_OFF -> "Bluetooth is off."
        Readiness.NO_EXTENDED -> "This phone's Bluetooth can't carry trip-group messages (no extended advertising)."
        Readiness.READY -> {
            val radioText = when {
                plan == null -> "Starts when TrailMind is open or a hike is recording"
                !app.prefs.frontierHeartbeatsEnabled -> "Listening only: your position isn't shared"
                radio.adverts.any { it.coded && it.running } && radio.adverts.any { !it.coded && it.running } -> "Long-range Bluetooth"
                radio.adverts.any { it.coded && it.running } -> "Long-range Bluetooth only (standard didn't start)"
                radio.adverts.any { it.running } -> "Standard Bluetooth"
                else -> radio.adverts.firstNotNullOfOrNull { it.error }?.let { "Can't broadcast: $it" } ?: "Starting Bluetooth…"
            }
            val all = members
            "$radioText · ${all.count(::inRange)} of ${all.size} in range"
        }
    }

    /** For the recording notification, e.g. "Group 2/3". */
    fun summary(): String? {
        if (group == null || plan == null) return null
        val all = members
        return "Group ${all.count(::inRange)}/${all.size}"
    }

    fun logCsv(): String = synchronized(log) {
        buildString {
            appendLine("time,member,frame,sequence,hops,ttl,result,rssi_dbm,phy,tx_power_dbm,lat,lon,distance_m,own_lat,own_lon")
            log.forEach { appendLine(it) }
        }
    }

    fun clearLog() = synchronized(log) { log.clear() }

    // ---------------------------------------------------------------- radio callbacks (group thread)

    override fun onAdvert(payload: ByteArray, rssi: Int, coded: Boolean, txPower: Int?) {
        val g = group ?: return
        val nowMs = System.currentTimeMillis()
        val nowS = nowS()
        val result = GroupAdvert.open(listOf(g.keys), payload, nowS)
        if (result == null) {
            unreadable++
            return
        }
        opened++
        if (coded) codedHeardMs = nowMs
        for (frame in result.frames) {
            if (frame is RangeFrame) finder.onFrame(frame)
            val outcome = table.accept(frame, nowMs, nowS, rssi, coded)
            if (outcome == PeerTable.Result.NEW || outcome == PeerTable.Result.NEWER || outcome == PeerTable.Result.SAME) relay.offer(frame, nowMs)
            if (outcome == PeerTable.Result.NEW || outcome == PeerTable.Result.NEWER) news(frame, nowMs)
            record(frame, outcome, rssi, coded, txPower, nowMs)
        }
        publishSoon()
    }

    override fun onRadioChanged() = publishSoon()

    // ---------------------------------------------------------------- internals (group thread)

    private fun load() {
        val row = app.db.tripGroup() ?: return
        val code = GroupKeyStore.unwrap(row.secret)?.let { GroupCode.parse(String(it, Charsets.US_ASCII)) }
        val g = code?.let { TripGroup(row.id, row.name, it, row.memberId, row.displayName, row.colour, row.createdMs, row.expiresMs) }
        if (g == null || g.keys.groupId != row.id) {
            Log.w(TAG, "trip group key unavailable; the user needs to join again")
            app.db.deleteTripGroups()
            return
        }
        group = g
        table = PeerTable(g.memberId)
        for (m in app.db.groupMembers(g.id)) {
            val position = m.position?.let { GroupFrames.decode(it) as? PositionFrame }
            table.restore(PeerTable.Peer(m.memberId, m.name, m.colour, position, m.positionMs, m.heardMs, m.directMs, m.rssi, m.coded))
        }
        members = table.peers()
    }

    private fun newGroup(code: GroupCode, name: String, displayName: String): TripGroup {
        val now = System.currentTimeMillis()
        val keys = GroupKeys(code)
        val g = TripGroup(keys.groupId, name.trim().ifBlank { "Trip group" }, code, random.nextInt(),
            displayName.trim().ifBlank { "Hiker" }, random.nextInt(COLOURS.size), now, now + TRIP_MS)
        app.prefs.groupDisplayName = g.displayName
        app.prefs.groupSequence = 0
        saveGroup(g)
        table = PeerTable(g.memberId)
        relay.clear()
        hikeWatch.clear()
        helpAlerted.clear()
        savedMs.clear()
        ownFrame = null
        ownFrameMs = 0
        profileMs = 0
        clearLog()
        (lastFix ?: app.location.latest)?.let(::makeOwn)
        reconcile()
        publish()
        return g
    }

    private fun saveGroup(g: TripGroup) {
        app.db.saveTripGroup(TripGroupRow(g.id, g.name, GroupKeyStore.wrap(g.code.text.toByteArray(Charsets.US_ASCII)), g.memberId,
            g.displayName, g.colour, g.createdMs, g.expiresMs))
        group = g
    }

    private fun leaveNow() {
        finder.leave()
        group = null
        app.db.deleteTripGroups()
        table = PeerTable(0)
        relay.clear()
        hikeWatch.clear()
        helpAlerted.clear()
        savedMs.clear()
        ownFrame = null
        members = emptyList()
        boostUntilMs = 0
        clearLog()
        runCatching { Notifications.manager(app).cancel(Notifications.ID_GROUP_HELP) }
        reconcile()
        publish()
    }

    private fun onTick() {
        val g = group ?: return
        val now = System.currentTimeMillis()
        // A trip never ends under a hike that's still recording.
        if (now > g.expiresMs && !recording) {
            leaveNow()
            return
        }
        if (boostUntilMs in 1..now) boostUntilMs = 0
        finder.tick()
        checkGroupHike()
        val e = GroupKeys.epoch(nowS())
        val rotate = epoch != Long.MIN_VALUE && e != epoch
        epoch = e
        reconcile()
        if (rotate) radio.restartAdverts()
        publish()
    }

    private fun reconcile() {
        val ready = readiness() == Readiness.READY
        val battery = app.getSystemService(BatteryManager::class.java)?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            ?.takeIf { it in 0..100 }
        val powerSave = app.getSystemService(PowerManager::class.java)?.isPowerSaveMode == true
        // Finding with UWB needs its asks and answers to cross quickly, and a phone must still hear (and send) Stop with its screen off.
        val boost = System.currentTimeMillis() < boostUntilMs || finder.needsRadio
        val p = if (ready) RadioProfile.plan(uiVisible || finder.needsRadio, recording, boost, battery, powerSave, app.prefs.groupRelayEnabled) else null
        plan = p
        if (p == null) {
            radio.update(null, null, false)
            return
        }
        capabilities = radio.capabilities()
        // With sharing off, adverts carry only a UWB ask or answer, and the name that goes with it.
        val share = app.prefs.frontierHeartbeatsEnabled
        radio.update(p, if (share || finder.outgoing() != null) payload(p, share) else null, app.prefs.groupLongRange)
    }

    private fun payload(plan: RadioPlan, share: Boolean): ByteArray? {
        val g = group ?: return null
        val max = capabilities?.maxFrames ?: 0
        if (max == 0) return null
        val nowMs = System.currentTimeMillis()
        val nowS = nowS()
        val frames = ArrayList<GroupFrame>(max)
        if (share) ownFrame?.let { frames += it.copy(capabilities = capabilityBits(), flags = flags()) }
        finder.outgoing()?.let { if (frames.size < max) frames += it }
        val profileDue = frames.isEmpty() || nowMs - profileMs > PROFILE_MS
        if (share && plan.relay) frames += relay.pick(nowMs, nowS, max - frames.size - (if (profileDue) 1 else 0), plan.relayHelpOnly)
        if (frames.size < max) {
            frames += ProfileFrame(g.memberId, g.colour, g.displayName)
            profileMs = nowMs
        }
        return GroupAdvert.build(g.keys, nowS, frames, random)
    }

    private fun fix(f: Fix) {
        lastFix = f
        // Only a fix taken moments ago says anything about the clock; a cached one is simply old.
        val ageMs = (SystemClock.elapsedRealtimeNanos() - f.location.elapsedRealtimeNanos) / 1_000_000
        if (f.location.provider == LocationManager.GPS_PROVIDER && f.location.time > 0 && ageMs in 0..FRESH_FIX_MS) {
            val skew = System.currentTimeMillis() - ageMs - f.location.time
            clockSkewMs = if (abs(skew) > CLOCK_TOLERANCE_MS) skew else 0
        }
        if (group == null) return
        val prev = ownFrame
        val moved = prev == null || Geo.distanceM(prev.lat, prev.lon, f.lat, f.lon) >= MOVE_M
        if (!moved && System.currentTimeMillis() - ownFrameMs < if (uiVisible) 5_000 else 10_000) return
        makeOwn(f)
        if (plan != null) reconcile()
    }

    private fun makeOwn(f: Fix) {
        val g = group ?: return
        val seq = (app.prefs.groupSequence + 1) and 0xFFFF_FFFFL
        app.prefs.groupSequence = seq
        val originS = (f.location.time.takeIf { it > 0 } ?: nowMs()) / 1_000
        val battery = app.getSystemService(BatteryManager::class.java)?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: 0
        ownFrame = PositionFrame.of(g.memberId, seq, originS, f.lat, f.lon, f.altitudeM, f.accuracyM, battery.coerceIn(0, 100), status(),
            capabilities = capabilityBits(), flags = flags())
        ownFrameMs = System.currentTimeMillis()
    }

    private fun statusChanged() {
        val status = status()
        if (ownFrame?.status == status) return
        (lastFix ?: app.location.latest)?.let(::makeOwn)
        if (status.needsHelp) boostUntilMs = System.currentTimeMillis() + RadioProfile.BOOST_MS
        reconcile()
        publish()
    }

    private fun status(): EmergencyStatus = when (FallAlert.stage(app)) {
        FallAlert.Stage.COUNTDOWN -> EmergencyStatus.FALL_DETECTED
        FallAlert.Stage.TEXT_READY, FallAlert.Stage.SENDING, FallAlert.Stage.SENT -> EmergencyStatus.CRITICAL_SOS
        else -> EmergencyStatus.fromWire(app.prefs.frontierEmergencyStatus).takeIf { it.needsHelp } ?: EmergencyStatus.OK
    }

    private fun capabilityBits(): Int {
        var bits = 0
        if (radio.adverts.any { it.coded && it.running }) bits = bits or GroupFrames.CAP_CODED_TX
        if (System.currentTimeMillis() - codedHeardMs < 10 * 60_000L) bits = bits or GroupFrames.CAP_CODED_RX
        if (app.prefs.groupRelayEnabled) bits = bits or GroupFrames.CAP_RELAY
        if (app.frontier.satelliteState.dataAvailable) bits = bits or GroupFrames.CAP_SATELLITE
        return bits or finder.capabilityBits()
    }

    private fun flags(): Int = when (TrackingState.status) {
        TrackingState.Status.RECORDING ->
            GroupFrames.FLAG_RECORDING or if (app.prefs.groupHikes) GroupFrames.FLAG_GROUP_HIKE else 0
        TrackingState.Status.PAUSED -> GroupFrames.FLAG_PAUSED or if (app.prefs.groupHikes) GroupFrames.FLAG_GROUP_HIKE else 0
        TrackingState.Status.IDLE -> 0
    }

    /** Offers this phone's user the group hike another member is recording, once, when it isn't recording itself. */
    private fun checkGroupHike() {
        val sink = groupHikeHandler ?: return
        if (!app.prefs.groupHikes || !uiVisible || recording || TrackingState.status != TrackingState.Status.IDLE) return
        val peer = hikeWatch.next(table.peers(), nowS(), System.currentTimeMillis()) ?: return
        val who = nameOf(peer)
        Async.ui { if (groupHikeHandler === sink) sink(who) else offerLost(peer.memberId) }
    }

    private fun news(frame: GroupFrame, nowMs: Long) {
        val peer = table.peer(frame.memberId) ?: return
        var important = frame is ProfileFrame
        if (frame is PositionFrame) {
            checkGroupHike()
            if (frame.status.needsHelp) {
                alertHelp(peer, frame)
                important = true
            } else if (helpAlerted.remove(frame.memberId) != null) {
                runCatching { Notifications.manager(app).cancel(Notifications.ID_GROUP_HELP) }
                important = true
            }
        }
        if (!important && nowMs - (savedMs[frame.memberId] ?: 0L) < SAVE_MS) return
        savedMs[frame.memberId] = nowMs
        val g = group ?: return
        try {
            val p = peer.position
            app.db.upsertGroupMember(g.id, GroupMemberRow(peer.memberId, peer.name, peer.colour, p?.let(GroupFrames::encode),
                peer.positionReceivedMs, peer.lastHeardMs, peer.lastDirectMs, peer.rssi, peer.coded))
            // The satellite message carries the whole group, so a gateway phone can report members it heard.
            if (p != null) app.db.upsertMeshHeartbeat(HikerTelemetry("%08x".format(p.memberId), p.lat, p.lon, p.altitudeM ?: 0,
                p.batteryPercent, p.originTimeS, p.status, p.triageCode), nowMs)
        } catch (e: Exception) {
            Log.w(TAG, "could not save a member", e)
        }
    }

    private fun alertHelp(peer: PeerTable.Peer, frame: PositionFrame) {
        boostUntilMs = System.currentTimeMillis() + RadioProfile.BOOST_MS
        val first = helpAlerted.put(peer.memberId, frame.originTimeS) == null
        reconcile()
        if (!first || !app.prefs.groupHelpAlerts) return
        val what = when (frame.status) {
            EmergencyStatus.FALL_DETECTED -> "may have fallen"
            EmergencyStatus.CRITICAL_SOS -> "needs help"
            else -> "is hurt"
        }
        val there = LatLon(frame.lat, frame.lon)
        val where = lastFix?.let { f ->
            val here = LatLon(f.lat, f.lon)
            val b = Geo.bearingDeg(here, there)
            "${Units.distance(Geo.distanceM(here, there), app.prefs.imperial)} ${Geo.cardinal(b)} of you"
        }
        val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(frame.originTimeS * 1_000))
        val text = listOfNotNull(where, "position from $time", if (frame.hops > 0) "passed on by the group" else null).joinToString(" · ")
        val open = PendingIntent.getActivity(app, 30, Intent(app, MainActivity::class.java)
            .setAction(MainActivity.ACTION_GROUP_MEMBER).putExtra(MainActivity.EXTRA_MEMBER, peer.memberId)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(app, Notifications.CH_GROUP)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("${nameOf(peer)} $what")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText("$text\n\nTap to see them on the map and get a bearing."))
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_ALARM)
            .setAutoCancel(true)
            .build()
        runCatching { Notifications.manager(app).notify(Notifications.ID_GROUP_HELP, n) }
    }

    private fun record(frame: GroupFrame, outcome: PeerTable.Result, rssi: Int, coded: Boolean, txPower: Int?, nowMs: Long) {
        val own = lastFix
        val p = frame as? PositionFrame
        val distance = if (p != null && own != null) Geo.distanceM(own.lat, own.lon, p.lat, p.lon).toInt().toString() else ""
        val line = listOf(
            nowMs, "%08x".format(frame.memberId), when (frame) { is PositionFrame -> "position"; is ProfileFrame -> "profile"; is RangeFrame -> "range" },
            p?.sequence ?: "", frame.hops, frame.ttl,
            outcome.name.lowercase(), rssi, if (coded) "coded" else "1m", txPower ?: "", p?.lat ?: "", p?.lon ?: "", distance,
            own?.lat ?: "", own?.lon ?: "",
        ).joinToString(",")
        synchronized(log) {
            log.addLast(line)
            while (log.size > MAX_LOG_LINES) log.removeFirst()
        }
    }

    private fun publishSoon() {
        if (publishPending) return
        publishPending = true
        handler.postDelayed({ publishPending = false; publish() }, 500)
    }

    private fun publish() {
        members = table.peers()
        Async.ui { listeners.forEach { it() } }
    }

    companion object {
        private const val TAG = "GroupSharing"
        private const val TICK_MS = 5_000L
        private const val PROFILE_MS = 20_000L
        private const val SAVE_MS = 30_000L
        private const val MOVE_M = 10.0
        private const val IN_RANGE_MS = 2 * 60_000L
        private const val CLOCK_TOLERANCE_MS = 60_000L
        private const val FRESH_FIX_MS = 10_000L
        private const val MAX_LOG_LINES = 5_000
        const val TRIP_MS = 24 * 3_600_000L
        const val MAX_TRIP_MS = 7 * 24 * 3_600_000L

        /** Member colours; red is kept for calls for help. */
        val COLOURS = intArrayOf(
            0xFF00897B.toInt(), 0xFFEF6C00.toInt(), 0xFF7B1FA2.toInt(), 0xFF388E3C.toInt(),
            0xFF3949AB.toInt(), 0xFFC2185B.toInt(), 0xFF6D4C41.toInt(), 0xFF827717.toInt(),
        )
    }
}
