import SwiftUI

/// More (Pages2.kt MorePage): the destinations that don't fit the five-tab capsule, the features other pages offer, and
/// what the display and iPhone Duo's fold report.
struct MorePage: View {
    @ObservedObject private var duo = DuoState.shared

    var body: some View {
        PageScaffold("More") {
            ForEach(Tab.allCases.filter { !Tab.compactTabs.contains($0) }) { t in
                ListItemRow(title: Self.title(t), subtitle: Self.subtitle(t), icon: t.icon, info: Self.info(t)) { open(t) }
                if t == .safety, let telemetry = FeatureHooks.openTelemetry {
                    ListItemRow(title: "Satellites & telemetry", subtitle: "Position accuracy, height and pressure", icon: .myLocation,
                                info: "See how accurate your position is, and the altitude and air pressure the phone reports. iPhone doesn't list the satellites it uses.") {
                        telemetry()
                    }
                }
            }
            if let search = FeatureHooks.openSearch {
                ListItemRow(title: "Search", subtitle: "Places, grid references and coordinates", icon: .search, action: search)
            }
            if let group = FeatureHooks.openGroup {
                ListItemRow(title: "Trip group", subtitle: FeatureHooks.groupSummary?() ?? "Your party on the map, phone to phone",
                            icon: .walk, action: group)
            }
            if let checkIn = FeatureHooks.openCheckIn {
                ListItemRow(title: "Check-in", subtitle: "Someone hears if you're late back", icon: .sos, action: checkIn)
            }
            if let strava = FeatureHooks.openStrava {
                ListItemRow(title: "Strava", subtitle: "Post finished hikes", icon: .upload, action: strava)
            }
            ListItemRow(title: "Display & fold", subtitle: "What iPhone Duo reports", icon: .info) {
                Navigator.shared.push(PageRoute("display") { DisplayDiagnosticsPage() })
            }
            if duo.hinge != .unavailable {
                TMText("Unfold your phone for a side-by-side map and panel layout.", .caption)
            }
        }
    }

    private func open(_ t: Tab) {
        Navigator.shared.push(PageRoute("more-\(t.rawValue)") { MoreTabPage(tab: t) })
    }

    private static func title(_ t: Tab) -> String {
        switch t {
        case .offline: return "Offline maps"
        case .safety: return "Safety & location"
        default: return t.label
        }
    }

    private static func subtitle(_ t: Tab) -> String? {
        switch t {
        case .offline: return "Maps for use without signal"
        case .assist: return "Prepare for your walk"
        case .safety: return "Your position and emergency tools"
        case .settings: return "Personalise TrailMind"
        case .routes: return "Plan, import and follow routes"
        case .hikes: return "Your recorded hikes"
        case .compass: return "Bearings and grid references"
        default: return nil
        }
    }

    private static func info(_ t: Tab) -> String? {
        switch t {
        case .offline:
            return "Download licensed OS areas or route corridors, or import MBTiles. Some premium detail expires after 24 hours. OpenStreetMap cannot be bulk downloaded."
        case .assist:
            return "A rule-based hike briefing with mountain weather, written with Apple Intelligence on iPhones that have it. Weather needs a connection to refresh; saved briefings remain available offline."
        case .safety:
            return "Read or share coordinates, grid references and optional what3words. Set a check-in, manage fall alerts or prepare an emergency message. Emergency information remains visible without opening help."
        case .settings:
            return "Set API keys, menu transparency, units, pace, route alerts, recording preferences and your emergency contact."
        default:
            return nil
        }
    }
}

/// A tab's root page opened from More in the narrow layout, where the capsule has room for five destinations.
struct MoreTabPage: View {
    let tab: Tab

    init(tab: Tab) { self.tab = tab }

    var body: some View {
        switch tab {
        case .map: DashboardPage()
        case .routes: RoutesPage()
        case .hikes: HikesPage()
        case .compass: CompassPage()
        case .offline: OfflinePage()
        case .assist: BeaconPage()
        case .safety: SafetyPage()
        case .settings: SettingsPage()
        case .more: MorePage()
        }
    }
}
