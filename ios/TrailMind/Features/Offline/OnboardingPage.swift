import Combine
import CoreLocation
import SwiftUI

/// The first-run introduction and safety acceptance (Pages2.kt OnboardingPage). TrailMind opens it over everything until
/// it is accepted; Settings → Show safety introduction opens it again as a page.
struct OnboardingPage: View {
    @Environment(\.palette) private var p
    @Environment(\.pageCanGoBack) private var canGoBack

    var body: some View {
        PageScaffold("Welcome to TrailMind") {
            HStack(alignment: .center, spacing: 12) {
                TrailMindLogo(size: 52)
                TMText("A personal, offline-first hiking companion.", .title)
            }
            TMCard(spacing: 10) {
                row(.map, "Maps: OpenStreetMap for browsing, Ordnance Survey maps with your own free OS Data Hub key, and offline map packs.")
                row(.route, "Import GPX routes, see time and climb estimates, and get off-route alerts while following them.")
                row(.walk, "Record hikes with GPS (works with the screen off), then export GPX for Strava or anything else.")
                row(.compass, "Compass, OS grid references and sunset times — all on-device.")
            }
            TMBanner(message: "Safety: TrailMind is an aid, not a replacement for a paper map, compass and the skills to use them. GPS, batteries and phone signal fail. " +
                     "Check the weather, tell someone your plans, and in the UK call 999 or 112 and ask for Police, then Mountain Rescue.", danger: true)
            TMText("Privacy: no accounts, ads or analytics. Your routes, hikes and contacts stay on this phone. Maps, search, weather and route tools send only the area or points they need to their provider. " +
                   "Your location is texted only to your chosen contact, when you tap Send. " +
                   "If you join a trip group, it is also shared, encrypted, with the group's phones nearby.", .caption)
            TMButton("I understand – continue", icon: .play, fill: true) { accept() }
        }
        .background(p.bg.ignoresSafeArea())
    }

    private func row(_ icon: TMIcon, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TMIconView(icon: icon, size: 24, color: p.primary)
            TMText(text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func accept() {
        Prefs.shared.onboardingAccepted = true
        if canGoBack { Navigator.shared.pop() }
        OnboardingLocation.locateWhenAllowed()
    }
}

/// After the introduction: ask for location (the first time) and show where you are once allowed
/// (host.withLocationPermission { map.locate() }).
enum OnboardingLocation {
    private static var waiting: AnyCancellable?

    static func locateWhenAllowed() {
        let hub = LocationHub.shared
        if hub.hasPermission {
            MapController.shared.locate()
            return
        }
        guard hub.authorization == .notDetermined else { return }
        waiting = hub.$authorization
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { status in
                guard status != .notDetermined else { return }
                waiting = nil
                if status == .authorizedWhenInUse || status == .authorizedAlways { MapController.shared.locate() }
            }
        hub.requestPermission()
    }
}
