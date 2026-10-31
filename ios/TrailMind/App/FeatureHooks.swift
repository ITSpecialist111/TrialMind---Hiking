import Foundation

/// Cross-feature entry points. Each feature sets its hooks when its service starts, so the map and other pages can
/// reach it without depending on its files (and features can be built in parallel).
enum FeatureHooks {
    /// Route planner: start planning, optionally from a point (long-press "Plan a route from here").
    static var startPlan: ((LatLon?) -> Void)?
    /// Guidance: "Go to here" for a point.
    static var goTo: ((String, LatLon) -> Void)?
    /// Terrain: ground height at a point, with its credit line; calls back on the main queue.
    static var groundHeight: ((LatLon, @escaping (Double?, String?) -> Void) -> Void)?
    /// Offline maps: how many installed packs cover a source.
    static var packCount: ((TileSource) -> Int)?
    /// Offline maps: open the Offline page ready to download the area on screen.
    static var offlineHere: ((LatLon) -> Void)?
    /// Search: open the search page.
    static var openSearch: (() -> Void)?
    /// Trip group: a short summary for the map chip ("Group · 3 near"), or nil when not in a group.
    static var groupSummary: (() -> String?)?
    /// Trip group: fit everyone on the map.
    static var fitGroup: (() -> Void)?
    /// Old maps: "See it on an old map" for a box or point.
    static var showOldMap: ((BoundingBox?, LatLon?) -> Void)?
    /// Terrain overlays (steep ground, LiDAR) react to the settings changing.
    static var refreshTerrainOverlays: (() -> Void)?

    // Hikes
    /// Called when a hike starts recording (hike id, name) — fall monitoring, group hikes.
    static var hikeStartedListeners: [(Int64, String) -> Void] = []
    /// Called when a hike is finished and saved (hike id) — Strava automatic posting, fall monitoring.
    static var hikeFinishedListeners: [(Int64) -> Void] = []
    /// Starts recording a hike with a name (a trip-group member started a group hike). Returns false if one is already recording.
    static var startHike: ((String) -> Bool)?
    /// Whether a hike is recording right now (and its name), for other features' status lines.
    static var recordingNow: (() -> (recording: Bool, name: String?))?

    // Strava
    /// "Upload to Strava" for a finished hike.
    static var stravaUploadHike: ((Int64) -> Void)?
    /// A short Strava status for a hike ("On Strava", "Waiting for signal"...), or nil.
    static var stravaStatus: ((Int64) -> String?)?

    // Pages owned by other features, opened from Settings, More, Safety and the map.
    static var openStrava: (() -> Void)?
    static var openGroup: (() -> Void)?
    static var openTelemetry: (() -> Void)?
    static var openCheckIn: (() -> Void)?
    static var openRouteDetail: ((Int64) -> Void)?
    static var openHikeDetail: ((Int64) -> Void)?
    /// Beacon briefing for a route.
    static var openBriefing: ((Int64?) -> Void)?
    /// The safety summary line for the dashboard ("Check-in due 17:30", "Fall alarm on").
    static var safetySummary: (() -> String?)?
    /// Shows the current position's grid reference and what3words etc. (Safety → share location).
    static var shareLocation: (() -> Void)?
}
