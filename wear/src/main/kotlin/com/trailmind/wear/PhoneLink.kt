package com.trailmind.wear

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.trailmind.core.watch.WatchProtocol
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Bluetooth RFCOMM client to TrailMind on the paired phone. Keeps retrying while started; frames are
 * delivered on the link thread so the caller can decode tiles off the main thread.
 */
class PhoneLink(private val ctx: Context, private val listener: Listener) {
    enum class Status { NO_BLUETOOTH, NO_PERMISSION, BLUETOOTH_OFF, CONNECTING, NO_PHONE, CONNECTED }

    interface Listener {
        fun onLinkStatus(status: Status)
        fun onFrame(frame: WatchProtocol.Frame)
    }

    @Volatile private var generation = 0
    @Volatile private var socket: BluetoothSocket? = null
    @Volatile private var out: DataOutputStream? = null
    private var thread: Thread? = null
    private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "phone-write").apply { isDaemon = true } }
    private val prefs = ctx.getSharedPreferences("link", Context.MODE_PRIVATE)

    fun hasPermission() = hasPermission(ctx)

    fun start() {
        if (thread != null) return
        val g = ++generation
        thread = Thread({ loop(g) }, "phone-link").apply { isDaemon = true; start() }
    }

    fun stop() {
        generation++
        runCatching { socket?.close() }
        thread?.interrupt()
        thread = null
    }

    fun send(type: Int, payload: ByteArray) {
        val o = out ?: return
        try {
            writer.execute {
                try { WatchProtocol.writeFrame(o, type, payload) } catch (_: IOException) { runCatching { socket?.close() } }
            }
        } catch (_: RejectedExecutionException) { }
    }

    private fun loop(g: Int) {
        var failures = 0
        while (g == generation) {
            val adapter = ctx.getSystemService(BluetoothManager::class.java)?.adapter
            val blocked = when {
                adapter == null -> Status.NO_BLUETOOTH
                !hasPermission() -> Status.NO_PERMISSION
                !adapter.isEnabled -> Status.BLUETOOTH_OFF
                else -> null
            }
            if (blocked != null) { listener.onLinkStatus(blocked); pause(3_000); continue }
            listener.onLinkStatus(Status.CONNECTING)
            val connected = candidates(adapter!!).any { g == generation && session(it, g) }
            if (g != generation) break
            failures = if (connected) 0 else failures + 1
            if (!connected) listener.onLinkStatus(Status.NO_PHONE)
            pause(if (connected) 1_000 else minOf(15_000L, 3_000L * failures))
        }
    }

    /** Phones first, the last phone that answered first of all. */
    @SuppressLint("MissingPermission")
    private fun candidates(adapter: BluetoothAdapter): List<BluetoothDevice> {
        val bonded = runCatching { adapter.bondedDevices.toList() }.getOrDefault(emptyList())
        val phones = bonded.filter { it.bluetoothClass?.majorDeviceClass == BluetoothClass.Device.Major.PHONE }
        val last = prefs.getString("phone", null)
        return phones.ifEmpty { bonded }.sortedByDescending { it.address == last }
    }

    /** Returns true if a session was established (even if it later dropped). */
    @SuppressLint("MissingPermission")
    private fun session(device: BluetoothDevice, g: Int): Boolean {
        val s = try {
            device.createRfcommSocketToServiceRecord(UUID.fromString(WatchProtocol.SERVICE_UUID)).also { socket = it; it.connect() }
        } catch (e: IOException) {
            Log.i(TAG, "no TrailMind on ${device.address}: ${e.message}")
            runCatching { socket?.close() }
            socket = null
            return false
        }
        prefs.edit().putString("phone", device.address).apply()
        try {
            out = DataOutputStream(BufferedOutputStream(s.outputStream, 8 * 1024))
            listener.onLinkStatus(Status.CONNECTED)
            send(WatchProtocol.HELLO, WatchProtocol.hello("TrailMind watch"))
            val input = DataInputStream(BufferedInputStream(s.inputStream, 32 * 1024))
            while (g == generation) listener.onFrame(WatchProtocol.readFrame(input))
        } catch (e: IOException) {
            Log.i(TAG, "phone link closed: ${e.message}")
        } finally {
            out = null
            runCatching { s.close() }
            socket = null
        }
        return true
    }

    private fun pause(ms: Long) {
        try { Thread.sleep(ms) } catch (_: InterruptedException) { }
    }

    companion object {
        private const val TAG = "PhoneLink"

        fun hasPermission(ctx: Context) = Build.VERSION.SDK_INT < 31 ||
            ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    }
}
