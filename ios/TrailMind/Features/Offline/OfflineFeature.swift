import SwiftUI

// Placeholders for offline maps, search, settings, onboarding, More and the dashboard.
// The offline/settings feature replaces this whole file with its real implementation.

struct OfflinePage: View {
    var body: some View { FeaturePlaceholder(title: "Offline maps", note: "Offline maps are being ported.") }
}

struct SettingsPage: View {
    var body: some View { FeaturePlaceholder(title: "Settings", note: "Settings are being ported.") }
}

struct MorePage: View {
    var body: some View {
        PageScaffold("More") {
            ForEach(Tab.allCases.filter { !Tab.compactTabs.contains($0) }) { t in
                ListItemRow(title: t.label, icon: t.icon) { Navigator.shared.push(PageRoute("more-\(t.rawValue)") { MoreTabPage(tab: t) }) }
            }
            ListItemRow(title: "Display & fold", subtitle: "What iPhone Duo reports", icon: .info) {
                Navigator.shared.push(PageRoute("display") { DisplayDiagnosticsPage() })
            }
        }
    }
}

/// A tab's root page opened from More in the narrow layout.
struct MoreTabPage: View {
    let tab: Tab
    var body: some View {
        switch tab {
        case .offline: OfflinePage()
        case .assist: BeaconPage()
        case .safety: SafetyPage()
        case .settings: SettingsPage()
        default: EmptyView()
        }
    }
}

/// The map tab's side pane in the wide layout.
struct DashboardPage: View {
    var body: some View { FeaturePlaceholder(title: "Map", note: "Pick a route or start a hike.") }
}

struct OnboardingPage: View {
    var body: some View {
        VStack(spacing: 16) {
            TrailMindLogo(size: 72)
            Text("TrailMind supports navigation; it does not replace it.").font(.headline).multilineTextAlignment(.center)
            TMButton("I understand") { Prefs.shared.onboardingAccepted = true }
        }
        .padding(24)
    }
}
