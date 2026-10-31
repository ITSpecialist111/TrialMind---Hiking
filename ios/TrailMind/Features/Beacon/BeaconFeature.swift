import Foundation

/// Beacon and Strava: sets their cross-feature hooks and starts posting to Strava. `start()` runs once at launch.
enum BeaconFeature {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        FeatureHooks.openBriefing = { routeId in
            Navigator.shared.push(PageRoute("beacon-\(routeId.map(String.init) ?? "route")") { BeaconPage(routeId: routeId) })
        }
        FeatureHooks.openStrava = { StravaPage.open() }
        FeatureHooks.stravaUploadHike = { StravaService.shared.uploadHike($0) }
        FeatureHooks.stravaStatus = { StravaService.shared.status($0) }
        FeatureHooks.stravaPostNow = { StravaService.shared.postNowFromHikePage($0) }
        FeatureHooks.hikeFinishedListeners.append { StravaService.shared.onHikeFinished($0) }
        // Strava's sign-in coming back through the app's link (when it doesn't return to the sign-in sheet). Checked
        // before the trip-group invites, which share the trailmind:// scheme, as on Android.
        AppEvents.shared.urlHandlers.insert({ url in
            guard StravaOAuth.isRedirect(url.absoluteString) else { return false }
            StravaService.shared.handleRedirect(url.absoluteString) { AppModel.shared.toast($0) }
            if Navigator.shared.stack.last?.id != StravaPage.routeId { StravaPage.open() }
            return true
        }, at: 0)
        StravaService.shared.start()
    }

    // MARK: Facilities saved by the route page

    static let facilitiesAttribution = "Facilities: © OpenStreetMap contributors"

    /// The facilities found near a route and saved on the phone (OverpassFacilities.saved: Application Support/pois/<route
    /// id>.json, in the Android app's format), or nil when there are none or the file is damaged.
    static func facilities(_ routeId: Int64) -> BeaconFacilities? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let file = base.appendingPathComponent("pois", isDirectory: true).appendingPathComponent("\(routeId).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return BeaconFacilities.parse(data)
    }
}
