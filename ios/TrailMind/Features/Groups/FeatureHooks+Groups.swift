import SwiftUI

/// Cross-feature hooks the trip group adds (set in `GroupsFeature.start()`).
extension FeatureHooks {
    /// Safety page: the trip group's card (Android SafetyPage.groupCard), or the intro card with Create and Join when
    /// this phone isn't in a group.
    static var groupSafetyCard: (() -> AnyView)?
}
