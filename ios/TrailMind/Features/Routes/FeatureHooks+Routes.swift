import Foundation

/// Hooks the routes feature calls into other features for (set by those features when they are integrated). Each has a
/// fallback here when it is nil.
extension FeatureHooks {
    /// Offline maps: open the Offline page ready to download a route's corridor (Android's `OfflinePage(host, routeId)`).
    /// Without it the route page fits the route on the map and uses `offlineHere`.
    static var offlineForRoute: ((Int64) -> Void)?
    // Check-ins for a route use the safety feature's `pickCheckIn` and `clearCheckIn` (FeatureHooks+Safety.swift).
}
