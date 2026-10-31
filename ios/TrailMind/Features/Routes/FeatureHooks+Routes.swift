import Foundation

/// Hooks the routes feature calls into other features for (set by those features when they are integrated). Each has a
/// fallback here when it is nil.
extension FeatureHooks {
    /// Offline maps: open the Offline page ready to download a route's corridor (Android's `OfflinePage(host, routeId)`).
    /// Without it the route page fits the route on the map and uses `offlineHere`.
    static var offlineForRoute: ((Int64) -> Void)?
    /// Safety: set or edit the check-in for a route (Android's `pickCheckIn(host, route, planningMinutes, routeId)`):
    /// route name, planning minutes, route id, and a callback once it changed. Without it the route page opens the
    /// check-in (`openCheckIn`) or the Safety tab.
    static var checkInForRoute: ((String, Double, Int64, @escaping () -> Void) -> Void)?
    /// Safety: clear the check-in, cancelling its reminders (Android's `CheckIn.clear`), when its route is deleted.
    /// Without it the route page clears the check-in settings itself.
    static var clearCheckIn: (() -> Void)?
}
