import CoreLocation
import SwiftUI

/// Satellites & telemetry (ui/SatellitePage.kt), as far as iOS allows: the fix's accuracy, height, speed and course, the
/// barometer and the compass's state. iOS gives apps no list of the satellites behind a fix, so iPhone shows no sky plot
/// or signal list.
struct TelemetryPage: View {
    @StateObject private var position = SafetyFixWatcher()
    @StateObject private var ticker = SafetyTicker()
    @ObservedObject private var pressure = PressureWatch.shared
    @ObservedObject private var prefs = Prefs.shared

    init() {}

    var body: some View {
        let now = ticker.now
        let fix = position.fix
        let imperial = prefs.imperial
        PageScaffold("Satellites & telemetry") {
            HelpRow(summary: "Your GPS fix and sensors, live.",
                    detail: "A sky plot needs the receiver's satellite reports, which iOS keeps to itself: apps get the position with its accuracy, height, speed and course, but not the satellites behind it. Accuracy is the radius your true position is most likely within; indoors the phone falls back on Wi-Fi and mobile masts, and accuracy drops. Pressure comes from the barometer. GPS reception is not satellite messaging coverage.")
            if !position.hasPermission || !LocationHub.shared.fullAccuracy {
                TMBanner(message: "Allow precise location to see GPS telemetry.")
                TMButton("Allow precise location", icon: .myLocation) { SafetyUI.allowLocation(position.authorization) }
            }
            TMButton("Open TrailMind's location settings", icon: .myLocation, style: .text) { AppModel.shared.openSettings() }
            TMCard(spacing: 10) {
                TMText(summary(fix, now))
                StatGrid(items: [
                    ("Accuracy", fix.map { "±" + Units.distance(Double($0.accuracyM), imperial: imperial) } ?? "—"),
                    ("Altitude", fix?.altitudeM.map { Units.elevation($0, imperial: imperial) } ?? "—"),
                    ("Speed", fix?.speedMps.map { Units.speedKmh($0, imperial: imperial) } ?? "—"),
                    ("Course", fix?.courseDeg.map { Units.bearing($0) } ?? "—"),
                    ("Pressure", pressure.pressureHpa.map { fmt("%.1f hPa", $0) } ?? "—"),
                    ("Fix age", fix.map { "\(max((now - $0.timeMs) / 1_000, 0)) s" } ?? "—"),
                ], cols: 3)
                TMText("No sky plot on iPhone: iOS shares the position and its accuracy, not the satellites behind it.", .caption)
            }
            TMText(SafetyText.telemetry(fix.map { telemetryFix($0, now) }, pressureHpa: pressure.pressureHpa,
                                        compass: compassReading(now), imperial: imperial))
        }
        .onAppear {
            ticker.start()
            CompassMonitor.shared.acquire()
            LocationHub.shared.requestBarometer()
        }
        .onDisappear {
            ticker.stop()
            CompassMonitor.shared.release()
        }
    }

    private func summary(_ fix: Fix?, _ now: Int64) -> String {
        guard position.hasPermission else { return "Location permission is off." }
        guard let fix else { return "Waiting for a position fix. Move outdoors with a clear view of the sky." }
        if now - fix.timeMs > 10_000 { return "Position report expired; waiting for updates." }
        return "Live position fixes"
    }

    private func telemetryFix(_ fix: Fix, _ now: Int64) -> SafetyText.TelemetryFix {
        let location = fix.location
        var provider = "Core Location"
        if let source = location.sourceInformation {
            if source.isSimulatedBySoftware { provider = "simulated location" } else if source.isProducedByAccessory { provider = "GPS accessory" }
        }
        return SafetyText.TelemetryFix(provider: provider, ageS: (now - fix.timeMs) / 1_000, accuracyM: Double(fix.accuracyM),
                                       verticalAccuracyM: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
                                       altitudeM: fix.altitudeM, speedMps: fix.speedMps, courseDeg: fix.courseDeg)
    }

    private func compassReading(_ now: Int64) -> SafetyText.CompassReading {
        let hub = LocationHub.shared
        return SafetyText.CompassReading.of(disturbed: CompassMonitor.shared.disturbed, headingAtMs: hub.headingAtMs, nowMs: now,
                                            unreliable: hub.compassUnreliable)
    }
}
