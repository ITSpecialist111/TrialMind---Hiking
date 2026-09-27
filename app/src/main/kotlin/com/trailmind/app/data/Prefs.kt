package com.trailmind.app.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import com.trailmind.core.stats.PaceSettings
import com.trailmind.core.frontier.FallVector

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

    var recentSearches: List<String>
        get() = runCatching {
            val list = JSONArray(sp.getString("recent_searches", "[]"))
            (0 until list.length()).map { list.getString(it) }
        }.getOrDefault(emptyList())
        set(value) = sp.edit().putString("recent_searches", JSONArray(value.take(5)).toString()).apply()

    /** The OS key's project can load Premium zooms, as last seen by Save & test or the map. */
    var osPremium: Boolean
        get() = sp.getBoolean("os_premium", false)
        set(v) = sp.edit().putBoolean("os_premium", v).apply()

    var baseSourceId: String
        get() = sp.getString("base_source", "osm") ?: "osm"
        set(v) = sp.edit().putString("base_source", v).apply()

    /** Wide layout: the map fills the window, with the navigation rail and side pane hidden. */
    var mapFullScreen: Boolean
        get() = sp.getBoolean("map_full_screen", false)
        set(v) = sp.edit().putBoolean("map_full_screen", v).apply()

    var imperial: Boolean
        get() = sp.getBoolean("imperial", false)
        set(v) = sp.edit().putBoolean("imperial", v).apply()

    var offlineOnly: Boolean
        get() = sp.getBoolean("offline_only", false)
        set(v) = sp.edit().putBoolean("offline_only", v).apply()

    /** Tint and outline the map where the base map is on the phone. */
    var showOfflineAreas: Boolean
        get() = sp.getBoolean("show_offline_areas", true)
        set(v) = sp.edit().putBoolean("show_offline_areas", v).apply()

    var showSteepGround: Boolean
        get() = sp.getBoolean("show_steep_ground", false)
        set(v) = sp.edit().putBoolean("show_steep_ground", v).apply()

    var showFacilities: Boolean
        get() = sp.getBoolean("show_facilities", true)
        set(v) = sp.edit().putBoolean("show_facilities", v).apply()

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

    var daylightMarginMinutes: Int
        get() = sp.getInt("daylight_margin_min", 30).takeIf { it == 0 || it == 30 || it == 60 } ?: 30
        set(v) { require(v == 0 || v == 30 || v == 60); sp.edit().putInt("daylight_margin_min", v).apply() }

    var daylightAlertState: String
        get() = sp.getString("daylight_alert_state", "") ?: ""
        set(v) = sp.edit().putString("daylight_alert_state", v).apply()

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

    var emergencyContactName: String
        get() = sp.getString("emergency_contact_name", "") ?: ""
        set(v) = sp.edit().putString("emergency_contact_name", v.trim()).apply()

    var checkInDueMs: Long
        get() = sp.getLong("check_in_due", 0L)
        set(v) = sp.edit().putLong("check_in_due", v).apply()

    var checkInRoute: String
        get() = sp.getString("check_in_route", "") ?: ""
        set(v) = sp.edit().putString("check_in_route", v).apply()

    var checkInRouteId: Long
        get() = sp.getLong("check_in_route_id", 0L)
        set(v) = sp.edit().putLong("check_in_route_id", v).apply()

    var checkInStage: Int
        get() = sp.getInt("check_in_stage", 0)
        set(v) = sp.edit().putInt("check_in_stage", v).apply()

    var watchEnabled: Boolean
        get() = sp.getBoolean("watch_enabled", false)
        set(v) = sp.edit().putBoolean("watch_enabled", v).apply()

    /** Pack id to the 24-hour detail expiry the user has already been asked to renew. */
    var renewAsked: Map<Long, Long>
        get() = runCatching {
            val json = JSONObject(sp.getString("renew_asked", "{}") ?: "{}")
            json.keys().asSequence().associate { it.toLong() to json.getLong(it) }
        }.getOrDefault(emptyMap())
        set(v) = sp.edit().putString("renew_asked", JSONObject(v.mapKeys { it.key.toString() }).toString()).apply()

    /** Bluetooth address of the watch the user picked; connections from any other device are refused. */
    var watchAddress: String
        get() = sp.getString("watch_address", "") ?: ""
        set(v) = sp.edit().putString("watch_address", v).apply()

    var frontierDeviceId: String
        get() = sp.getString("frontier_device_id", "") ?: ""
        set(v) = sp.edit().putString("frontier_device_id", v).apply()

    var frontierSequence: Long
        get() = sp.getLong("frontier_sequence", 0L)
        set(v) = sp.edit().putLong("frontier_sequence", v).apply()

    var frontierEnabled: Boolean
        get() = sp.getBoolean("frontier_enabled", true)
        set(v) = sp.edit().putBoolean("frontier_enabled", v).apply()

    var frontierHeartbeatsEnabled: Boolean
        get() = sp.getBoolean("frontier_heartbeats_enabled", true)
        set(v) = sp.edit().putBoolean("frontier_heartbeats_enabled", v).apply()

    var frontierFallDetectionEnabled: Boolean
        get() = sp.getBoolean("frontier_fall_detection_enabled", true)
        set(v) = sp.edit().putBoolean("frontier_fall_detection_enabled", v).apply()

    var frontierSatelliteDataEnabled: Boolean
        get() = sp.getBoolean("frontier_satellite_data_enabled", true)
        set(v) = sp.edit().putBoolean("frontier_satellite_data_enabled", v).apply()

    var frontierEmergencyStatus: Int
        get() = sp.getInt("frontier_emergency_status", 0)
        set(v) = sp.edit().putInt("frontier_emergency_status", v).apply()

    var frontierFallVector: FallVector?
        get() = if (sp.contains("frontier_fall_impact")) {
            FallVector(
                impactGForce = sp.getFloat("frontier_fall_impact", 0f),
                freefallDurationSeconds = sp.getFloat("frontier_fall_duration", 0f),
                deltaAltitudeMeters = sp.getFloat("frontier_fall_altitude", 0f),
            )
        } else {
            null
        }
        set(v) {
            sp.edit().apply {
                if (v == null) {
                    remove("frontier_fall_impact")
                    remove("frontier_fall_duration")
                    remove("frontier_fall_altitude")
                } else {
                    putFloat("frontier_fall_impact", v.impactGForce)
                    putFloat("frontier_fall_duration", v.freefallDurationSeconds)
                    putFloat("frontier_fall_altitude", v.deltaAltitudeMeters)
                }
            }.apply()
        }
}
