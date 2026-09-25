package com.trailmind.app.location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import com.trailmind.app.Async
import com.trailmind.app.nav.NavigationController
import java.util.concurrent.CopyOnWriteArraySet

/** A GPS fix with the best available altitude above mean sea level. */
data class Fix(val location: Location, val altitudeMslM: Double?, val altitudeIsMsl: Boolean) {
    val lat get() = location.latitude
    val lon get() = location.longitude
    val accuracyM: Float get() = if (location.hasAccuracy()) location.accuracy else 50f
}

/** Fan-out of location fixes from the foreground listener and the tracking service. */
class LocationHub(private val nav: NavigationController) {
    @Volatile var latest: Fix? = null
        private set
    private val listeners = CopyOnWriteArraySet<(Fix) -> Unit>()

    fun addListener(l: (Fix) -> Unit) = listeners.add(l)
    fun removeListener(l: (Fix) -> Unit) = listeners.remove(l)

    fun publish(fix: Fix) {
        val prev = latest
        if (prev != null && prev.location.time == fix.location.time && prev.lat == fix.lat && prev.lon == fix.lon) return
        latest = fix
        Async.ui {
            nav.onFix(fix)
            listeners.forEach { it(fix) }
        }
    }

    companion object {
        fun hasPermission(ctx: Context) =
            ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
                ctx.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

        /**
         * Converts to MSL altitude. Android reports GPS altitude above the WGS84 ellipsoid (≈50 m
         * higher than sea level in the UK). API 34+ ships a geoid model (AltitudeConverter); this
         * does disk I/O so must run off the main thread.
         */
        fun toFix(ctx: Context, loc: Location): Fix {
            if (!loc.hasAltitude()) return Fix(loc, null, false)
            if (Build.VERSION.SDK_INT >= 34) {
                try {
                    if (!loc.hasMslAltitude()) android.location.altitude.AltitudeConverter().addMslAltitudeToLocation(ctx, loc)
                    if (loc.hasMslAltitude()) return Fix(loc, loc.mslAltitudeMeters, true)
                } catch (e: Exception) {
                    Log.w("LocationHub", "MSL conversion failed", e)
                }
            }
            return Fix(loc, loc.altitude, false)
        }
    }
}

/** Location updates while the UI is visible (no recording). Runs callbacks on a worker thread. */
class ForegroundLocation(private val context: Context, private val hub: LocationHub) : LocationListener {
    private var thread: HandlerThread? = null
    private val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    @SuppressLint("MissingPermission")
    fun start() {
        if (!LocationHub.hasPermission(context) || thread != null) return
        val t = HandlerThread("fg-location").apply { start() }
        thread = t
        try {
            for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                if (!lm.allProviders.contains(provider)) continue
                lm.getLastKnownLocation(provider)?.let { last ->
                    if (hub.latest == null && System.currentTimeMillis() - last.time < 10 * 60_000) {
                        t.threadHandler().post { hub.publish(LocationHub.toFix(context, last)) }
                    }
                }
            }
            if (lm.allProviders.contains(LocationManager.GPS_PROVIDER)) {
                lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1_000L, 0f, this, t.looper)
            }
            if (lm.allProviders.contains(LocationManager.NETWORK_PROVIDER)) {
                lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 10_000L, 0f, this, t.looper)
            }
        } catch (e: SecurityException) {
            Log.w("ForegroundLocation", "permission revoked", e)
        }
    }

    fun stop() {
        runCatching { lm.removeUpdates(this) }
        thread?.quitSafely()
        thread = null
    }

    fun isGpsEnabled(): Boolean = runCatching { lm.isProviderEnabled(LocationManager.GPS_PROVIDER) }.getOrDefault(false)

    override fun onLocationChanged(location: Location) {
        // Ignore coarse network fixes once we have a recent good GPS fix.
        val latest = hub.latest
        if (location.provider == LocationManager.NETWORK_PROVIDER && latest != null &&
            latest.location.provider == LocationManager.GPS_PROVIDER && location.time - latest.location.time < 30_000
        ) return
        hub.publish(LocationHub.toFix(context, location))
    }

    @Deprecated("Deprecated in Java")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
    override fun onProviderEnabled(provider: String) = Unit
    override fun onProviderDisabled(provider: String) = Unit
}

private fun HandlerThread.threadHandler() = android.os.Handler(looper ?: Looper.getMainLooper())
