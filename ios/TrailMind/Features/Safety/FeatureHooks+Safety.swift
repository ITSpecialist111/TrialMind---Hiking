import Foundation

/// Hooks the Safety feature adds for other features (it sets them in `SafetyFeature.start()`), and one it reads.
extension FeatureHooks {
    /// Cancels the check-in (the Hikes recording card's "Cancel check-in").
    static var clearCheckIn: (() -> Void)?

    /// The check-in dialog for a particular walk (ui/CheckInUi.kt pickCheckIn): its name, its planning time in minutes
    /// (the suggested return time is now plus 1½ × that, to the next quarter hour) and its route id (0 for none).
    /// `openCheckIn` is the same for the followed route, or "my walk".
    static var pickCheckIn: ((_ route: String, _ planningMinutes: Double, _ routeId: Int64) -> Void)?

    /// Route guidance for the compass, set by the feature that follows routes: where you are on the followed route
    /// (with its next waypoint) and whether you are off it, or nil when no route is followed. The compass points to the
    /// map target first, then the next waypoint, then the way the route heads.
    static var compassGuide: (() -> (fix: RouteFix, offRoute: Bool)?)?
}
