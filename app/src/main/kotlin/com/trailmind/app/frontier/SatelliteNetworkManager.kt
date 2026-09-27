package com.trailmind.app.frontier

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.telephony.ServiceState
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URL
import java.util.concurrent.ConcurrentHashMap

/**
 * [network] is a satellite data link TrailMind may use; [textsOverSatellite] means the phone is registered on a
 * non-terrestrial network such as O2 Satellite, where texts work even without any data.
 */
data class SatelliteLinkState(
    val network: Network? = null,
    val textsOverSatellite: Boolean = false,
    val operatorName: String? = null,
) {
    val dataAvailable get() = network != null
    val connected get() = dataAvailable || textsOverSatellite
}

/**
 * Watches for satellite links the way Android documents them: data networks with the satellite transport or
 * without NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED, and the phone's registration on a non-terrestrial network.
 */
class SatelliteNetworkManager(
    private val context: Context,
    private val onStateChanged: (SatelliteLinkState) -> Unit,
) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val telephony: TelephonyManager? = context.getSystemService(TelephonyManager::class.java)
    private val satelliteNetworks: MutableSet<Network> = ConcurrentHashMap.newKeySet()
    @Volatile private var registered = false
    @Volatile private var onNtn = false
    @Volatile private var operator: String? = null
    private var telephonyCallback: Any? = null
    private var last = SatelliteLinkState()

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            if (isSatellite(capabilities)) satelliteNetworks.add(network) else satelliteNetworks.remove(network)
            publish()
        }

        override fun onLost(network: Network) {
            satelliteNetworks.remove(network)
            publish()
        }
    }

    fun start() {
        if (registered) return
        registered = true
        val request = NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).apply {
            if (Build.VERSION.SDK_INT >= 36) removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED)
        }.build()
        try {
            connectivity.registerNetworkCallback(request, networkCallback)
        } catch (e: RuntimeException) {
            Log.w(TAG, "unable to observe satellite data networks", e)
        }
        listenForNonTerrestrialService()
        publish()
    }

    fun stop() {
        if (!registered) return
        registered = false
        runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
        if (Build.VERSION.SDK_INT >= 31) (telephonyCallback as? TelephonyCallback)?.let { runCatching { telephony?.unregisterTelephonyCallback(it) } }
        telephonyCallback = null
        satelliteNetworks.clear()
        onNtn = false
        operator = null
        publish()
    }

    private fun listenForNonTerrestrialService() {
        if (Build.VERSION.SDK_INT < 31) return
        val tm = telephony ?: return
        val callback = object : TelephonyCallback(), TelephonyCallback.ServiceStateListener {
            override fun onServiceStateChanged(serviceState: ServiceState) {
                // Without location permission Android withholds the network name; the NTN flag still works.
                val name = try { serviceState.operatorAlphaLong } catch (e: SecurityException) { null }
                // O2 shows the network name "O2 Satellite"; the NTN flag is the platform's own signal.
                onNtn = (Build.VERSION.SDK_INT >= 35 && serviceState.isUsingNonTerrestrialNetwork) ||
                    name?.contains("satellite", ignoreCase = true) == true
                operator = name
                publish()
            }
        }
        try {
            tm.registerTelephonyCallback(context.mainExecutor, callback)
            telephonyCallback = callback
        } catch (e: RuntimeException) {
            Log.w(TAG, "unable to observe satellite service state", e)
        }
    }

    fun sendUdp(host: String, port: Int, payload: ByteArray) {
        require(host.isNotBlank()) { "host is required" }
        require(port in 1..65535) { "port out of range" }
        check(Thread.currentThread() !== android.os.Looper.getMainLooper().thread) {
            "satellite UDP must be sent off the main thread"
        }
        val network = satelliteNetworks.firstOrNull() ?: error("no satellite data network is available")
        DatagramSocket().use { socket ->
            network.bindSocket(socket)
            val address = network.getAllByName(host).firstOrNull()
                ?: error("unable to resolve $host on the satellite network")
            socket.send(DatagramPacket(payload, payload.size, InetSocketAddress(address, port)))
        }
    }

    /** Opens an HTTP connection bound to the satellite network; the carrier still decides which apps it carries. */
    fun openDataConnection(url: URL): HttpURLConnection {
        check(Thread.currentThread() !== android.os.Looper.getMainLooper().thread) {
            "satellite data connections must be opened off the main thread"
        }
        val network = satelliteNetworks.firstOrNull() ?: error("no satellite data network is available")
        return network.openConnection(url) as? HttpURLConnection
            ?: error("$url is not an HTTP endpoint")
    }

    @Synchronized private fun publish() {
        val state = SatelliteLinkState(satelliteNetworks.firstOrNull(), onNtn, operator?.takeIf { onNtn })
        if (state == last) return
        last = state
        onStateChanged(state)
    }

    companion object {
        private const val TAG = "SatelliteNetwork"

        fun isSatellite(capabilities: NetworkCapabilities): Boolean =
            (Build.VERSION.SDK_INT >= 35 && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_SATELLITE)) ||
                (Build.VERSION.SDK_INT >= 36 && !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED))

        /** True when the phone's current internet route is a satellite link, where TrailMind keeps to small requests. */
        fun onSatellite(context: Context): Boolean {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
            val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
            return isSatellite(caps)
        }
    }
}
