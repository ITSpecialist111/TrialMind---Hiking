import Foundation

/// Starts each feature's services at launch. Features add their start call here when they are integrated.
enum FeatureStartup {
    static func startAll() {
        MapHeadingDriver.shared.start()
        GroupsFeature.start()
        RoutesFeature.start()
        // Safety must start at launch so check-in and fall-alarm notification actions work when they cold-launch the app.
        SafetyFeature.start()
        // Beacon registers the Strava background task, which iOS only allows during launch.
        BeaconFeature.start()
        // Offline maps register their Premium purge and download tasks during launch too.
        OfflineFeature.start()
        // Hikes chains to any notification delegate set before it, so it starts after the other features.
        HikesFeature.start()
    }
}
