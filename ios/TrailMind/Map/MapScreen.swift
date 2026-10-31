import MapKit
import SwiftUI

/// Map-screen state that sheets and dialogs share.
final class MapScreenState: ObservableObject {
    static let shared = MapScreenState()
    @Published var longPressed: LatLon? = nil
    @Published var showLayers = false
    @Published var showOldMaps = false
    @Published var showCredits = false
}

/// Everything floating over the map (MapScreen.kt), laid out inside the uncovered map area: status chips and cards at
/// the top, the tool capsule at the trailing edge, the record bar, credits and scale at the foot.
struct MapScreen: View {
    @Environment(\.palette) private var p
    @ObservedObject var map: MapController
    @ObservedObject var prefs: Prefs
    @ObservedObject var location: LocationHub
    @ObservedObject var state = MapScreenState.shared
    let geometry: ShellGeometry
    /// Whether the overlays show (narrow layout off the map tab: the page covers the map).
    let showControls: Bool

    var body: some View {
        let area = geometry.mapArea
        ZStack(alignment: .topLeading) {
            TrailMapView(controller: map, prefs: prefs, palette: p)
                .ignoresSafeArea()
                .onAppear { map.visibleArea = area }
                .onChange(of: area) { _, a in map.visibleArea = a }

            if showControls {
                // The middle of the uncovered map: why the chosen map isn't showing (TileMapView.drawHint).
                if let hint = hintText {
                    MapHint(text: hint, opensSettings: keyMissing)
                        .frame(maxWidth: max(0, area.width * 0.84))
                        .position(x: area.midX, y: area.midY)
                }

                // Top: status chips, then cards.
                VStack(alignment: .leading, spacing: 8) {
                    statusChips
                    GuidanceCard()
                    GoToCard()
                    PlannerCard()
                    RecoverCard()
                }
                .frame(width: max(0, area.width - 76), alignment: .topLeading)
                .offset(x: area.minX + 8, y: area.minY + 8)

                // Trailing: the tool capsule.
                toolCapsule
                    .offset(x: area.maxX - 56, y: area.minY + 8)

                // Foot: record bar above credits and scale.
                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 0)
                    RecordBar()
                    HStack(alignment: .bottom, spacing: 8) {
                        credits
                        ScalePlate(zoom: map.zoom, lat: map.center.lat, imperial: prefs.imperial)
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: max(0, area.width - 16), height: max(0, area.height - 8), alignment: .bottomLeading)
                .offset(x: area.minX + 8, y: area.minY)
            }
        }
        .sheet(isPresented: $state.showLayers) { LayersSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $state.showOldMaps) { OldMapsSheet().presentationDetents([.medium, .large]) }
        .sheet(item: Binding(get: { state.longPressed.map { PointBox(point: $0) } }, set: { state.longPressed = $0?.point })) { box in
            PointSheet(point: box.point).presentationDetents([.medium])
        }
        .onReceive(location.$latest) { fix in if let fix { map.onFix(fix) } }
    }

    private var currentSource: TileSource {
        TileSources.builtIns().first { $0.id == prefs.baseSourceId } ?? TileSources.builtIns()[0]
    }

    private var keyMissing: Bool {
        let s = currentSource
        return !s.appleMap && s.requiresKey && TileLoader.shared.apiKey(for: s) == nil
    }

    /// MapScreen.updateHint: a missing key first, then the last tile problem, then the source's own hint.
    private var hintText: String? {
        let s = currentSource
        if s.appleMap { return nil }
        if keyMissing { return "Add your free \(s.keyKind.label) in Settings to show this map" }
        return map.tileError ?? map.sourceHint
    }

    @ViewBuilder private var statusChips: some View {
        FlowLayout(spacing: 6) {
            TMChip(gpsLabel, glass: true, tint: gpsTint) { Navigator.shared.open(.safety) }
            TMChip(shortName(currentSource), glass: true, icon: .layers) { state.showLayers = true }
            if map.showingTrack { TMChip("Hike track  ✕", glass: true) { map.clearShownTrack() } }
            if map.searchPin != nil { TMChip("Clear search pin  ✕", glass: true) { map.clearSearchPin() } }
            if !prefs.historicOverlayId.isEmpty {
                TMChip("Old map \(prefs.historicOverlayPercent)%", glass: true) { state.showOldMaps = true }
            }
            GroupChip()
        }
    }

    private var gpsLabel: String {
        if !location.hasPermission { return location.authorization == .notDetermined ? "GPS off" : "No location access" }
        guard let fix = location.latest else { return "Waiting for GPS" }
        if fix.ageS > 30 { return "GPS stale · \(Int(fix.ageS))s" }
        if !location.fullAccuracy { return "Approximate location" }
        return "GPS ±\(Int(fix.accuracyM.rounded())) m"
    }

    private var gpsTint: Color? {
        if !location.hasPermission || !location.fullAccuracy { return p.danger }
        guard let fix = location.latest else { return p.accent }
        return fix.ageS > 30 || fix.accuracyM > 50 ? p.accent : nil
    }

    private func shortName(_ s: TileSource) -> String {
        s.name.replacingOccurrences(of: "OS Maps – ", with: "OS ").replacingOccurrences(of: " (online)", with: "")
    }

    private var toolCapsule: some View {
        VStack(spacing: 2) {
            FabButton(icon: .search, description: "Search", size: 44, flat: true) {
                if let open = FeatureHooks.openSearch { open() } else { Navigator.shared.open(.more) }
            }
            FabButton(icon: .layers, description: "Map layers", size: 44, flat: true) { state.showLayers = true }
            FabButton(icon: map.follow ? .navigation : .myLocation, description: map.follow ? "Following your position" : "Show my position",
                      size: 44, flat: true, fg: map.follow ? p.primary : p.onSurface) { map.locate() }
            FabButton(icon: .north, description: prefs.mapHeadingUp ? "Heading up. Tap for north up" : "North up. Tap for heading up",
                      size: 44, flat: true, fg: prefs.mapHeadingUp && map.headingUnavailable ? p.accent : (prefs.mapHeadingUp ? p.primary : p.onSurface),
                      rotation: -map.mapHeading) {
                prefs.mapHeadingUp.toggle()
                if !prefs.mapHeadingUp { map.setHeading(0) }
            }
            if geometry.usesRail {
                FabButton(icon: prefs.mapFullScreen ? .fullscreenExit : .fullscreen,
                          description: prefs.mapFullScreen ? "Show the menu" : "Full-screen map", size: 44, flat: true) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { prefs.mapFullScreen.toggle() }
                }
            }
        }
        .padding(4)
        .glassBackground(p, radius: 26)
    }

    @ViewBuilder private var credits: some View {
        let source = currentSource
        Button { AppModel.shared.info("Map data", creditsText(source)) } label: {
            HStack(alignment: .center, spacing: 6) {
                if source.showsOsLogo, let logo = OSLogo.image { Image(uiImage: logo).accessibilityLabel("Ordnance Survey") }
                Text(source.appleMap ? "Apple Maps" : source.attribution)
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassBackground(p, radius: 10, shadow: 2)
        }
        .buttonStyle(.plain)
    }

    private func creditsText(_ s: TileSource) -> String {
        var lines = [s.attribution]
        if s.showsOsLogo { lines.append("OS terms: \(TileSources.osTermsURL)\nReport an error: \(TileSources.osErrorsURL)") }
        if s.id == TileSources.osm { lines.append("Licence: \(TileSources.osmCopyrightURL)\nFix the map: \(TileSources.osmFixTheMapURL)") }
        if let old = TileSources.historic().first(where: { $0.id == prefs.historicOverlayId }) {
            lines.append(old.attribution + "\n" + TileSources.nlsMapsURL)
        }
        return lines.joined(separator: "\n\n")
    }
}

/// A note in the middle of the uncovered map (TileMapView.drawHint); with a missing key it opens Settings.
private struct MapHint: View {
    @Environment(\.palette) private var p
    let text: String
    let opensSettings: Bool

    var body: some View {
        let label = Text(text)
            .tm(.body, p)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassBackground(p, radius: 12, shadow: 2)
        if opensSettings {
            Button { Navigator.shared.open(.settings) } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Settings")
        } else {
            label.allowsHitTesting(false)
        }
    }
}

private struct PointBox: Identifiable {
    let point: LatLon
    var id: String { "\(point.lat),\(point.lon)" }
}

/// A distance bar of a round length for the current zoom (TileMapView's scale).
struct ScalePlate: View {
    @Environment(\.palette) private var p
    let zoom: Double
    let lat: Double
    let imperial: Bool

    var body: some View {
        let mpp = WebMercator.metresPerPixel(lat, zoom)
        let target = mpp * 90
        let nice = ScalePlate.niceLength(target, imperial: imperial)
        let width = CGFloat(nice / mpp)
        VStack(alignment: .leading, spacing: 2) {
            Text(Units.distance(nice, imperial: imperial)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.onSurface)
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(p.onSurface).frame(width: max(8, width), height: 2)
                Rectangle().fill(p.onSurface).frame(width: 2, height: 6)
                Rectangle().fill(p.onSurface).frame(width: 2, height: 6).offset(x: max(8, width) - 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassBackground(p, radius: 10, shadow: 2)
        .accessibilityLabel("Scale \(Units.distance(nice, imperial: imperial))")
    }

    static func niceLength(_ metres: Double, imperial: Bool) -> Double {
        let unit = imperial ? 1609.344 / 5280 : 1.0
        let v = metres / unit
        let pow10 = pow(10, floor(log10(max(v, 1))))
        let n = v / pow10
        let step = n >= 5 ? 5.0 : n >= 2 ? 2.0 : 1.0
        return step * pow10 * unit
    }
}

/// The long-press menu (MapScreen.onLongPress): grid reference and height, then the actions for that point.
struct PointSheet: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let point: LatLon
    @State private var height: String? = nil

    var body: some View {
        let grid = OsGrid.fromWgs84(point)?.format(8)
        let latLon = Units.latLon(point.lat, point.lon)
        VStack(alignment: .leading, spacing: 12) {
            Text(grid ?? latLon).tm(.headline, p)
            if grid != nil { Text(latLon).tm(.caption, p) }
            if let height { Text(height).tm(.caption, p) }
            TMButton("Plan a route from here", icon: .route, style: .tonal, fill: true) {
                dismiss()
                if let plan = FeatureHooks.startPlan { plan(point) } else { AppModel.shared.toast("Route planning is not available yet") }
            }
            TMButton("Go to here (bearing & distance)", icon: .navigation, style: .tonal, fill: true) {
                dismiss()
                if let goTo = FeatureHooks.goTo { goTo(grid ?? latLon, point) } else { MapController.shared.setTarget(grid ?? latLon, point) }
            }
            TMButton("Copy position", icon: .share, style: .tonal, fill: true) {
                dismiss()
                AppModel.shared.copy("Position", [grid, latLon].compactMap { $0 }.joined(separator: " · "))
            }
            TMButton("Offline map of this area…", icon: .download, style: .tonal, fill: true) {
                dismiss()
                MapController.shared.centerOn(point, zoom: max(MapController.shared.zoom, 12))
                if let here = FeatureHooks.offlineHere { here(point) } else { Navigator.shared.open(.offline) }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(p.bg)
        .onAppear {
            FeatureHooks.groundHeight?(point) { h, credit in
                if let h { height = "Height about \(Units.elevation(h, imperial: Prefs.shared.imperial))" + (credit.map { "\n\($0)" } ?? "") }
            }
        }
    }
}

/// Map layers (MapScreen.chooseLayer + chooseOverlays): base map, overlays and old maps.
struct LayersSheet: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Map layers").tm(.headline, p)
                ForEach(TileSources.builtIns()) { s in
                    let missing = s.requiresKey && TileLoader.shared.apiKey(for: s) == nil
                    let packs = FeatureHooks.packCount?(s) ?? 0
                    let subtitle = missing ? "Needs your \(s.keyKind.label)" : (packs > 0 ? "\(packs) offline pack\(packs > 1 ? "s" : "")" : nil)
                    ListItemRow(title: s.name, subtitle: subtitle, icon: .map, badge: prefs.baseSourceId == s.id ? "On map" : nil, info: s.note) {
                        if missing {
                            AppModel.shared.choose(s.name, s.note, options: [("Add key", { dismiss(); Navigator.shared.open(.settings) })])
                        } else {
                            prefs.baseSourceId = s.id
                            dismiss()
                        }
                    }
                }
                SectionLabel("Overlays")
                TMCard {
                    TMToggle(label: "Steep ground (25° and steeper)", isOn: $prefs.showSteepGround)
                    TMToggle(label: "LiDAR hill shading and crags (England)", isOn: $prefs.showLidar)
                    TMToggle(label: "Offline areas", isOn: $prefs.showOfflineAreas)
                    HelpRow(summary: "Terrain and saved-map coverage.",
                            detail: "LiDAR shows 1 m detail of the ground in England, with crags in dark red. It loads when you zoom in close with signal, stays on the phone, and route offline maps save it along the route.")
                }
                TMButton("Old maps", icon: .layers, style: .tonal) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MapScreenState.shared.showOldMaps = true }
                }
            }
            .padding(20)
        }
        .background(p.bg)
        .onChange(of: prefs.showSteepGround) { _, _ in FeatureHooks.refreshTerrainOverlays?() }
        .onChange(of: prefs.showLidar) { _, _ in FeatureHooks.refreshTerrainOverlays?() }
    }
}

/// Old maps (MapScreen.chooseOldMap): a scanned OS series faded over today's map.
struct OldMapsSheet: View {
    @Environment(\.palette) private var p
    @ObservedObject private var prefs = Prefs.shared
    @State private var percent: Double = 55

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Old maps").tm(.headline, p)
                Text("Fade a scanned Ordnance Survey map over today's map to find what has gone.").tm(.caption, p)
                if prefs.mapTilerKey.isEmpty {
                    TMBanner(message: "Old maps need your own free MapTiler key. Add it in Settings.")
                    TMButton("Add MapTiler key", style: .tonal) { Navigator.shared.open(.settings) }
                }
                ForEach(TileSources.historic()) { s in
                    ListItemRow(title: s.name.replacingOccurrences(of: TileSources.oldMapPrefix, with: ""), subtitle: nil, icon: .map,
                                badge: prefs.historicOverlayId == s.id ? "Showing" : nil, info: s.note) {
                        prefs.historicOverlayId = prefs.historicOverlayId == s.id ? "" : s.id
                    }
                }
                if !prefs.historicOverlayId.isEmpty {
                    Text("Old map shows \(Int(percent)) %").tm(.label, p)
                    Slider(value: $percent, in: 10...100, step: 5) { _ in prefs.historicOverlayPercent = Int(percent) }.tint(p.primary)
                    ActionRow {
                        TMButton("Forest of Dean", icon: .myLocation, style: .tonal) {
                            MapController.shared.centerOn(LatLon(TileSources.forestOfDeanLat, TileSources.forestOfDeanLon), zoom: TileSources.forestOfDeanZoom)
                        }
                        TMButton("Remove old map", style: .outlined) { prefs.historicOverlayId = "" }
                    }
                }
                Text(TileSources.nlsAttribution).tm(.caption, p)
            }
            .padding(20)
        }
        .background(p.bg)
        .onAppear { percent = Double(prefs.historicOverlayPercent) }
    }
}

enum OSLogo {
    static let image: UIImage? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return UIImage(named: "os_logo_maps", in: bundle, compatibleWith: nil)
    }()
}
