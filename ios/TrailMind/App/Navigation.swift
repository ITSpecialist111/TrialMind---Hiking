import SwiftUI

/// The Android app's destinations (MainActivity.Tab), in the same order with the same icons.
enum Tab: String, CaseIterable, Identifiable {
    case map, routes, hikes, compass, offline, assist, safety, settings, more

    var id: String { rawValue }

    var label: String {
        switch self {
        case .map: return "Map"
        case .routes: return "Routes"
        case .hikes: return "Hikes"
        case .compass: return "Compass"
        case .offline: return "Offline"
        case .assist: return "Beacon"
        case .safety: return "Safety"
        case .settings: return "Settings"
        case .more: return "More"
        }
    }

    var icon: TMIcon {
        switch self {
        case .map: return .map
        case .routes: return .route
        case .hikes: return .walk
        case .compass: return .compass
        case .offline: return .download
        case .assist: return .sparkle
        case .safety: return .sos
        case .settings: return .tune
        case .more: return .menu
        }
    }

    /// Narrow windows (the cover screen) and short wide ones show five destinations; the rest live under More.
    static let compactTabs: [Tab] = [.map, .routes, .hikes, .compass, .more]
    static let railTabs: [Tab] = [.map, .routes, .hikes, .compass, .offline, .assist, .safety, .settings]
}

/// A page pushed above a tab's root page. Two routes with the same id are the same page.
struct PageRoute: Identifiable, Hashable {
    let id: String
    let make: () -> AnyView

    init<V: View>(_ id: String, @ViewBuilder _ make: @escaping () -> V) {
        self.id = id
        self.make = { AnyView(make()) }
    }

    static func == (a: PageRoute, b: PageRoute) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Which destination is showing and the pages pushed above it (MainActivity's tab and page stack).
final class Navigator: ObservableObject {
    static let shared = Navigator()

    @Published private(set) var tab: Tab = .map
    @Published private(set) var stack: [PageRoute] = []
    /// Set by the shell: whether the map tab has a dashboard page (the wide layout) or is the bare map.
    var mapHasPane = false

    /// Switches destination. Tapping the current destination again returns to its root page.
    func show(_ t: Tab) {
        if t != tab {
            withAnimation(.easeInOut(duration: 0.2)) { tab = t; stack = [] }
            if Prefs.shared.mapFullScreen { Prefs.shared.mapFullScreen = false }
        } else if !stack.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) { stack = [] }
        } else if t == .map {
            MapController.shared.locate()
        }
    }

    func push(_ route: PageRoute) {
        if Prefs.shared.mapFullScreen { Prefs.shared.mapFullScreen = false }
        if stack.last?.id == route.id { return }
        withAnimation(.easeInOut(duration: 0.2)) { stack.append(route) }
    }

    /// Opens a page as the root of a tab (e.g. Safety from a notification).
    func open(_ t: Tab, _ route: PageRoute? = nil) {
        withAnimation(.easeInOut(duration: 0.2)) {
            tab = t
            stack = route.map { [$0] } ?? []
        }
    }

    var canGoBack: Bool { !stack.isEmpty }

    func pop() {
        guard !stack.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) { _ = stack.removeLast() }
    }

    /// Back to the map: in the narrow layout that hides the page; in the wide one it shows the dashboard.
    func showMap() {
        withAnimation(.easeInOut(duration: 0.2)) { tab = .map; stack = [] }
    }

    /// The highlighted destination: pages reached from More keep More selected in the five-tab capsule.
    func selected(in tabs: [Tab]) -> Tab { tabs.contains(tab) ? tab : .more }
}

// MARK: - Page environment

/// How far page content must keep clear of floating navigation, so it scrolls under the capsule instead of stopping short.
private struct PageInsetsKey: EnvironmentKey { static let defaultValue = EdgeInsets() }
/// Whether the page on show has a page below it to go back to.
private struct PageCanGoBackKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var pageInsets: EdgeInsets {
        get { self[PageInsetsKey.self] }
        set { self[PageInsetsKey.self] = newValue }
    }
    var pageCanGoBack: Bool {
        get { self[PageCanGoBackKey.self] }
        set { self[PageCanGoBackKey.self] = newValue }
    }
}
