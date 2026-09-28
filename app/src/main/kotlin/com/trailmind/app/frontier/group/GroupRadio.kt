package com.trailmind.app.frontier.group

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import com.trailmind.core.frontier.group.GroupAdvert
import com.trailmind.core.frontier.group.RadioPlan
import com.trailmind.core.frontier.group.ScanDuty
import java.util.ArrayDeque
import java.util.UUID

/**
 * The trip-group radio: non-connectable extended advertising sets carrying the sealed group payload (LE Coded for
 * range, plus 1M for phones that can't receive Coded) and one filtered scan on every PHY. Every call and callback runs
 * on [handler]'s thread. What the phone supports is checked at run time, never assumed from its model.
 */
@SuppressLint("MissingPermission", "InlinedApi") // update() checks hasPermissions() before any Bluetooth call.
class GroupRadio(private val context: Context, private val handler: Handler, private val listener: Listener) {
    interface Listener {
        fun onAdvert(payload: ByteArray, rssi: Int, coded: Boolean, txPower: Int?)
        fun onRadioChanged()
    }

    data class Capabilities(
        val bluetooth: Boolean,
        val enabled: Boolean,
        val extended: Boolean,
        val coded: Boolean,
        val multipleAdvertisers: Boolean,
        val maxAdvertisingData: Int,
    ) {
        val maxFrames: Int get() = if (extended) GroupAdvert.maxFrames(maxAdvertisingData) else 0
    }

    /** One advertising set, as the diagnostics page shows it. */
    class AdvertState(val coded: Boolean) {
        @Volatile var running = false
        @Volatile var txPower: Int? = null
        @Volatile var error: String? = null
        internal var set: AdvertisingSet? = null
        internal var callback: AdvertisingSetCallback? = null
    }

    private val manager = context.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? get() = manager?.adapter
    private val uuid = ParcelUuid(UUID.fromString(GroupAdvert.SERVICE_UUID))

    @Volatile var adverts: List<AdvertState> = emptyList(); private set
    @Volatile var scanning = false; private set
    @Volatile var scanDuty: ScanDuty? = null; private set
    @Volatile var scanError: String? = null; private set
    @Volatile var scanStartedAt = 0L; private set
    @Volatile var received = 0L; private set
    @Volatile var receivedCoded = 0L; private set

    private var plan: RadioPlan? = null
    private var payload: ByteArray? = null
    private var longRange = true
    private val scanStarts = ArrayDeque<Long>()
    private var receiverRegistered = false
    private var advertFailures = 0
    private val retry = Runnable { update(plan, payload, longRange, force = true) }
    private val advertRetry = Runnable { retryFailedAdverts() }

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val state = i.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            handler.post {
                // The stack drops every advertising set and scan when Bluetooth goes off; start afresh when it's back.
                forgetRadio()
                if (state == BluetoothAdapter.STATE_ON) update(plan, payload, longRange, force = true)
                listener.onRadioChanged()
            }
        }
    }

    fun capabilities(): Capabilities {
        val a = adapter
        val on = a?.isEnabled == true
        return Capabilities(
            bluetooth = a != null,
            enabled = on,
            extended = on && a!!.isLeExtendedAdvertisingSupported,
            coded = on && a!!.isLeCodedPhySupported,
            multipleAdvertisers = on && a!!.isMultipleAdvertisementSupported,
            maxAdvertisingData = if (on) a!!.leMaximumAdvertisingDataLength else 0,
        )
    }

    /**
     * Runs [plan], advertising [payload] (null: listen only), or turns the radio off when [plan] is null. Only what
     * changed is redone, because Android limits how often an app may start a scan.
     */
    fun update(plan: RadioPlan?, payload: ByteArray?, longRange: Boolean, force: Boolean = false) {
        val old = this.plan
        val advertsChanged = force || plan?.advertiseInterval != old?.advertiseInterval || longRange != this.longRange ||
            (payload == null) != (this.payload == null)
        val dataChanged = !payload.contentEquals(this.payload)
        this.plan = plan
        this.payload = payload
        this.longRange = longRange
        handler.removeCallbacks(retry)
        if (plan == null) {
            stopAdverts()
            stopScan()
            unregister()
            return
        }
        register()
        if (!hasPermissions(context) || !capabilities().extended) {
            stopAdverts()
            stopScan()
            return
        }
        if (payload == null) stopAdverts()
        else if (advertsChanged || adverts.isEmpty()) {
            stopAdverts()
            startAdverts(plan, payload)
        } else if (dataChanged) setData(payload)
        val refresh = plan.scanRefreshMs?.let { SystemClock.elapsedRealtime() - scanStartedAt > it } == true
        if (!scanning || plan.scan != old?.scan || refresh) startScan(plan)
    }

    /** New advertising sets, so the Bluetooth address changes with the group's tag. */
    fun restartAdverts() {
        val plan = plan ?: return
        val data = payload ?: return
        if (!hasPermissions(context)) return
        stopAdverts()
        startAdverts(plan, data)
    }

    private fun startAdverts(plan: RadioPlan, data: ByteArray) {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        val caps = capabilities()
        handler.removeCallbacks(advertRetry)
        advertFailures = 0
        // 1M first: every phone can hear it, so if only one advertising slot is free it should get it.
        adverts = buildList {
            add(startSet(advertiser, plan, coded = false, data))
            if (longRange && caps.coded) add(startSet(advertiser, plan, coded = true, data))
        }
    }

    /** Starts again any set that failed (no free slot, an internal error), backing off from 30 s to 5 minutes. */
    private fun retryFailedAdverts() {
        val plan = plan ?: return
        val data = payload ?: return
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        if (!hasPermissions(context)) return
        adverts = adverts.map { s ->
            if (s.running || s.error == null) s
            else {
                s.callback?.let { cb -> runCatching { advertiser.stopAdvertisingSet(cb) } }
                startSet(advertiser, plan, s.coded, data)
            }
        }
    }

    private fun advertFailed() {
        handler.removeCallbacks(advertRetry)
        advertFailures++
        handler.postDelayed(advertRetry, minOf(RETRY_MS * advertFailures, MAX_ADVERT_RETRY_MS))
    }

    private fun startSet(advertiser: BluetoothLeAdvertiser, plan: RadioPlan, coded: Boolean, data: ByteArray): AdvertState {
        val state = AdvertState(coded)
        val phy = if (coded) BluetoothDevice.PHY_LE_CODED else BluetoothDevice.PHY_LE_1M
        val callback = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
                if (status == ADVERTISE_SUCCESS && set != null) {
                    state.set = set
                    state.running = true
                    state.txPower = txPower
                    state.error = null
                    if (adverts.all { it.running }) advertFailures = 0
                } else {
                    state.running = false
                    state.error = advertiseError(status)
                    Log.w(TAG, "advertising set (${if (coded) "coded" else "1M"}) failed: ${state.error}")
                    advertFailed()
                }
                listener.onRadioChanged()
            }

            override fun onAdvertisingSetStopped(set: AdvertisingSet?) {
                state.running = false
                state.set = null
            }

            override fun onAdvertisingDataSet(set: AdvertisingSet?, status: Int) {
                if (status != ADVERTISE_SUCCESS) state.error = "update refused: ${advertiseError(status)}"
            }
        }
        try {
            val params = AdvertisingSetParameters.Builder()
                .setLegacyMode(false)
                .setConnectable(false)
                .setScannable(false)
                .setPrimaryPhy(phy)
                .setSecondaryPhy(phy)
                .setInterval(plan.advertiseInterval)
                .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
                .setIncludeTxPower(true)
                .build()
            advertiser.startAdvertisingSet(params, data(data), null, null, null, callback, handler)
            state.callback = callback
        } catch (e: RuntimeException) {
            // IllegalArgumentException for a PHY the phone lacks or data too long; SecurityException if a permission went.
            state.error = e.message ?: e.javaClass.simpleName
            Log.w(TAG, "cannot start advertising set", e)
            advertFailed()
        }
        return state
    }

    private fun setData(data: ByteArray) {
        for (s in adverts) {
            val set = s.set ?: continue
            try {
                set.setAdvertisingData(data(data))
            } catch (e: RuntimeException) {
                s.error = e.message ?: e.javaClass.simpleName
            }
        }
    }

    private fun stopAdverts() {
        handler.removeCallbacks(advertRetry)
        val advertiser = adapter?.bluetoothLeAdvertiser
        for (s in adverts) {
            val cb = s.callback ?: continue
            runCatching { advertiser?.stopAdvertisingSet(cb) }
            s.running = false
        }
        adverts = emptyList()
    }

    private fun startScan(plan: RadioPlan) {
        val scanner = adapter?.bluetoothLeScanner ?: return
        if (scanning) stopScan()
        val now = SystemClock.elapsedRealtime()
        while (scanStarts.isNotEmpty() && now - scanStarts.first() > SCAN_QUOTA_WINDOW_MS) scanStarts.removeFirst()
        if (scanStarts.size >= MAX_SCAN_STARTS) {
            // Android ignores a sixth start inside 30 s without saying so; wait for the window instead.
            handler.postDelayed(retry, SCAN_QUOTA_WINDOW_MS - (now - scanStarts.first()) + 1_000)
            return
        }
        val mode = when (plan.scan) {
            ScanDuty.LOW_POWER -> ScanSettings.SCAN_MODE_LOW_POWER
            ScanDuty.BALANCED -> ScanSettings.SCAN_MODE_BALANCED
            ScanDuty.LOW_LATENCY -> ScanSettings.SCAN_MODE_LOW_LATENCY
        }
        val settings = ScanSettings.Builder()
            .setScanMode(mode)
            .setLegacy(false)
            .setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setReportDelay(0)
            .build()
        // Never an empty filter: Android pauses unfiltered scans with the screen off.
        val filter = ScanFilter.Builder()
            .setServiceData(uuid, byteArrayOf(GroupAdvert.VERSION.toByte()), byteArrayOf(0xFF.toByte()))
            .build()
        try {
            scanner.startScan(listOf(filter), settings, scanCallback)
            scanning = true
            scanDuty = plan.scan
            scanError = null
            scanStartedAt = now
            scanStarts.addLast(now)
        } catch (e: RuntimeException) {
            scanError = e.message ?: e.javaClass.simpleName
            handler.postDelayed(retry, RETRY_MS)
        }
    }

    private fun stopScan() {
        if (!scanning) return
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        scanning = false
        scanDuty = null
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = deliver(result)

        override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach(::deliver)

        override fun onScanFailed(errorCode: Int) {
            handler.post {
                scanning = false
                scanError = scanError(errorCode)
                Log.w(TAG, "scan failed: $scanError")
                handler.postDelayed(retry, RETRY_MS)
                listener.onRadioChanged()
            }
        }
    }

    private fun deliver(result: ScanResult) {
        val data = result.scanRecord?.getServiceData(uuid) ?: return
        val coded = result.primaryPhy == BluetoothDevice.PHY_LE_CODED
        val tx = result.txPower.takeIf { it != ScanResult.TX_POWER_NOT_PRESENT && it != 127 }
        val rssi = result.rssi
        handler.post {
            received++
            if (coded) receivedCoded++
            listener.onAdvert(data, rssi, coded, tx)
        }
    }

    private fun forgetRadio() {
        adverts.forEach { it.running = false }
        adverts = emptyList()
        scanning = false
        scanDuty = null
    }

    private fun register() {
        if (receiverRegistered) return
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(stateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else context.registerReceiver(stateReceiver, filter)
        receiverRegistered = true
    }

    private fun unregister() {
        if (!receiverRegistered) return
        runCatching { context.unregisterReceiver(stateReceiver) }
        receiverRegistered = false
    }

    private fun data(payload: ByteArray): AdvertiseData = AdvertiseData.Builder()
        .addServiceData(uuid, payload)
        .setIncludeDeviceName(false)
        .setIncludeTxPowerLevel(false)
        .build()

    companion object {
        private const val TAG = "GroupRadio"
        private const val SCAN_QUOTA_WINDOW_MS = 30_000L
        private const val MAX_SCAN_STARTS = 4
        private const val RETRY_MS = 30_000L
        private const val MAX_ADVERT_RETRY_MS = 5 * 60_000L

        /** "Nearby devices", plus precise location because scan results carry the group's positions (no neverForLocation). */
        fun permissions(): Array<String> = arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT,
        )

        fun supported(): Boolean = Build.VERSION.SDK_INT >= 31

        fun hasPermissions(context: Context): Boolean = supported() &&
            (permissions() + Manifest.permission.ACCESS_FINE_LOCATION).all {
                context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
            }

        private fun advertiseError(status: Int) = when (status) {
            AdvertisingSetCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "data too large"
            AdvertisingSetCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "no free advertising slot"
            AdvertisingSetCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "already started"
            AdvertisingSetCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "internal error"
            AdvertisingSetCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "not supported by this phone"
            else -> "error $status"
        }

        private fun scanError(code: Int) = when (code) {
            ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "already started"
            ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "could not register"
            ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "internal error"
            ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "not supported by this phone"
            ScanCallback.SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES -> "out of hardware resources"
            ScanCallback.SCAN_FAILED_SCANNING_TOO_FREQUENTLY -> "started too often"
            else -> "error $code"
        }
    }
}
