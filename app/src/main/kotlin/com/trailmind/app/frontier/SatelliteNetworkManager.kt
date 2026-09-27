package com.trailmind.app.frontier

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URL

enum class DirectToCellService {
    SMS,
    RCS,
    WHATSAPP_MESSAGING,
    FACEBOOK_MESSENGER,
    WHATSAPP_AUDIO,
    ALLOWLISTED_LIGHT_APP_DATA,
    BACKGROUND_LOCATION_SYNC,
}

data class SatelliteLinkState(
    val network: Network?,
    val constrainedCellularAvailable: Boolean,
    val availableServices: Set<DirectToCellService> = emptySet(),
)

/**
 * Observes bandwidth-constrained cellular networks exposed by Android. Android's public API does
 * not identify an O2/Starlink bearer explicitly, so callers must treat this as an NTN candidate.
 */
class SatelliteNetworkManager(
    private val connectivityManager: ConnectivityManager,
    private val onStateChanged: (SatelliteLinkState) -> Unit,
) {
    @Volatile private var registered = false
    @Volatile private var candidate: Network? = null
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = update(network)

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            if (isConstrainedCellular(capabilities)) update(network) else if (candidate == network) clear(network)
        }

        override fun onLost(network: Network) = clear(network)
    }

    fun start() {
        if (registered) return
        if (Build.VERSION.SDK_INT < 36) {
            onStateChanged(SatelliteLinkState(null, false))
            return
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED)
            .build()
        try {
            connectivityManager.registerNetworkCallback(request, callback)
            registered = true
        } catch (e: RuntimeException) {
            Log.w(TAG, "unable to observe constrained cellular networks", e)
            onStateChanged(SatelliteLinkState(null, false))
        }
    }

    fun stop() {
        if (!registered) return
        try {
            connectivityManager.unregisterNetworkCallback(callback)
        } catch (e: RuntimeException) {
            Log.w(TAG, "unable to unregister network callback", e)
        } finally {
            registered = false
            candidate = null
            onStateChanged(SatelliteLinkState(null, false))
        }
    }

    fun sendUdp(host: String, port: Int, payload: ByteArray) {
        require(host.isNotBlank()) { "host is required" }
        require(port in 1..65535) { "port out of range" }
        check(Thread.currentThread() !== android.os.Looper.getMainLooper().thread) {
            "satellite UDP must be sent off the main thread"
        }
        val network = candidate ?: error("no constrained cellular network is available")
        DatagramSocket().use { socket ->
            network.bindSocket(socket)
            val address = network.getAllByName(host).firstOrNull()
                ?: error("unable to resolve $host on constrained cellular network")
            socket.send(DatagramPacket(payload, payload.size, InetSocketAddress(address, port)))
        }
    }

    /**
     * Opens an HTTP connection explicitly bound to the constrained cellular bearer. The carrier
     * still decides whether this application and destination are allowlisted for light app data.
     */
    fun openDataConnection(url: URL): HttpURLConnection {
        check(Thread.currentThread() !== android.os.Looper.getMainLooper().thread) {
            "satellite data connections must be opened off the main thread"
        }
        val network = candidate ?: error("no constrained cellular network is available")
        return network.openConnection(url) as? HttpURLConnection
            ?: error("$url is not an HTTP endpoint")
    }

    private fun update(network: Network) {
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return
        if (!isConstrainedCellular(capabilities)) return
        candidate = network
        onStateChanged(SatelliteLinkState(network, true, O2_DIRECT_TO_CELL_SERVICES))
    }

    private fun clear(network: Network) {
        if (candidate != network) return
        candidate = null
        onStateChanged(SatelliteLinkState(null, false))
    }

    private fun isConstrainedCellular(capabilities: NetworkCapabilities): Boolean =
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
            if (Build.VERSION.SDK_INT >= 36) {
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED)
            } else {
                false
            }

    companion object {
        private const val TAG = "SatelliteNetwork"

        /**
         * Services carried by the target O2 Direct-to-Cell profile. SMS/RCS and third-party
         * messaging or calling remain owned by their respective system/application clients.
         */
        val O2_DIRECT_TO_CELL_SERVICES: Set<DirectToCellService> = DirectToCellService.entries.toSet()
    }
}
