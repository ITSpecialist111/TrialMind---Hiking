import Foundation

extension FeatureHooks {
    /// Strava: post a finished hike now, or try again after it failed ("Post now" / "Try again" on the hike page).
    /// Without a working link it falls back to uploading by hand, or offers to connect again.
    static var stravaPostNow: ((Int64) -> Void)?
}
