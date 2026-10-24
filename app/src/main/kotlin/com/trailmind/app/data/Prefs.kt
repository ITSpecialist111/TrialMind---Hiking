package com.trailmind.app.data

import android.content.Context
import android.util.Base64
import com.trailmind.app.frontier.group.GroupKeyStore
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
        get() = (sp.getString("base_source", "osm") ?: "osm").let { if (com.trailmind.app.map.TileSources.isRetired(it)) "osm" else it }
        set(v) = sp.edit().putString("base_source", v).apply()

    /** Wide layout: the map fills the window, with the navigation rail and side pane hidden. */
    var mapFullScreen: Boolean
        get() = sp.getBoolean("map_full_screen", false)
        set(v) = sp.edit().putBoolean("map_full_screen", v).apply()

    var menuOpacityPercent: Int
        get() = sp.getInt("menu_opacity", 92).coerceIn(70, 100)
        set(v) { require(v in 70..100); sp.edit().putInt("menu_opacity", v).apply() }

    var what3wordsKey: String
        get() = sp.getString("what3words_key", "") ?: ""
        set(v) = sp.edit().putString("what3words_key", v.trim()).apply()

    /** The map turns so the way you face is at the top, instead of north. */
    var mapHeadingUp: Boolean
        get() = sp.getBoolean("map_heading_up", false)
        set(v) = sp.edit().putBoolean("map_heading_up", v).apply()

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

    /** Hill shading and crags from 1 m LiDAR (England) on the map. */
    var showLidar: Boolean
        get() = sp.getBoolean("show_lidar", false)
        set(v) = sp.edit().putBoolean("show_lidar", v).apply()

    /** Route offline maps also save 1 m LiDAR near the route (England). */
    var packLidar: Boolean
        get() = sp.getBoolean("pack_lidar", true)
        set(v) = sp.edit().putBoolean("pack_lidar", v).apply()

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

    /** Pass on other trip-group members' positions, so the group reaches further than one phone's range. */
    var groupRelayEnabled: Boolean
        get() = sp.getBoolean("group_relay", true)
        set(v) = sp.edit().putBoolean("group_relay", v).apply()

    var groupShowOnMap: Boolean
        get() = sp.getBoolean("group_show_on_map", true)
        set(v) = sp.edit().putBoolean("group_show_on_map", v).apply()

    /** Also advertise on LE Coded (long range) when the phone supports it. */
    var groupLongRange: Boolean
        get() = sp.getBoolean("group_long_range", true)
        set(v) = sp.edit().putBoolean("group_long_range", v).apply()

    var groupHelpAlerts: Boolean
        get() = sp.getBoolean("group_help_alerts", true)
        set(v) = sp.edit().putBoolean("group_help_alerts", v).apply()

    /** Answer when someone in the trip group asks to find this phone up close with UWB. */
    var groupUwbFindable: Boolean
        get() = sp.getBoolean("group_uwb_findable", true)
        set(v) = sp.edit().putBoolean("group_uwb_findable", v).apply()

    /** The user accepted the explanation of what trip groups share, shown before Android's Nearby devices prompt. */
    var groupDisclosureAccepted: Boolean
        get() = sp.getBoolean("group_disclosure_v1", false)
        set(v) = sp.edit().putBoolean("group_disclosure_v1", v).apply()

    /** The name last used in a trip group, offered again for the next one. */
    var groupDisplayName: String
        get() = sp.getString("group_display_name", "") ?: ""
        set(v) = sp.edit().putString("group_display_name", v.trim()).apply()

    /** Sequence number of this phone's latest position frame, so members can order them across restarts. */
    var groupSequence: Long
        get() = sp.getLong("group_sequence", 0L)
        set(v) = sp.edit().putLong("group_sequence", v).apply()

    /**
     * Hikes are logged for the whole trip group: starting one invites the others to record theirs, and
     * another member's group hike is joined on this phone too.
     */
    var groupHikes: Boolean
        get() = sp.getBoolean("group_hikes", true)
        set(v) = sp.edit().putBoolean("group_hikes", v).apply()

    /** Ask before recording because a member started a group hike, instead of starting straight away. */
    var groupHikesAsk: Boolean
        get() = sp.getBoolean("group_hikes_ask", false)
        set(v) = sp.edit().putBoolean("group_hikes_ask", v).apply()

    /** Pause the hike when the phone is moving at vehicle speed for half a minute. */
    var autoPauseInVehicle: Boolean
        get() = sp.getBoolean("auto_pause_vehicle", true)
        set(v) = sp.edit().putBoolean("auto_pause_vehicle", v).apply()

    /** The user's own MapTiler Cloud key, which serves the National Library of Scotland's old maps. Never bundled. */
    var mapTilerKey: String
        get() = sp.getString("maptiler_key", "") ?: ""
        set(v) = sp.edit().putString("maptiler_key", v.trim()).apply()

    /** An old map drawn over the base map (a [com.trailmind.app.map.TileSource] id), or empty for none. */
    var historicOverlayId: String
        get() = sp.getString("historic_overlay", "") ?: ""
        set(v) = sp.edit().putString("historic_overlay", v).apply()

    /** How much of the old map shows through over the base map, 10–100 %. */
    var historicOverlayPercent: Int
        get() = sp.getInt("historic_overlay_percent", 55).coerceIn(10, 100)
        set(v) = sp.edit().putInt("historic_overlay_percent", v.coerceIn(10, 100)).apply()

    // ---------------------------------------------------------------- Strava

    /** The Client ID of the user's own Strava API application (not a secret). */
    var stravaClientId: String
        get() = sp.getString("strava_client_id", "") ?: ""
        set(v) = sp.edit().putString("strava_client_id", v.trim()).apply()

    /** The application's secret, the access token and the refresh token: encrypted with a key that stays in Android's keystore. */
    var stravaClientSecret: String
        get() = secret("strava_client_secret")
        set(v) = putSecret("strava_client_secret", v.trim())

    var stravaAccessToken: String
        get() = secret("strava_access_token")
        set(v) = putSecret("strava_access_token", v)

    var stravaRefreshToken: String
        get() = secret("strava_refresh_token")
        set(v) = putSecret("strava_refresh_token", v)

    /** When the access token lapses, seconds since 1970. */
    var stravaExpiresAtS: Long
        get() = sp.getLong("strava_expires_at", 0L)
        set(v) = sp.edit().putLong("strava_expires_at", v).apply()

    var stravaScope: String
        get() = sp.getString("strava_scope", "") ?: ""
        set(v) = sp.edit().putString("strava_scope", v).apply()

    /** Who is linked, for "Linked as …". */
    var stravaAthleteId: Long
        get() = sp.getLong("strava_athlete_id", 0L)
        set(v) = sp.edit().putLong("strava_athlete_id", v).apply()

    var stravaAthleteUsername: String
        get() = sp.getString("strava_athlete_username", "") ?: ""
        set(v) = sp.edit().putString("strava_athlete_username", v).apply()

    var stravaAthleteFirstName: String
        get() = sp.getString("strava_athlete_first", "") ?: ""
        set(v) = sp.edit().putString("strava_athlete_first", v).apply()

    var stravaAthleteLastName: String
        get() = sp.getString("strava_athlete_last", "") ?: ""
        set(v) = sp.edit().putString("strava_athlete_last", v).apply()

    /** Strava refused the saved link (revoked, or uploading wasn't allowed): the user has to connect again. */
    var stravaNeedsReconnect: Boolean
        get() = sp.getBoolean("strava_needs_reconnect", false)
        set(v) = sp.edit().putBoolean("strava_needs_reconnect", v).apply()

    /** The random value sent with the sign-in, which Strava must send back. Cleared once used. */
    var stravaPendingState: String
        get() = sp.getString("strava_pending_state", "") ?: ""
        set(v) = sp.edit().putString("strava_pending_state", v).apply()

    /** Post each finished hike to Strava without asking. */
    var stravaAuto: Boolean
        get() = sp.getBoolean("strava_auto", true)
        set(v) = sp.edit().putBoolean("strava_auto", v).apply()

    /** What hikes are posted as: a [com.trailmind.core.strava.StravaActivityKind] code. */
    var stravaKind: String
        get() = sp.getString("strava_kind", "hike") ?: "hike"
        set(v) = sp.edit().putString("strava_kind", v).apply()

    private fun secret(key: String): String {
        val encoded = sp.getString(key, null) ?: return ""
        val bytes = runCatching { Base64.decode(encoded, Base64.NO_WRAP) }.getOrNull() ?: return ""
        // Null once the keystore has lost its key (a restore to a new phone): the user connects again.
        return GroupKeyStore.unwrap(bytes)?.toString(Charsets.UTF_8) ?: ""
    }

    private fun putSecret(key: String, value: String) {
        if (value.isEmpty()) sp.edit().remove(key).apply()
        else sp.edit().putString(key, Base64.encodeToString(GroupKeyStore.wrap(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)).apply()
    }

    // Reading or writing a secret goes through Android's keystore, which can take seconds the first time (it makes the key),
    // so screens ask these plain questions instead and leave the secrets to background threads.
    val hasStravaSecret: Boolean get() = sp.contains("strava_client_secret")
    val hasStravaRefreshToken: Boolean get() = sp.contains("strava_refresh_token")

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

    /** The running fall alarm or SOS: when it started (0 = none), its stage, what the text says, and how sending went. */
    var fallAlertMs: Long
        get() = sp.getLong("fall_alert_ms", 0L)
        set(v) = sp.edit().putLong("fall_alert_ms", v).apply()

    var fallStage: Int
        get() = sp.getInt("fall_stage", 0)
        set(v) = sp.edit().putInt("fall_stage", v).apply()

    var sosSituation: String
        get() = sp.getString("sos_situation", "") ?: ""
        set(v) = sp.edit().putString("sos_situation", v).apply()

    var sosAttempts: Int
        get() = sp.getInt("sos_attempts", 0)
        set(v) = sp.edit().putInt("sos_attempts", v).apply()

    var sosFailed: Boolean
        get() = sp.getBoolean("sos_failed", false)
        set(v) = sp.edit().putBoolean("sos_failed", v).apply()

    var sosSentMs: Long
        get() = sp.getLong("sos_sent_ms", 0L)
        set(v) = sp.edit().putLong("sos_sent_ms", v).apply()

    /** The number the current SOS text is being sent to. */
    var sosRecipient: String
        get() = sp.getString("sos_recipient", "") ?: ""
        set(v) = sp.edit().putString("sos_recipient", v).apply()

    /** "number|time written in the text" for each number the current SOS text is confirmed sent to. */
    var sosSentTo: Set<String>
        get() = sp.getStringSet("sos_sent_to", emptySet()).orEmpty().toSet()
        set(v) = sp.edit().putStringSet("sos_sent_to", v).apply()

    /** Ids of alerts ended with "I'm OK" whose SOS texts may still report late; each late success gets an all-clear. */
    var sosAllClearPending: Set<String>
        get() = sp.getStringSet("sos_all_clear_pending", emptySet()).orEmpty().toSet()
        set(v) = sp.edit().putStringSet("sos_all_clear_pending", v).apply()

    /** The user lets TrailMind send the SOS text itself when they don't answer the fall alarm. Off until they choose it. */
    var sosAutoSend: Boolean
        get() = sp.getBoolean("sos_auto_send", false)
        set(v) = sp.edit().putBoolean("sos_auto_send", v).apply()

    /** The user says this phone is registered for UK emergencySMS, so texting 999 works. */
    var emergencySmsRegistered: Boolean
        get() = sp.getBoolean("emergency_sms_registered", false)
        set(v) = sp.edit().putBoolean("emergency_sms_registered", v).apply()
}
