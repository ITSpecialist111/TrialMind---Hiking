import SwiftUI

/// The whole window: map underneath, then (by layout) the page, the rail and pane, or the fold split, and the
/// navigation. Implements the Android MainActivity layouts and iPhone Duo's poses.
struct RootView: View {
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var nav = Navigator.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var duo = DuoState.shared
    @ObservedObject private var map = MapController.shared
    @ObservedObject private var location = LocationHub.shared
    @Environment(\.palette) private var p
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            let fold = foldRect(geo)
            let occlusions = occlusionRects(geo)
            let g = ShellGeometry.resolve(size: geo.size, safe: geo.safeAreaInsets, fold: fold,
                                          verticalBarEdge: duo.verticalBarEdge, occlusions: occlusions, fullScreen: prefs.mapFullScreen)
            shell(g)
                .onAppear { nav.mapHasPane = !g.usesCapsule || g.mode == .foldTable }
                .onChange(of: g.mode) { _, _ in nav.mapHasPane = g.mode != .compact }
        }
        .ignoresSafeArea()
        .background(DuoProbe().ignoresSafeArea().allowsHitTesting(false))
        .modifier(DialogHost(app: app))
        .onChange(of: scenePhase) { _, phase in
            location.setForeground(phase == .active)
            if phase != .active { map.saveCamera() }
            if phase == .active { TileLoader.shared.purgeExpiredPremium() }
        }
        .onAppear { location.setForeground(true) }
        .fullScreenCover(isPresented: Binding(get: { !prefs.onboardingAccepted }, set: { _ in })) {
            PaletteProvider { OnboardingPage() }
        }
    }

    /// The active fold in window coordinates: SwiftUI's reserved regions first, then UIKit's.
    private func foldRect(_ geo: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            if let r = geo.reservedRegions(kind: .division).first(where: { $0.isActive }) { return r.frame }
        }
        return duo.fold
    }

    private func occlusionRects(_ geo: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) {
            let list = geo.reservedRegions(kind: .occlusion).filter { $0.isActive }.map(\.frame)
            if !list.isEmpty { return list }
        }
        return duo.occlusions
    }

    private var tabs: [Tab] { Tab.allCases }

    @ViewBuilder private func shell(_ g: ShellGeometry) -> some View {
        let showPageCompact = !(nav.tab == .map && nav.stack.isEmpty)
        ZStack(alignment: .topLeading) {
            MapScreen(map: map, prefs: prefs, location: location, geometry: g,
                      showControls: g.mode != .compact || !showPageCompact || nav.tab == .map && nav.stack.isEmpty)

            switch g.mode {
            case .compact:
                if showPageCompact {
                    pageContainer(g)
                        .frame(width: g.size.width, height: g.size.height)
                        .padding(.top, 0)
                        .background(p.bg)
                        .overlay(alignment: .bottom) { bottomFade(g) }
                        .transition(.opacity)
                }
                capsule(g)
            case .wide, .foldBook:
                menu(g)
                if g.fullScreen { reopenHandle(g) }
            case .foldTable:
                pane(g)
                capsule(g)
            }
            ToastHost(app: app, bottom: g.usesCapsule ? g.size.height - g.capsuleFrame.minY + 12 : g.safe.bottom + 24)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: g)
    }

    // MARK: Pages

    @ViewBuilder private func currentPage(_ g: ShellGeometry) -> some View {
        if let top = nav.stack.last {
            top.make().id(top.id)
        } else {
            rootPage(nav.tab, g).id(nav.tab.rawValue)
        }
    }

    @ViewBuilder private func rootPage(_ t: Tab, _ g: ShellGeometry) -> some View {
        switch t {
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

    /// The narrow layout's page: full window over the map, respecting the safe area at the top and sides.
    @ViewBuilder private func pageContainer(_ g: ShellGeometry) -> some View {
        currentPage(g)
            .environment(\.pageInsets, g.pageInsets.edgeInsets)
            .environment(\.pageCanGoBack, nav.canGoBack)
            .padding(.top, g.safe.top)
            .padding(.leading, g.safe.leading)
            .padding(.trailing, g.safe.trailing)
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                // Edge swipe back, as elsewhere on iPhone.
                if nav.canGoBack, v.startLocation.x < 28, v.translation.width > 80, abs(v.translation.height) < 80 { nav.pop() }
            })
    }

    /// Content passes under the capsule, so its foot fades into the page colour instead of ending in a hard edge.
    @ViewBuilder private func bottomFade(_ g: ShellGeometry) -> some View {
        if g.nav == .bottom {
            LinearGradient(colors: [p.bg.opacity(0), p.bg], startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func capsule(_ g: ShellGeometry) -> some View {
        let vertical = g.nav != .bottom
        NavCapsule(nav: nav, tabs: Tab.compactTabs, vertical: vertical)
            .frame(width: vertical ? g.capsuleFrame.width : nil, height: vertical ? nil : g.capsuleFrame.height)
            .position(x: g.capsuleFrame.midX, y: g.capsuleFrame.midY)
    }

    /// Wide and book layouts: the rail and the rounded pane over the map (MainActivity wide layout).
    @ViewBuilder private func menu(_ g: ShellGeometry) -> some View {
        let opacity = Double(prefs.menuOpacityPercent) / 100
        let hiddenOffset = (g.menuOnLeading ? -1.0 : 1.0) * (g.railFrame.width + g.paneFrame.width + 24)
        ZStack(alignment: .topLeading) {
            NavRail(nav: nav, tabs: g.compactTabs ? Tab.compactTabs : Tab.railTabs, logo: !g.compactTabs, opacity: opacity)
                .padding(.top, g.safe.top)
                .padding(.bottom, g.safe.bottom)
                .frame(width: g.railFrame.width, height: g.railFrame.height)
                .offset(x: g.railFrame.minX, y: g.railFrame.minY)
            pane(g)
        }
        .offset(x: g.fullScreen ? hiddenOffset : 0)
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            // Swipe the menu away towards its edge to fold it up (UnfoldingMenuLayout).
            let towardsEdge = g.menuOnLeading ? v.translation.width < -70 : v.translation.width > 70
            if towardsEdge && abs(v.translation.height) < abs(v.translation.width) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { prefs.mapFullScreen = true }
            }
        })
    }

    @ViewBuilder private func pane(_ g: ShellGeometry) -> some View {
        let opacity = Double(prefs.menuOpacityPercent) / 100
        currentPage(g)
            .environment(\.pageInsets, EdgeInsets())
            .environment(\.pageCanGoBack, nav.canGoBack)
            .frame(width: g.paneFrame.width, height: g.paneFrame.height)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(p.bg.opacity(opacity))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(p.glassStroke, lineWidth: 1))
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .offset(x: g.paneFrame.minX, y: g.paneFrame.minY)
    }

    /// The handle that unfolds the menu again (scaled to 55%, with the full tap target kept).
    @ViewBuilder private func reopenHandle(_ g: ShellGeometry) -> some View {
        let x = g.menuOnLeading ? g.safe.leading + 30 : g.size.width - g.safe.trailing - 30
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { prefs.mapFullScreen = false }
        } label: {
            TMIconView(icon: .fullscreenExit, size: 24, color: p.onSurface)
                .frame(width: 48, height: 48)
                .glassBackground(p, radius: 24)
                .scaleEffect(0.55)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show the menu")
        .position(x: x, y: g.size.height / 2)
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in
            let out = g.menuOnLeading ? v.translation.width > 40 : v.translation.width < -40
            if out { withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { prefs.mapFullScreen = false } }
        })
    }
}
