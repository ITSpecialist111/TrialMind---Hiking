package com.trailmind.app.frontier

import android.os.BatteryManager
import com.trailmind.app.Async
import com.trailmind.app.TrailMindApp
import com.trailmind.app.location.Fix
import com.trailmind.core.frontier.DetectedFall
import com.trailmind.core.frontier.EmergencyStatus
import com.trailmind.core.frontier.FallVector
import com.trailmind.core.frontier.FrontierTelemetryCodec
import com.trailmind.core.frontier.GroupMeshPayload
import com.trailmind.core.frontier.HikerTelemetry
import com.trailmind.core.frontier.PackedGroupPayload
import java.security.SecureRandom
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.CopyOnWriteArraySet
import kotlin.math.roundToInt

class FrontierCoordinator(private val app: TrailMindApp) {
    private val battery = app.getSystemService(BatteryManager::class.java)
    private val sequence = AtomicLong(app.prefs.frontierSequence)
    private val deviceId = app.prefs.frontierDeviceId.ifBlank {
        ByteArray(4).also(SecureRandom()::nextBytes).joinToString("") { "%02x".format(it) }
            .also { app.prefs.frontierDeviceId = it }
    }
    private val locationListener: (Fix) -> Unit = ::onFix
    private val networkManager = SatelliteNetworkManager(app) {
        satelliteState = it
        notifyListeners()
    }
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    @Volatile private var lastHeartbeatMs = 0L
    @Volatile private var localStatus = EmergencyStatus.fromWire(app.prefs.frontierEmergencyStatus)
    @Volatile private var pendingFall: FallVector? = app.prefs.frontierFallVector

    @Volatile
    var satelliteState = SatelliteLinkState()
        private set

    fun start() {
        applySettings()
    }

    fun stop() {
        app.location.removeListener(locationListener)
        networkManager.stop()
    }

    fun addListener(listener: () -> Unit) = listeners.add(listener)
    fun removeListener(listener: () -> Unit) = listeners.remove(listener)

    fun applySettings() {
        if (app.prefs.frontierEnabled && app.prefs.frontierHeartbeatsEnabled) {
            app.location.addListener(locationListener)
        } else {
            app.location.removeListener(locationListener)
        }
        if (app.prefs.frontierEnabled && app.prefs.frontierSatelliteDataEnabled) {
            networkManager.start()
        } else {
            networkManager.stop()
        }
        notifyListeners()
    }

    fun recordFall(fall: DetectedFall) {
        if (!app.prefs.frontierEnabled || !app.prefs.frontierFallDetectionEnabled) return
        localStatus = EmergencyStatus.FALL_DETECTED
        pendingFall = fall.fallVector
        app.prefs.frontierEmergencyStatus = localStatus.wireValue
        app.prefs.frontierFallVector = fall.fallVector
        app.location.latest?.let { fix ->
            Async.io { app.db.upsertMeshHeartbeat(telemetry(fix, localStatus)) }
        }
        notifyListeners()
        FallAlert.start(app)
    }

    fun preparePayload(): PackedGroupPayload {
        val nextSequence = sequence.incrementAndGet()
        app.prefs.frontierSequence = nextSequence
        val hikers = app.db.meshHeartbeats(System.currentTimeMillis() - HEARTBEAT_RETENTION_MS)
        return FrontierTelemetryCodec.pack(
            GroupMeshPayload(
                gatewayDeviceId = deviceId,
                messageSequence = nextSequence,
                hikers = hikers,
                fallTelemetry = pendingFall,
            ),
        )
    }

    fun openSatelliteDataConnection(url: URL): HttpURLConnection = networkManager.openDataConnection(url)

    fun markFallPayloadSent() {
        pendingFall = null
        app.prefs.frontierFallVector = null
    }

    fun clearEmergency() {
        localStatus = EmergencyStatus.OK
        pendingFall = null
        app.prefs.frontierEmergencyStatus = EmergencyStatus.OK.wireValue
        app.prefs.frontierFallVector = null
        app.location.latest?.let { fix -> Async.io { app.db.upsertMeshHeartbeat(telemetry(fix, localStatus)) } }
        notifyListeners()
    }

    fun statusText(): String = when {
        !app.prefs.frontierEnabled -> "Frontier safety is off"
        satelliteState.dataAvailable -> "Satellite data connected: TrailMind keeps to texts and small updates"
        satelliteState.textsOverSatellite -> "On ${satelliteState.operatorName ?: "satellite"}: texts work, calls don't"
        app.prefs.frontierSatelliteDataEnabled -> "Frontier active · not on satellite now"
        else -> "Frontier active · not watching for satellite"
    }

    fun heartbeatText(nowMs: Long = System.currentTimeMillis()): String = when {
        !app.prefs.frontierEnabled -> "Disabled"
        !app.prefs.frontierHeartbeatsEnabled -> "Location heartbeats off"
        lastHeartbeatMs == 0L -> "Waiting for a location fix"
        else -> {
            val ageSeconds = ((nowMs - lastHeartbeatMs).coerceAtLeast(0L) / 1_000)
            "Last local heartbeat ${if (ageSeconds < 90) "${ageSeconds}s" else "${ageSeconds / 60} min"} ago"
        }
    }

    fun emergencyText(): String = when (localStatus) {
        EmergencyStatus.OK -> "No active emergency"
        else -> localStatus.name.replace('_', ' ').lowercase().replaceFirstChar(Char::uppercase)
    }

    private fun onFix(fix: Fix) {
        val now = System.currentTimeMillis()
        if (now - lastHeartbeatMs < HEARTBEAT_INTERVAL_MS) return
        lastHeartbeatMs = now
        Async.io {
            app.db.upsertMeshHeartbeat(telemetry(fix, localStatus), now)
            app.db.pruneMeshHeartbeats(now - HEARTBEAT_RETENTION_MS)
        }
        notifyListeners()
    }

    private fun telemetry(fix: Fix, status: EmergencyStatus) = HikerTelemetry(
        hikerId = deviceId,
        latitude = fix.lat,
        longitude = fix.lon,
        altitudeMeters = (fix.altitudeM ?: 0.0).roundToInt(),
        batteryPercent = battery?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)?.coerceIn(0, 100) ?: 0,
        timestampEpochSeconds = fix.location.time.takeIf { it > 0 }?.div(1_000) ?: System.currentTimeMillis() / 1_000,
        status = status,
    )

    private fun notifyListeners() = Async.ui { listeners.forEach { it() } }

    companion object {
        const val HEARTBEAT_INTERVAL_MS = 30_000L
        const val HEARTBEAT_RETENTION_MS = 10 * 60_000L
    }
}
