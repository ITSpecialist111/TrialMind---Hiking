import Foundation

/// User settings, with the Android app's keys and defaults (data/Prefs.kt). Plain values live in UserDefaults; keys,
/// secrets and tokens live in the Keychain. Every property publishes, so SwiftUI pages refresh when a setting changes.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d: UserDefaults

    init(defaults: UserDefaults = .standard) {
        d = defaults
        let ud = defaults
        func b(_ k: String, _ def: Bool) -> Bool { ud.object(forKey: k) == nil ? def : ud.bool(forKey: k) }
        func i(_ k: String, _ def: Int) -> Int { ud.object(forKey: k) == nil ? def : ud.integer(forKey: k) }
        func l(_ k: String, _ def: Int64) -> Int64 { (ud.object(forKey: k) as? NSNumber)?.int64Value ?? def }
        func f(_ k: String, _ def: Double) -> Double { ud.object(forKey: k) == nil ? def : ud.double(forKey: k) }
        func s(_ k: String, _ def: String = "") -> String { ud.string(forKey: k) ?? def }

        onboardingAccepted = b("onboarding_v1", false)
        let os = Keychain.get("os_api_key")
        osApiKey = os.isEmpty ? Keychain.migrateLegacyOSKey() : os
        recentSearches = ud.stringArray(forKey: "recent_searches") ?? []
        osPremium = b("os_premium", false)
        baseSourceId = s("base_source", "os_outdoor")
        mapFullScreen = b("map_full_screen", false)
        menuOpacityPercent = i("menu_opacity", 92).clamped(70, 100)
        what3wordsKey = Keychain.get("what3words_key")
        mapHeadingUp = b("map_heading_up", false)
        imperial = b("imperial", false)
        offlineOnly = b("offline_only", false)
        showOfflineAreas = b("show_offline_areas", true)
        showSteepGround = b("show_steep_ground", false)
        showLidar = b("show_lidar", false)
        packLidar = b("pack_lidar", true)
        revealLidar = b("reveal_lidar", false)
        revealStyle = LidarReveal.Style.of(ud.string(forKey: "reveal_style"))
        revealPercent = i("reveal_percent", 50).clamped(0, 100)
        showFacilities = b("show_facilities", true)
        flatSpeedKmh = f("flat_speed", 4.5)
        conditionsFactor = f("conditions", 1.0)
        offRouteThresholdM = i("off_route_m", 60)
        let margin = i("daylight_margin_min", 30)
        daylightMarginMinutes = [0, 30, 60].contains(margin) ? margin : 30
        daylightAlertState = s("daylight_alert_state")
        activeRouteId = l("active_route", -1)
        mapLat = f("map_lat", 54.46)
        mapLon = f("map_lon", -3.09)
        mapZoom = f("map_zoom", 11)
        customName = s("custom_name")
        customTemplate = s("custom_template")
        customAttribution = s("custom_attr")
        customMaxZoom = i("custom_maxz", 17)
        customOfflineAllowed = b("custom_offline", false)
        emergencyContact = s("emergency_contact")
        emergencyContactName = s("emergency_contact_name")
        checkInDueMs = l("check_in_due", 0)
        checkInRoute = s("check_in_route")
        checkInRouteId = l("check_in_route_id", 0)
        checkInStage = i("check_in_stage", 0)
        renewAsked = (ud.dictionary(forKey: "renew_asked") as? [String: NSNumber] ?? [:])
            .reduce(into: [:]) { acc, kv in if let id = Int64(kv.key) { acc[id] = kv.value.int64Value } }
        frontierDeviceId = s("frontier_device_id")
        frontierSequence = l("frontier_sequence", 0)
        frontierEnabled = b("frontier_enabled", true)
        frontierHeartbeatsEnabled = b("frontier_heartbeats_enabled", true)
        frontierFallDetectionEnabled = b("frontier_fall_detection_enabled", true)
        frontierSatelliteDataEnabled = b("frontier_satellite_data_enabled", true)
        groupRelayEnabled = b("group_relay", true)
        groupShowOnMap = b("group_show_on_map", true)
        groupLongRange = b("group_long_range", true)
        groupHelpAlerts = b("group_help_alerts", true)
        groupUwbFindable = b("group_uwb_findable", true)
        groupDisclosureAccepted = b("group_disclosure_v1", false)
        groupDisplayName = s("group_display_name")
        groupSequence = l("group_sequence", 0)
        groupHikes = b("group_hikes", true)
        groupHikesAsk = b("group_hikes_ask", false)
        autoPauseInVehicle = b("auto_pause_vehicle", true)
        mapTilerKey = Keychain.get("maptiler_key")
        historicOverlayId = s("historic_overlay")
        historicOverlayPercent = i("historic_overlay_percent", 55).clamped(10, 100)
        stravaClientId = s("strava_client_id")
        stravaClientSecret = Keychain.get("strava_client_secret")
        stravaAccessToken = Keychain.get("strava_access_token")
        stravaRefreshToken = Keychain.get("strava_refresh_token")
        stravaExpiresAtS = l("strava_expires_at", 0)
        stravaScope = s("strava_scope")
        stravaAthleteId = l("strava_athlete_id", 0)
        stravaAthleteUsername = s("strava_athlete_username")
        stravaAthleteFirstName = s("strava_athlete_first")
        stravaAthleteLastName = s("strava_athlete_last")
        stravaNeedsReconnect = b("strava_needs_reconnect", false)
        stravaPendingState = s("strava_pending_state")
        stravaAuto = b("strava_auto", true)
        stravaKind = s("strava_kind", "hike")
        frontierEmergencyStatus = i("frontier_emergency_status", 0)
        fallAlertMs = l("fall_alert_ms", 0)
        fallStage = i("fall_stage", 0)
        sosSituation = s("sos_situation")
        sosAttempts = i("sos_attempts", 0)
        sosFailed = b("sos_failed", false)
        sosSentMs = l("sos_sent_ms", 0)
        sosRecipient = s("sos_recipient")
        sosAutoSend = b("sos_auto_send", false)
        unfinishedHikeOffered = l("unfinished_hike_offered", 0)
        fallAlarmSound = b("fall_alarm_sound", true)
        beaconUseAppleIntelligence = b("beacon_apple_intelligence", true)
    }

    @Published var onboardingAccepted: Bool { didSet { d.set(onboardingAccepted, forKey: "onboarding_v1") } }
    /// The user's own OS Data Hub API key. Never bundled with the app.
    @Published var osApiKey: String { didSet { Keychain.set("os_api_key", osApiKey.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    @Published var recentSearches: [String] { didSet { d.set(Array(recentSearches.prefix(5)), forKey: "recent_searches") } }
    /// The OS key's project can load Premium zooms, as last seen by Save & test or the map.
    @Published var osPremium: Bool { didSet { d.set(osPremium, forKey: "os_premium") } }
    @Published var baseSourceId: String { didSet { d.set(baseSourceId, forKey: "base_source") } }
    /// Wide layout: the map fills the window, with the navigation rail and side pane hidden.
    @Published var mapFullScreen: Bool { didSet { d.set(mapFullScreen, forKey: "map_full_screen") } }
    @Published var menuOpacityPercent: Int { didSet { d.set(menuOpacityPercent.clamped(70, 100), forKey: "menu_opacity") } }
    @Published var what3wordsKey: String { didSet { Keychain.set("what3words_key", what3wordsKey.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    /// The map turns so the way you face is at the top, instead of north.
    @Published var mapHeadingUp: Bool { didSet { d.set(mapHeadingUp, forKey: "map_heading_up") } }
    @Published var imperial: Bool { didSet { d.set(imperial, forKey: "imperial") } }
    @Published var offlineOnly: Bool { didSet { d.set(offlineOnly, forKey: "offline_only") } }
    /// Tint and outline the map where the base map is on the phone.
    @Published var showOfflineAreas: Bool { didSet { d.set(showOfflineAreas, forKey: "show_offline_areas") } }
    @Published var showSteepGround: Bool { didSet { d.set(showSteepGround, forKey: "show_steep_ground") } }
    /// Hill shading and crags from 1 m LiDAR (England) on the map.
    @Published var showLidar: Bool { didSet { d.set(showLidar, forKey: "show_lidar") } }
    /// Route offline maps also save 1 m LiDAR near the route (England).
    @Published var packLidar: Bool { didSet { d.set(packLidar, forKey: "pack_lidar") } }
    /// The Reveal slider: LiDAR picture of the ground drawn over the part of the map left of a draggable line.
    @Published var revealLidar: Bool { didSet { d.set(revealLidar, forKey: "reveal_lidar") } }
    @Published var revealStyle: LidarReveal.Style { didSet { d.set(revealStyle.id, forKey: "reveal_style") } }
    /// How much of the map width, from the left, the Reveal picture covers: 0–100.
    @Published var revealPercent: Int { didSet { d.set(revealPercent.clamped(0, 100), forKey: "reveal_percent") } }
    @Published var showFacilities: Bool { didSet { d.set(showFacilities, forKey: "show_facilities") } }
    @Published var flatSpeedKmh: Double { didSet { d.set(flatSpeedKmh, forKey: "flat_speed") } }
    @Published var conditionsFactor: Double { didSet { d.set(conditionsFactor, forKey: "conditions") } }
    @Published var offRouteThresholdM: Int { didSet { d.set(offRouteThresholdM, forKey: "off_route_m") } }
    @Published var daylightMarginMinutes: Int { didSet { d.set(daylightMarginMinutes, forKey: "daylight_margin_min") } }
    @Published var daylightAlertState: String { didSet { d.set(daylightAlertState, forKey: "daylight_alert_state") } }
    @Published var activeRouteId: Int64 { didSet { d.set(NSNumber(value: activeRouteId), forKey: "active_route") } }
    @Published var mapLat: Double { didSet { d.set(mapLat, forKey: "map_lat") } }
    @Published var mapLon: Double { didSet { d.set(mapLon, forKey: "map_lon") } }
    @Published var mapZoom: Double { didSet { d.set(mapZoom, forKey: "map_zoom") } }
    @Published var customName: String { didSet { d.set(customName, forKey: "custom_name") } }
    @Published var customTemplate: String { didSet { d.set(customTemplate, forKey: "custom_template") } }
    @Published var customAttribution: String { didSet { d.set(customAttribution, forKey: "custom_attr") } }
    @Published var customMaxZoom: Int { didSet { d.set(customMaxZoom, forKey: "custom_maxz") } }
    /// The user confirms their provider's licence permits storing tiles offline.
    @Published var customOfflineAllowed: Bool { didSet { d.set(customOfflineAllowed, forKey: "custom_offline") } }
    @Published var emergencyContact: String { didSet { d.set(emergencyContact, forKey: "emergency_contact") } }
    @Published var emergencyContactName: String { didSet { d.set(emergencyContactName, forKey: "emergency_contact_name") } }
    @Published var checkInDueMs: Int64 { didSet { d.set(NSNumber(value: checkInDueMs), forKey: "check_in_due") } }
    @Published var checkInRoute: String { didSet { d.set(checkInRoute, forKey: "check_in_route") } }
    @Published var checkInRouteId: Int64 { didSet { d.set(NSNumber(value: checkInRouteId), forKey: "check_in_route_id") } }
    @Published var checkInStage: Int { didSet { d.set(checkInStage, forKey: "check_in_stage") } }
    /// Pack id to the 24-hour detail expiry the user has already been asked to renew.
    @Published var renewAsked: [Int64: Int64] {
        didSet { d.set(Dictionary(uniqueKeysWithValues: renewAsked.map { (String($0.key), NSNumber(value: $0.value)) }), forKey: "renew_asked") }
    }
    @Published var frontierDeviceId: String { didSet { d.set(frontierDeviceId, forKey: "frontier_device_id") } }
    @Published var frontierSequence: Int64 { didSet { d.set(NSNumber(value: frontierSequence), forKey: "frontier_sequence") } }
    @Published var frontierEnabled: Bool { didSet { d.set(frontierEnabled, forKey: "frontier_enabled") } }
    @Published var frontierHeartbeatsEnabled: Bool { didSet { d.set(frontierHeartbeatsEnabled, forKey: "frontier_heartbeats_enabled") } }
    @Published var frontierFallDetectionEnabled: Bool { didSet { d.set(frontierFallDetectionEnabled, forKey: "frontier_fall_detection_enabled") } }
    @Published var frontierSatelliteDataEnabled: Bool { didSet { d.set(frontierSatelliteDataEnabled, forKey: "frontier_satellite_data_enabled") } }
    /// Pass on other trip-group members' positions, so the group reaches further than one phone's range.
    @Published var groupRelayEnabled: Bool { didSet { d.set(groupRelayEnabled, forKey: "group_relay") } }
    @Published var groupShowOnMap: Bool { didSet { d.set(groupShowOnMap, forKey: "group_show_on_map") } }
    @Published var groupLongRange: Bool { didSet { d.set(groupLongRange, forKey: "group_long_range") } }
    @Published var groupHelpAlerts: Bool { didSet { d.set(groupHelpAlerts, forKey: "group_help_alerts") } }
    /// Answer when someone in the trip group asks to find this phone up close (UWB / Nearby Interaction).
    @Published var groupUwbFindable: Bool { didSet { d.set(groupUwbFindable, forKey: "group_uwb_findable") } }
    @Published var groupDisclosureAccepted: Bool { didSet { d.set(groupDisclosureAccepted, forKey: "group_disclosure_v1") } }
    @Published var groupDisplayName: String { didSet { d.set(groupDisplayName, forKey: "group_display_name") } }
    @Published var groupSequence: Int64 { didSet { d.set(NSNumber(value: groupSequence), forKey: "group_sequence") } }
    /// Hikes are logged for the whole trip group: starting one invites the others to record theirs.
    @Published var groupHikes: Bool { didSet { d.set(groupHikes, forKey: "group_hikes") } }
    @Published var groupHikesAsk: Bool { didSet { d.set(groupHikesAsk, forKey: "group_hikes_ask") } }
    /// Pause the hike when the phone is moving at vehicle speed for half a minute.
    @Published var autoPauseInVehicle: Bool { didSet { d.set(autoPauseInVehicle, forKey: "auto_pause_vehicle") } }
    /// The user's own MapTiler Cloud key, which serves the National Library of Scotland's old maps. Never bundled.
    @Published var mapTilerKey: String { didSet { Keychain.set("maptiler_key", mapTilerKey.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    /// An old map drawn over the base map (a map layer id), or empty for none.
    @Published var historicOverlayId: String { didSet { d.set(historicOverlayId, forKey: "historic_overlay") } }
    /// How much of the old map shows through over the base map, 10-100 %.
    @Published var historicOverlayPercent: Int { didSet { d.set(historicOverlayPercent.clamped(10, 100), forKey: "historic_overlay_percent") } }

    // Strava
    @Published var stravaClientId: String { didSet { d.set(stravaClientId, forKey: "strava_client_id") } }
    @Published var stravaClientSecret: String { didSet { Keychain.set("strava_client_secret", stravaClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    @Published var stravaAccessToken: String { didSet { Keychain.set("strava_access_token", stravaAccessToken) } }
    @Published var stravaRefreshToken: String { didSet { Keychain.set("strava_refresh_token", stravaRefreshToken) } }
    /// When the access token lapses, seconds since 1970.
    @Published var stravaExpiresAtS: Int64 { didSet { d.set(NSNumber(value: stravaExpiresAtS), forKey: "strava_expires_at") } }
    @Published var stravaScope: String { didSet { d.set(stravaScope, forKey: "strava_scope") } }
    @Published var stravaAthleteId: Int64 { didSet { d.set(NSNumber(value: stravaAthleteId), forKey: "strava_athlete_id") } }
    @Published var stravaAthleteUsername: String { didSet { d.set(stravaAthleteUsername, forKey: "strava_athlete_username") } }
    @Published var stravaAthleteFirstName: String { didSet { d.set(stravaAthleteFirstName, forKey: "strava_athlete_first") } }
    @Published var stravaAthleteLastName: String { didSet { d.set(stravaAthleteLastName, forKey: "strava_athlete_last") } }
    @Published var stravaNeedsReconnect: Bool { didSet { d.set(stravaNeedsReconnect, forKey: "strava_needs_reconnect") } }
    @Published var stravaPendingState: String { didSet { d.set(stravaPendingState, forKey: "strava_pending_state") } }
    @Published var stravaAuto: Bool { didSet { d.set(stravaAuto, forKey: "strava_auto") } }
    @Published var stravaKind: String { didSet { d.set(stravaKind, forKey: "strava_kind") } }

    // Safety state
    @Published var frontierEmergencyStatus: Int { didSet { d.set(frontierEmergencyStatus, forKey: "frontier_emergency_status") } }
    @Published var fallAlertMs: Int64 { didSet { d.set(NSNumber(value: fallAlertMs), forKey: "fall_alert_ms") } }
    @Published var fallStage: Int { didSet { d.set(fallStage, forKey: "fall_stage") } }
    @Published var sosSituation: String { didSet { d.set(sosSituation, forKey: "sos_situation") } }
    @Published var sosAttempts: Int { didSet { d.set(sosAttempts, forKey: "sos_attempts") } }
    @Published var sosFailed: Bool { didSet { d.set(sosFailed, forKey: "sos_failed") } }
    @Published var sosSentMs: Int64 { didSet { d.set(NSNumber(value: sosSentMs), forKey: "sos_sent_ms") } }
    @Published var sosRecipient: String { didSet { d.set(sosRecipient, forKey: "sos_recipient") } }
    /// iOS cannot send texts by itself; this only means "open the prepared SOS text straight away".
    @Published var sosAutoSend: Bool { didSet { d.set(sosAutoSend, forKey: "sos_auto_send") } }

    // iPhone only
    /// The unfinished hike the user was last offered to recover, so the offer isn't repeated on every launch.
    @Published var unfinishedHikeOffered: Int64 { didSet { d.set(NSNumber(value: unfinishedHikeOffered), forKey: "unfinished_hike_offered") } }
    @Published var fallAlarmSound: Bool { didSet { d.set(fallAlarmSound, forKey: "fall_alarm_sound") } }
    /// Beacon writes its briefing with Apple Intelligence's on-device model when the phone has it.
    @Published var beaconUseAppleIntelligence: Bool { didSet { d.set(beaconUseAppleIntelligence, forKey: "beacon_apple_intelligence") } }

    var hasStravaSecret: Bool { !stravaClientSecret.isEmpty }
    var hasStravaRefreshToken: Bool { !stravaRefreshToken.isEmpty }
}
