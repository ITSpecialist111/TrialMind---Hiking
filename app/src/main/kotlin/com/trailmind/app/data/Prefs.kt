package com.trailmind.app.data

import android.content.Context
import com.trailmind.core.stats.PaceSettings

/** User settings. Stored in app-private SharedPreferences (app backup is disabled). */
class Prefs(context: Context) {
    private val sp = context.getSharedPreferences("trailmind", Context.MODE_PRIVATE)

    var onboardingAccepted: Boolean
        get() = sp.getBoolean("onboarding_v1", false)
        set(v) = sp.edit().putBoolean("onboarding_v1", v).apply()

    /** The user's own OS Data Hub API key. Never bundled with the app. */
    var osApiKey: String
        get() = sp.getString("os_api_key", "") ?: ""
        set(v) = sp.edit().putString("os_api_key", v.trim()).apply()

    var baseSourceId: String
        get() = sp.getString("base_source", "osm") ?: "osm"
        set(v) = sp.edit().putString("base_source", v).apply()

    var imperial: Boolean
        get() = sp.getBoolean("imperial", false)
        set(v) = sp.edit().putBoolean("imperial", v).apply()

    var offlineOnly: Boolean
        get() = sp.getBoolean("offline_only", false)
        set(v) = sp.edit().putBoolean("offline_only", v).apply()

    var flatSpeedKmh: Double
        get() = sp.getFloat("flat_speed", 4.5f).toDouble()
        set(v) = sp.edit().putFloat("flat_speed", v.toFloat()).apply()

    var conditionsFactor: Double
        get() = sp.getFloat("conditions", 1.0f).toDouble()
        set(v) = sp.edit().putFloat("conditions", v.toFloat()).apply()

    val pace: PaceSettings
        get() = runCatching { PaceSettings(flatSpeedKmh, conditionsFactor) }.getOrDefault(PaceSettings())

    var offRouteThresholdM: Int
        get() = sp.getInt("off_route_m", 60)
        set(v) = sp.edit().putInt("off_route_m", v).apply()

    var activeRouteId: Long
        get() = sp.getLong("active_route", -1)
        set(v) = sp.edit().putLong("active_route", v).apply()

    var mapLat: Double
        get() = java.lang.Double.longBitsToDouble(sp.getLong("map_lat", java.lang.Double.doubleToLongBits(54.46)))
        set(v) = sp.edit().putLong("map_lat", java.lang.Double.doubleToLongBits(v)).apply()
    var mapLon: Double
        get() = java.lang.Double.longBitsToDouble(sp.getLong("map_lon", java.lang.Double.doubleToLongBits(-3.09)))
        set(v) = sp.edit().putLong("map_lon", java.lang.Double.doubleToLongBits(v)).apply()
    var mapZoom: Double
        get() = sp.getFloat("map_zoom", 11f).toDouble()
        set(v) = sp.edit().putFloat("map_zoom", v.toFloat()).apply()

    var customName: String
        get() = sp.getString("custom_name", "") ?: ""
        set(v) = sp.edit().putString("custom_name", v.trim()).apply()
    var customTemplate: String
        get() = sp.getString("custom_template", "") ?: ""
        set(v) = sp.edit().putString("custom_template", v.trim()).apply()
    var customAttribution: String
        get() = sp.getString("custom_attr", "") ?: ""
        set(v) = sp.edit().putString("custom_attr", v.trim()).apply()
    var customMaxZoom: Int
        get() = sp.getInt("custom_maxz", 17)
        set(v) = sp.edit().putInt("custom_maxz", v).apply()
    /** The user confirms their provider's licence permits storing tiles offline. */
    var customOfflineAllowed: Boolean
        get() = sp.getBoolean("custom_offline", false)
        set(v) = sp.edit().putBoolean("custom_offline", v).apply()

    var emergencyContact: String
        get() = sp.getString("emergency_contact", "") ?: ""
        set(v) = sp.edit().putString("emergency_contact", v.trim()).apply()
}
