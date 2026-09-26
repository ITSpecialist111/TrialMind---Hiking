package com.trailmind.app.watch

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.trailmind.app.Async
import com.trailmind.app.TrailMindApp
import com.trailmind.app.location.TrackingService
import com.trailmind.app.location.TrackingState
import com.trailmind.app.map.TileGrid
import com.trailmind.app.map.TileSource
import com.trailmind.app.map.TileSources
import com.trailmind.core.format.Units
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.Sun
import com.trailmind.core.geo.TileKey
import com.trailmind.core.watch.TileReply
import com.trailmind.core.watch.TileRequest
import com.trailmind.core.watch.WatchProtocol
import com.trailmind.core.watch.WatchRoute
import com.trailmind.core.watch.WatchState
import com.trailmind.core.watch.WatchTrack
import com.trailmind.core.watch.WatchWaypoint
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Serves the TrailMind watch app over Bluetooth RFCOMM using framework APIs only (no Google Play services).
 * Listens while the phone UI is visible, a hike is recording or [WatchLinkService] keeps it up in the background,
 * and only accepts the watch chosen in Settings.
 */
class WatchLink(private val app: TrailMindApp) {
    enum class Status { OFF, NO_BLUETOOTH, NO_PERMISSION, BLUETOOTH_OFF, NO_WATCH_CHOSEN, WAITING, CONNECTED }

    @Volatile var status = Status.OFF; private set
    @Volatile var connectedName: String? = null; private set
    /** The watch app is on screen (as it last reported). */
    @Volatile var watchVisible = false; private set
    val watchActive: Boolean get() = status == Status.CONNECTED && watchVisible
    private var uiVisible = false
    @Volatile private var server: BluetoothServerSocket? = null
    @Volatile private var conn: Connection? = null
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private var pushPending = false
    private var lastPushMs = 0L
    private val pushNow = Runnable {
        pushPending = false
        lastPushMs = SystemClock.elapsedRealtime()
        conn?.let { push(it, force = false) }
    }
    private val adapter: BluetoothAdapter? get() = app.getSystemService(BluetoothManager::class.java)?.adapter

    init {
        TrackingState.addListener { refresh(); schedulePush() }
        app.nav.addListener { schedulePush() }
        app.location.addListener { schedulePush() }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = refresh()
        }
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else app.registerReceiver(receiver, filter)
    }

    fun addListener(l: () -> Unit) = listeners.add(l)
    fun removeListener(l: () -> Unit) = listeners.remove(l)

    fun setUiVisible(visible: Boolean) {
        uiVisible = visible
        refresh()
    }

    fun hasPermission() = Build.VERSION.SDK_INT < 31 ||
        app.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    /** Paired devices as (name, address), watches first, for the Settings picker. */
    @SuppressLint("MissingPermission")
    fun bondedDevices(): List<Pair<String, String>> {
        if (!hasPermission()) return emptyList()
        val devices = runCatching { adapter?.bondedDevices }.getOrNull() ?: return emptyList()
        return devices.sortedByDescending { it.bluetoothClass?.majorDeviceClass == BluetoothClass.Device.Major.WEARABLE }
            .map { (it.name ?: it.address) to it.address }
    }

    fun statusText(): String = when (status) {
        Status.OFF -> "Off."
        Status.NO_BLUETOOTH -> "This phone has no Bluetooth."
        Status.NO_PERMISSION -> "Allow \u201cNearby devices\u201d so TrailMind can talk to your watch."
        Status.BLUETOOTH_OFF -> "Bluetooth is off."
        Status.NO_WATCH_CHOSEN -> "Choose your watch below."
        Status.WAITING -> "Ready \u2013 open TrailMind on the watch."
        Status.CONNECTED -> "Connected to ${connectedName ?: "your watch"}."
    }

    /** Starts or stops listening to match settings, permission, Bluetooth state and app visibility. Main thread. */
    fun refresh() {
        val prefs = app.prefs
        val canServe = prefs.watchEnabled && hasPermission() && prefs.watchAddress.isNotBlank()
        // The background service can only be started while the UI is on screen.
        if (canServe && uiVisible && !WatchLinkService.running) WatchLinkService.start(app)
        if (!prefs.watchEnabled && WatchLinkService.running) WatchLinkService.stop(app)
        val wanted = prefs.watchEnabled && (uiVisible || WatchLinkService.running || TrackingService.running ||
            TrackingState.status != TrackingState.Status.IDLE)
        val a = adapter
        val blocker = when {
            !wanted -> Status.OFF
            a == null -> Status.NO_BLUETOOTH
            !hasPermission() -> Status.NO_PERMISSION
            !a.isEnabled -> Status.BLUETOOTH_OFF
            prefs.watchAddress.isBlank() -> Status.NO_WATCH_CHOSEN
            else -> null
        }
        if (blocker != null) { stopServer(); setStatus(blocker); return }
        if (server == null) startServer(a!!)
    }

    private fun setStatus(s: Status, name: String? = connectedName) {
        if (status == s && connectedName == name) return
        status = s
        connectedName = name
        notifyListeners()
    }

    private fun notifyListeners() {
        Async.main.post { listeners.forEach { it() } }
    }

    private fun setWatchVisible(v: Boolean) {
        if (watchVisible == v) return
        watchVisible = v
        notifyListeners()
    }

    @SuppressLint("MissingPermission")
    private fun startServer(a: BluetoothAdapter) {
        val s = try {
            a.listenUsingRfcommWithServiceRecord("TrailMind", UUID.fromString(WatchProtocol.SERVICE_UUID))
        } catch (e: Exception) {
            Log.w(TAG, "cannot listen", e)
            setStatus(Status.BLUETOOTH_OFF)
            return
        }
        server = s
        if (conn == null) setStatus(Status.WAITING, null)
        Thread({ acceptLoop(s) }, "watch-accept").apply { isDaemon = true; start() }
    }

    private fun stopServer() {
        val s = server ?: return
        server = null
        runCatching { s.close() }
        conn?.close()
    }

    @SuppressLint("MissingPermission")
    private fun acceptLoop(s: BluetoothServerSocket) {
        while (true) {
            val socket = try { s.accept() } catch (_: IOException) { return }
            if (!socket.remoteDevice.address.equals(app.prefs.watchAddress, ignoreCase = true)) {
                Log.w(TAG, "rejected a connection from a device that isn't the chosen watch")
                runCatching { socket.close() }
                continue
            }
            conn?.close()
            val c = Connection(socket)
            conn = c
            if (server !== s) { c.close(); return }
            c.start()
        }
    }

    // The watch draws Web Mercator tiles only, so a British National Grid base map goes to it as OS Outdoor.
    private fun currentSource(): TileSource = TileSources.byId(app.prefs.baseSourceId, app.prefs, app.tiles.packs)
        .let { if (it.grid == TileGrid.WEB_MERCATOR) it else TileSources.byId(TileSources.OS_OUTDOOR, app.prefs, app.tiles.packs) }

    // ---------------------------------------------------------------- phone -> watch (main thread)

    private fun schedulePush() {
        val c = conn ?: return
        // A hidden watch only needs occasional updates, but an off-route change goes out at once.
        val interval = if (watchVisible) PUSH_INTERVAL_MS else HIDDEN_PUSH_INTERVAL_MS
        val urgent = app.nav.offRoute != c.sentOffRoute
        if (pushPending && !urgent) return
        Async.main.removeCallbacks(pushNow)
        pushPending = true
        val wait = if (urgent) 0L else (interval - (SystemClock.elapsedRealtime() - lastPushMs)).coerceAtLeast(0)
        Async.main.postDelayed(pushNow, wait)
    }

    private fun push(c: Connection, force: Boolean) {
        c.send(WatchProtocol.STATE, buildState().encode())
        val route = app.nav.active
        val routeId = route?.data?.meta?.id ?: -1L
        if (force || routeId != c.sentRouteId) {
            c.sentRouteId = routeId
            val r = if (route == null) WatchRoute.NONE else WatchRoute(
                routeId, route.data.meta.name,
                WatchProtocol.decimate(route.data.points.map { it.latLon() }, MAX_ROUTE_POINTS),
                route.data.waypoints.map { WatchWaypoint(it.name, it.latLon()) },
            )
            c.send(WatchProtocol.ROUTE, r.encode())
        }
        val n = TrackingState.points.size
        val now = SystemClock.elapsedRealtime()
        if (force || n < c.sentTrackSize || (n != c.sentTrackSize && now - c.sentTrackMs >= TRACK_INTERVAL_MS)) {
            c.sentTrackSize = n
            c.sentTrackMs = now
            c.send(WatchProtocol.TRACK, WatchTrack.of(trackSegments(), MAX_TRACK_POINTS).encode())
        }
        val off = app.nav.offRoute
        if (off != c.sentOffRoute) {
            c.sentOffRoute = off
            val kind = if (off) WatchProtocol.ALERT_OFF_ROUTE else WatchProtocol.ALERT_BACK_ON_ROUTE
            c.send(WatchProtocol.ALERT, WatchProtocol.alert(kind, if (off) "Off route" else "Back on route"))
        }
    }

    private fun trackSegments(): List<List<LatLon>> {
        val points = TrackingState.points
        val out = ArrayList<List<LatLon>>()
        var start = 0
        for (end in TrackingState.line.breaks + points.size) {
            if (end > start) out.add(points.subList(start, end).map { it.latLon() })
            start = end
        }
        return out
    }

    private fun buildState(): WatchState {
        val f = app.location.latest
        val nav = app.nav
        val route = nav.active
        val rf = nav.fix
        val next = rf?.nextWaypoint
        val here = f?.let { LatLon(it.lat, it.lon) }
        val source = currentSource()
        val ahead = if (route != null && rf != null) route.guide.pointAt(rf.alongM + LOOK_AHEAD_M) else null
        return WatchState(
            recording = when (TrackingState.status) {
                TrackingState.Status.RECORDING -> WatchState.RECORDING
                TrackingState.Status.PAUSED -> WatchState.PAUSED
                TrackingState.Status.IDLE -> WatchState.IDLE
            },
            activeMs = TrackingState.activeMs(), distanceM = TrackingState.distanceM, ascentM = TrackingState.ascentM,
            imperial = app.prefs.imperial,
            hasFix = f != null, lat = f?.lat ?: 0.0, lon = f?.lon ?: 0.0, accuracyM = f?.accuracyM ?: 0f,
            altitudeM = f?.altitudeM ?: Double.NaN, fixTimeMs = f?.location?.time ?: 0L,
            grid = here?.let { OsGrid.fromWgs84(it)?.format(8) ?: Units.latLon(it.lat, it.lon) } ?: "",
            routeId = route?.data?.meta?.id ?: -1L, routeName = route?.data?.meta?.name ?: "",
            toGoM = rf?.remainingM ?: route?.guide?.totalM ?: Double.NaN,
            timeLeftMin = nav.remainingMinutes ?: route?.estimate?.planningMinutes ?: Double.NaN,
            climbLeftM = rf?.remainingAscentM ?: Double.NaN, progress = rf?.progress ?: Double.NaN,
            offRoute = nav.offRoute, offRouteM = rf?.offRouteM ?: 0.0,
            backBearingDeg = if (nav.offRoute && here != null && rf != null) Geo.bearingDeg(here, rf.snapped) else Double.NaN,
            nextName = next?.waypoint?.name ?: "", nextAlongM = next?.alongRouteM ?: Double.NaN,
            nextLat = next?.waypoint?.lat ?: Double.NaN, nextLon = next?.waypoint?.lon ?: Double.NaN,
            targetLat = nav.target?.lat ?: Double.NaN, targetLon = nav.target?.lon ?: Double.NaN,
            sunsetMs = here?.let { Sun.today(it).sunsetMs } ?: 0L,
            mapKey = source.id, attribution = source.attribution, mapMinZoom = source.minZoom, mapMaxZoom = source.maxZoom,
            pressureHpa = app.baro.pressureHpa ?: Double.NaN, pressureChangeHpa = app.baro.change3hHpa() ?: Double.NaN,
            aheadLat = ahead?.lat ?: Double.NaN, aheadLon = ahead?.lon ?: Double.NaN,
        )
    }

    // ---------------------------------------------------------------- watch -> phone

    private fun onCommand(code: Int) {
        val idle = TrackingState.status == TrackingState.Status.IDLE && !TrackingService.running
        when (code) {
            WatchProtocol.CMD_START -> if (idle) startHikeForWatch()
            WatchProtocol.CMD_PAUSE -> TrackingService.send(app, TrackingService.ACTION_PAUSE)
            WatchProtocol.CMD_RESUME -> TrackingService.send(app, TrackingService.ACTION_RESUME)
            WatchProtocol.CMD_FINISH -> TrackingService.send(app, TrackingService.ACTION_STOP)
            WatchProtocol.CMD_TRACBACK -> if (!app.nav.traceBack()) {
                conn?.send(WatchProtocol.ALERT, WatchProtocol.alert(WatchProtocol.ALERT_INFO, "Not enough track recorded yet."))
            }
            WatchProtocol.CMD_WATCH_VISIBLE -> {
                setWatchVisible(true)
                Async.main.removeCallbacks(pushNow)
                pushNow.run()
            }
            WatchProtocol.CMD_WATCH_HIDDEN -> setWatchVisible(false)
        }
    }

    /**
     * Android lets a visible app start location tracking; in the background this works only if the phone
     * allows it (for example with battery optimisation off), so check that it actually started.
     */
    private fun startHikeForWatch() {
        val fine = app.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val started = fine && (uiVisible || WatchLinkService.running) && runCatching { TrackingService.start(app) }
            .onFailure { Log.w(TAG, "cannot start recording from the watch", it) }.isSuccess
        if (!started) { tellWatchToUsePhone(); return }
        Async.main.postDelayed({
            if (TrackingState.status == TrackingState.Status.IDLE && !TrackingService.running) tellWatchToUsePhone()
        }, START_CHECK_MS)
    }

    private fun tellWatchToUsePhone() {
        conn?.send(WatchProtocol.ALERT, WatchProtocol.alert(WatchProtocol.ALERT_INFO, "Open TrailMind on your phone to start the hike."))
    }

    /** Forwards the barometer's storm warning; any thread. */
    fun weatherAlert(text: String) {
        conn?.send(WatchProtocol.ALERT, WatchProtocol.alert(WatchProtocol.ALERT_WEATHER, text))
    }

    fun daylightAlert(text: String) {
        conn?.send(WatchProtocol.ALERT, WatchProtocol.alert(WatchProtocol.ALERT_INFO, text))
    }

    private inner class Connection(private val socket: BluetoothSocket) {
        private val out = DataOutputStream(BufferedOutputStream(socket.outputStream, 16 * 1024))
        private val outbox = Outbox()
        private val writer = Thread({ writeLoop() }, "watch-write").apply { isDaemon = true }
        // Only visible tiles are requested; when the watch pans or zooms, stale requests are dropped first.
        private val tiles = ThreadPoolExecutor(2, 2, 30, TimeUnit.SECONDS, LinkedBlockingDeque(32),
            { r -> Thread(r, "watch-tiles").apply { isDaemon = true } }, ThreadPoolExecutor.DiscardOldestPolicy())
        @Volatile private var closed = false
        var sentRouteId = Long.MIN_VALUE
        var sentTrackSize = -1
        var sentTrackMs = 0L
        var sentOffRoute = false

        @SuppressLint("MissingPermission")
        fun start() {
            setStatus(Status.CONNECTED, runCatching { socket.remoteDevice.name }.getOrNull())
            // Watch apps that predate visibility reports are always treated as on screen.
            setWatchVisible(true)
            writer.start()
            Thread({ readLoop() }, "watch-read").apply { isDaemon = true; start() }
            send(WatchProtocol.HELLO, WatchProtocol.hello("TrailMind phone"))
            Async.main.post { if (!closed) push(this, force = true) }
        }

        fun send(type: Int, payload: ByteArray) {
            if (!closed) outbox.put(type, payload)
        }

        private fun writeLoop() {
            try {
                while (!closed) {
                    val (type, payload) = outbox.take()
                    WatchProtocol.writeFrame(out, type, payload)
                }
            } catch (_: IOException) {
                close()
            } catch (_: InterruptedException) { }
        }

        private fun readLoop() {
            val input = DataInputStream(BufferedInputStream(socket.inputStream, 16 * 1024))
            try {
                while (!closed) {
                    val f = WatchProtocol.readFrame(input)
                    when (f.type) {
                        WatchProtocol.TILE_REQUEST -> serveTile(TileRequest.decode(f.payload))
                        WatchProtocol.COMMAND -> f.payload.firstOrNull()?.toInt()?.let { code -> Async.main.post { onCommand(code) } }
                        else -> Unit
                    }
                }
            } catch (e: IOException) {
                Log.i(TAG, "watch link closed: ${e.message}")
            } finally {
                close()
            }
        }

        private fun serveTile(req: TileRequest) {
            try {
                tiles.execute {
                    val source = currentSource()
                    val bytes = if (req.mapKey != source.id) null
                    else runCatching { app.tiles.loadOrEnlargeBytes(source, TileKey(req.z, req.x, req.y), allowNetwork = true) }.getOrNull()
                    send(WatchProtocol.TILE, TileReply(req, bytes?.takeIf { it.size <= MAX_TILE_BYTES }).encode())
                }
            } catch (_: RejectedExecutionException) { }
        }

        fun close() {
            if (closed) return
            closed = true
            runCatching { socket.close() }
            writer.interrupt()
            tiles.shutdownNow()
            if (conn === this) {
                conn = null
                setWatchVisible(false)
                setStatus(if (server != null) Status.WAITING else Status.OFF, null)
            }
        }
    }

    /**
     * Outgoing frames. Bluetooth is slow next to a tile, so alerts and the newest state go first and a
     * state that was superseded before it could be sent is dropped; tiles use whatever bandwidth is left.
     */
    private class Outbox {
        private val lock = ReentrantLock()
        private val ready = lock.newCondition()
        private val control = ArrayDeque<Pair<Int, ByteArray>>()
        private var state: ByteArray? = null
        private var track: ByteArray? = null
        private val tiles = ArrayDeque<ByteArray>()

        fun put(type: Int, payload: ByteArray) = lock.withLock {
            when (type) {
                WatchProtocol.STATE -> state = payload
                WatchProtocol.TRACK -> track = payload
                WatchProtocol.TILE -> tiles.addLast(payload)
                else -> control.addLast(type to payload)
            }
            ready.signal()
        }

        fun take(): Pair<Int, ByteArray> {
            lock.lock()
            try {
                while (true) {
                    control.removeFirstOrNull()?.let { return it }
                    state?.let { state = null; return WatchProtocol.STATE to it }
                    track?.let { track = null; return WatchProtocol.TRACK to it }
                    tiles.removeFirstOrNull()?.let { return WatchProtocol.TILE to it }
                    ready.await()
                }
            } finally {
                lock.unlock()
            }
        }
    }

    companion object {
        private const val TAG = "WatchLink"
        private const val PUSH_INTERVAL_MS = 1_000L
        private const val HIDDEN_PUSH_INTERVAL_MS = 15_000L
        private const val START_CHECK_MS = 4_000L
        private const val TRACK_INTERVAL_MS = 5_000L
        private const val MAX_ROUTE_POINTS = 2_000
        private const val MAX_TRACK_POINTS = 3_000
        private const val MAX_TILE_BYTES = 256 * 1024
        // How far along the route the watch's pointer aims: far enough to be steady, near enough to follow bends.
        private const val LOOK_AHEAD_M = 60.0
    }
}
