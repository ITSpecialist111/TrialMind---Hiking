import SwiftUI

/// Hike recording, the hike library and route guidance on the map. `start()` runs once at launch: it starts the
/// recorder and guidance services, sets this feature's hooks, registers the auto-pause notification actions and offers
/// to recover a hike whose recording was interrupted.
enum HikesFeature {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        HikeNotifications.shared.install()
        HikeRecorder.shared.start()
        Guidance.shared.start()
        _ = GoToState.shared
        FeatureHooks.startHike = { name in HikeRecorder.shared.startFromHook(name) }
        FeatureHooks.recordingNow = {
            let recorder = HikeRecorder.shared
            return (recording: recorder.status != .idle, name: recorder.status != .idle ? recorder.hikeName : nil)
        }
        FeatureHooks.goTo = { name, position in Guidance.shared.goTo(name, position) }
        FeatureHooks.retrace = { retraceSteps() }
        FeatureHooks.openHikeDetail = { id in openHike(id) }
    }

    static func detailRoute(_ id: Int64) -> PageRoute {
        PageRoute("hike-detail-\(id)") { HikeDetailPage(hikeId: id) }
    }

    /// Shows a hike's page on the Hikes tab (after finishing, from a notification or another feature).
    static func openHike(_ id: Int64) {
        Navigator.shared.open(.hikes, detailRoute(id))
    }

    /// "Retrace my steps" (SafetyPage): guidance back along the recorded track to where the hike started.
    static func retraceSteps() {
        if Guidance.shared.retrace() {
            AppModel.shared.toast("Guiding you back along your track to where the hike started.")
            Navigator.shared.showMap()
        } else {
            AppModel.shared.toast("Not enough track recorded yet.")
        }
    }

    /// A GPX file name from a hike's name, short enough that the extension survives AppModel's file-name limit.
    static func gpxFileName(_ name: String) -> String {
        String(AppModel.safeFileName(name).prefix(56)) + ".gpx"
    }
}
