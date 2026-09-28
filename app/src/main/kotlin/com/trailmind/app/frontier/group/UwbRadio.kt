package com.trailmind.app.frontier.group

import android.Manifest
import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.ranging.RangingCapabilities
import android.ranging.RangingData
import android.ranging.RangingDevice
import android.ranging.RangingManager
import android.ranging.RangingPreference
import android.ranging.RangingSession
import android.ranging.SessionConfig
import android.ranging.raw.RawInitiatorRangingConfig
import android.ranging.raw.RawRangingDevice
import android.ranging.raw.RawResponderRangingConfig
import android.ranging.uwb.UwbAddress
import android.ranging.uwb.UwbComplexChannel
import android.ranging.uwb.UwbRangingParams
import android.util.Log
import java.util.UUID
import java.util.concurrent.Executor

/**
 * UWB ranging with one other phone through Android 16's Ranging module, using parameters TrailMind works out itself
 * (a raw session), so it needs neither Google Play services nor a connection between the phones. Every call and
 * callback runs on [handler]'s thread. What the phone supports is read from the module, never assumed from its model.
 */
class UwbRadio(private val context: Context, private val handler: Handler, private val listener: Listener) {
    interface Listener {
        fun onUwbCapabilities()
        fun onUwbEvent(event: Event)
    }

    enum class State { UNSUPPORTED, NO_PERMISSION, CHECKING, OFF, BLOCKED, READY }

    data class Capabilities(
        val state: State,
        val configIds: List<Int> = emptyList(),
        val channels: List<Int> = emptyList(),
        val preambles: List<Int> = emptyList(),
        val updateRates: List<Int> = emptyList(),
        val distance: Boolean = false,
        val azimuth: Boolean = false,
        val elevation: Boolean = false,
        val background: Boolean = false,
        val minIntervalMs: Long? = null,
    ) {
        fun supports(configId: Int, channel: Int, preamble: Int, updateRate: Int): Boolean = state == State.READY && distance &&
            configId in configIds && channel in channels && preamble in preambles && (updateRates.isEmpty() || updateRate in updateRates)
    }

    data class Measurement(
        val distanceM: Double?,
        val distanceConfidence: Int,
        val azimuthDeg: Double?,
        val azimuthConfidence: Int,
        val elevationDeg: Double?,
        val elevationConfidence: Int,
    )

    sealed interface Event {
        data object Started : Event
        data class Result(val measurement: Measurement) : Event
        data class Stopped(val reason: Int) : Event
        data class OpenFailed(val reason: Int) : Event
    }

    class Session(
        val initiator: Boolean,
        val sessionId: Int,
        val configId: Int,
        val channel: Int,
        val preamble: Int,
        val updateRate: Int,
        val localAddress: ByteArray,
        val peerAddress: ByteArray,
        val key: ByteArray,
        val angle: Boolean,
    )

    @Volatile var capabilities = Capabilities(if (supported(context)) State.CHECKING else State.UNSUPPORTED); private set

    private val impl: Impl? = if (Build.VERSION.SDK_INT >= 36 && supported(context)) Impl() else null

    /** Registers for capability updates once the Ranging permission is granted; call again after it changes. */
    fun refresh() { impl?.refresh() }

    /** Starts [session] in place of any running one; false if the module refused it straight away. */
    fun start(session: Session): Boolean = impl?.start(session) ?: false

    fun stop() { impl?.stop() }

    fun reasonText(reason: Int): String = impl?.reasonText(reason) ?: "error $reason"

    /** Whether a session stopped because the other phone ended it. */
    fun stoppedByPeer(reason: Int): Boolean = impl?.stoppedByPeer(reason) == true

    // TargetApi, not androidx RequiresApi: the app uses no AndroidX, and Impl is only created on Android 16 and later.
    @TargetApi(36)
    @SuppressLint("MissingPermission", "UseRequiresApi") // refresh() and start() check hasPermission() before any Ranging call.
    private inner class Impl {
        private val manager: RangingManager? = context.getSystemService(RangingManager::class.java)
        private val executor = Executor { handler.post(it) }
        private var registered = false
        private var session: RangingSession? = null

        private val capabilitiesCallback = RangingManager.RangingCapabilitiesCallback { caps ->
            capabilities = read(caps)
            Log.i(TAG, "capabilities: $capabilities")
            listener.onUwbCapabilities()
        }

        fun refresh() {
            val m = manager
            if (m == null) {
                capabilities = Capabilities(State.UNSUPPORTED)
                return
            }
            if (!hasPermission(context)) {
                if (registered) runCatching { m.unregisterCapabilitiesCallback(capabilitiesCallback) }
                registered = false
                stop()
                capabilities = Capabilities(State.NO_PERMISSION)
                listener.onUwbCapabilities()
                return
            }
            if (registered) return
            try {
                m.registerCapabilitiesCallback(executor, capabilitiesCallback)
                registered = true
            } catch (e: RuntimeException) {
                Log.w(TAG, "no ranging capabilities", e)
                capabilities = Capabilities(State.UNSUPPORTED)
                listener.onUwbCapabilities()
            }
        }

        private fun read(caps: RangingCapabilities): Capabilities {
            val state = when (caps.technologyAvailability[RangingManager.UWB]) {
                RangingCapabilities.ENABLED -> State.READY
                RangingCapabilities.DISABLED_USER -> State.OFF
                RangingCapabilities.DISABLED_REGULATORY, RangingCapabilities.DISABLED_USER_RESTRICTIONS -> State.BLOCKED
                else -> State.UNSUPPORTED
            }
            val uwb = caps.uwbCapabilities ?: return Capabilities(if (state == State.READY) State.UNSUPPORTED else state)
            return Capabilities(
                state = state,
                configIds = uwb.supportedConfigIds.toList(),
                channels = uwb.supportedChannels.toList(),
                preambles = uwb.supportedPreambleIndexes.toList(),
                updateRates = uwb.supportedRangingUpdateRates.toList(),
                distance = uwb.isDistanceMeasurementSupported,
                azimuth = uwb.isAzimuthalAngleSupported,
                elevation = uwb.isElevationAngleSupported,
                background = uwb.isBackgroundRangingSupported,
                minIntervalMs = uwb.minimumRangingInterval?.toMillis(),
            )
        }

        fun start(s: Session): Boolean {
            val m = manager ?: return false
            if (!hasPermission(context)) return false
            stop()
            val callback = SessionCallback()
            return try {
                val params = UwbRangingParams.Builder(s.sessionId, s.configId, UwbAddress.fromBytes(s.localAddress), UwbAddress.fromBytes(s.peerAddress))
                    .setComplexChannel(UwbComplexChannel.Builder().setChannel(s.channel).setPreambleIndex(s.preamble).build())
                    .setRangingUpdateRate(s.updateRate)
                    .setSessionKeyInfo(s.key)
                    .build()
                val device = RawRangingDevice.Builder()
                    .setRangingDevice(RangingDevice.Builder().setUuid(UUID(PEER_UUID_HIGH, s.sessionId.toLong())).build())
                    .setUwbRangingParams(params)
                    .build()
                val config = if (s.initiator) RawInitiatorRangingConfig.Builder().addRawRangingDevice(device).build()
                else RawResponderRangingConfig.Builder().setRawRangingDevice(device).build()
                val role = if (s.initiator) RangingPreference.DEVICE_ROLE_INITIATOR else RangingPreference.DEVICE_ROLE_RESPONDER
                val preference = RangingPreference.Builder(role, config)
                    .setSessionConfig(SessionConfig.Builder().setAngleOfArrivalNeeded(s.angle).build())
                    .build()
                val rs = m.createRangingSession(executor, callback) ?: return false
                callback.owner = rs
                session = rs
                rs.start(preference)
                true
            } catch (e: RuntimeException) {
                // IllegalArgumentException for parameters the module rejects, SecurityException if the permission went.
                Log.w(TAG, "could not start UWB ranging", e)
                session?.let { runCatching { it.close() } }
                session = null
                false
            }
        }

        fun stop() {
            val rs = session ?: return
            session = null
            runCatching { rs.stop() }
            runCatching { rs.close() }
        }

        fun stoppedByPeer(reason: Int): Boolean = reason == RangingSession.Callback.REASON_REMOTE_REQUEST

        fun reasonText(reason: Int): String = when (reason) {
            RangingSession.Callback.REASON_LOCAL_REQUEST -> "stopped on this phone"
            RangingSession.Callback.REASON_REMOTE_REQUEST -> "stopped by the other phone"
            RangingSession.Callback.REASON_UNSUPPORTED -> "settings not supported"
            RangingSession.Callback.REASON_SYSTEM_POLICY -> "not allowed by Android now"
            RangingSession.Callback.REASON_NO_PEERS_FOUND -> "no reply"
            else -> "error $reason"
        }

        /** Forwards events for the session it belongs to, so a late callback from a stopped one is ignored. */
        private inner class SessionCallback : RangingSession.Callback {
            var owner: RangingSession? = null
            private val current: Boolean get() = owner != null && owner === session

            override fun onOpened() = Unit

            override fun onOpenFailed(reason: Int) {
                if (!current) return
                stop()
                listener.onUwbEvent(Event.OpenFailed(reason))
            }

            override fun onStarted(peer: RangingDevice, technology: Int) {
                if (current) listener.onUwbEvent(Event.Started)
            }

            override fun onResults(peer: RangingDevice, data: RangingData) {
                if (current) listener.onUwbEvent(Event.Result(measurement(data)))
            }

            override fun onStopped(peer: RangingDevice, reason: Int) {
                if (current) listener.onUwbEvent(Event.Stopped(reason))
            }

            override fun onClosed(reason: Int) {
                if (!current) return
                session = null
                runCatching { owner?.close() }
                listener.onUwbEvent(Event.Stopped(reason))
            }
        }

        private fun measurement(d: RangingData) = Measurement(
            distanceM = d.distance?.measurement,
            distanceConfidence = d.distance?.confidence ?: 0,
            azimuthDeg = d.azimuth?.measurement,
            azimuthConfidence = d.azimuth?.confidence ?: 0,
            elevationDeg = d.elevation?.measurement,
            elevationConfidence = d.elevation?.confidence ?: 0,
        )
    }

    companion object {
        private const val TAG = "UwbRadio"
        private const val PEER_UUID_HIGH = 0x5452_4d55_5742_0001L

        fun supported(context: Context): Boolean =
            Build.VERSION.SDK_INT >= 36 && context.packageManager.hasSystemFeature(PackageManager.FEATURE_UWB)

        @SuppressLint("InlinedApi") // Only read on Android 16 and later.
        fun hasPermission(context: Context): Boolean =
            Build.VERSION.SDK_INT >= 36 && context.checkSelfPermission(Manifest.permission.RANGING) == PackageManager.PERMISSION_GRANTED
    }
}
