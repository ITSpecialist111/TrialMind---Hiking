import Foundation

/// Starts each feature's services at launch. Features add their start call here when they are integrated.
enum FeatureStartup {
    static func startAll() {
        MapHeadingDriver.shared.start()
        // Hikes chains to any notification delegate set before it, so it starts after the other features.
        HikesFeature.start()
    }
}
