import Foundation

/// Safety & location: the Safety page, the compass, satellites & telemetry, check-ins, the fall alarm, what3words and
/// Frontier status. `start()` runs once at launch: it starts the services, sets this feature's hooks and joins the
/// hike recording's start and finish.
enum SafetyFeature {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        SafetyNotifications.shared.install()
        FrontierStatus.shared.start()
        PressureWatch.shared.start()
        CheckInService.shared.start()
        FallMonitor.shared.start()
        FallAlarm.shared.start()

        FeatureHooks.openTelemetry = { Navigator.shared.push(telemetryRoute) }
        // Other pages open the dialog from their own dialogs' buttons: let those close first.
        FeatureHooks.openCheckIn = { SafetyUI.afterDialog { CheckInUI.pickForCurrentWalk() } }
        FeatureHooks.pickCheckIn = { route, minutes, routeId in
            SafetyUI.afterDialog { CheckInUI.pick(route: route, planningMinutes: minutes, routeId: routeId) }
        }
        FeatureHooks.clearCheckIn = { CheckInService.shared.clear() }
        FeatureHooks.safetySummary = { summary() }
        FeatureHooks.shareLocation = { SafetyLocation.share() }
        // Fall detection follows the recording; a finished hike ends its check-in (TrackingService.finish).
        FeatureHooks.hikeStartedListeners.append { _, _ in
            SafetyNotifications.shared.requestAuthorization()
            FallMonitor.shared.refresh()
        }
        FeatureHooks.hikeFinishedListeners.append { _ in
            CheckInService.shared.clear()
            FallMonitor.shared.refresh()
        }
    }

    static let telemetryRoute = PageRoute("safety-telemetry") { TelemetryPage() }

    /// The dashboard's safety line: the fall alarm, the check-in and whether falls are being watched for.
    static func summary() -> String? {
        let prefs = Prefs.shared
        let due = prefs.checkInDueMs
        return SafetyText.summary(alarm: FallAlarm.shared.state.stage, checkInDueMs: due, nowMs: nowMs(),
                                  dueTime: due > 0 ? SafetyFormat.clock(due) : "",
                                  fallDetectionOn: prefs.frontierEnabled && prefs.frontierFallDetectionEnabled && FallMonitor.shared.available)
    }
}
