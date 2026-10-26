import SwiftUI
import MapKit

private enum Destination: String, CaseIterable, Identifiable {
    case map = "Map", safety = "Safety", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .map: return "map"
        case .safety: return "location.circle"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var location: LocationService
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("menuOpacity") private var opacity = 0.92
    @AppStorage("mapLayer") private var layerID = MapLayer.osOutdoor.rawValue
    @State private var destination: Destination? = .map
    @State private var tracking: MapTracking = .none
    @State private var recentre = 0
    @State private var osKey: String? = OSKeyStore.load()
    @State private var keyDraft = ""
    @State private var tileProblem: String?

    private var layer: MapLayer { MapLayer(rawValue: layerID) ?? .osOutdoor }
    private var missingKey: Bool { layer.requiresKey && osKey == nil }

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $destination) { item in
                NavigationLink(value: item) { Label(item.rawValue, systemImage: item.symbol) }
            }
            .navigationTitle("TrailMind")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground).opacity(opacity))
        } detail: {
            switch destination ?? .map {
            case .map: map
            case .safety: safety
            case .settings: settings
            }
        }
        .onAppear { location.setForeground(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in location.setForeground(phase == .active) }
    }

    private var map: some View {
        TrailMapView(layer: layer, apiKey: osKey, tracking: $tracking, recentre: recentre) { status in
            switch status {
            case 401?, 403?: tileProblem = "OS rejected the API key. Check it in Settings and that the OS Maps API is on in your Data Hub project."
            case 429?: tileProblem = "OS Maps API rate limit reached. Try again shortly."
            case let code?: tileProblem = "Map tiles failed (HTTP \(code))."
            case nil: tileProblem = "Map tiles could not be downloaded. Check your connection."
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottomLeading) { credits }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if missingKey {
                    Button { destination = .settings } label: {
                        Label("Add your OS Data Hub API key in Settings to show OS Maps", systemImage: "key")
                    }
                    .font(.caption)
                } else if let tileProblem {
                    Text(tileProblem).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Menu {
                        Picker("Map", selection: $layerID) {
                            ForEach(MapLayer.allCases) { Text($0.name).tag($0.rawValue) }
                        }
                    } label: { Label(layer.name, systemImage: "square.3.layers.3d") }
                    Button {
                        location.requestLocation()
                        tracking = .follow
                        recentre += 1
                    } label: { Label("Locate", systemImage: "location") }
                    Button {
                        location.requestLocation()
                        tracking = tracking == .followHeading ? .follow : .followHeading
                    } label: {
                        Label(tracking == .followHeading ? "Heading up" : "North up", systemImage: "location.north.line")
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.callout)
                Text(location.message).font(.caption)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding()
            .padding(.bottom, 28)
        }
        .onChange(of: layerID) { _, _ in tileProblem = nil }
        .navigationTitle("Map")
    }

    /// OS branding asks for the OS logo on the map, with the copyright statement.
    @ViewBuilder private var credits: some View {
        if let text = layer.attribution() {
            HStack(alignment: .bottom, spacing: 6) {
                if layer.isOrdnanceSurvey, let logo = OSLogo.image {
                    Image(uiImage: logo).accessibilityLabel("Ordnance Survey")
                }
                if let url = layer.termsURL {
                    Link(text, destination: url).font(.caption2)
                } else {
                    Text(text).font(.caption2)
                }
            }
            .padding(6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, 8)
            .padding(.bottom, 4)
        }
    }

    private var safety: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your location").font(.largeTitle)
                Text("Preview only. Carry a map and compass; never rely on this build for an emergency.")
                    .foregroundStyle(.red)
                Text(location.message)
                if let text = location.shareText {
                    Text(text).textSelection(.enabled)
                    ShareLink(item: text) { Label("Share location", systemImage: "square.and.arrow.up") }
                }
                Button("Refresh location") { location.requestLocation() }
                Text("In the UK, call 999 or 112 and ask for Police, then Mountain Rescue.")
                Link("Open dialler: 999", destination: URL(string: "tel:999")!)
                DisclosureGroup("Location telemetry") {
                    if let fix = location.fix {
                        Text("Horizontal accuracy: +/-\(Int(fix.horizontalAccuracy)) m")
                        if fix.verticalAccuracy >= 0 {
                            Text("Altitude: \(Int(fix.altitude)) m; vertical accuracy +/-\(Int(fix.verticalAccuracy)) m")
                        }
                        if fix.speed >= 0 { Text("Speed: \(fix.speed, specifier: "%.1f") m/s") }
                    }
                    Text("Public iOS Core Location APIs do not expose GNSS satellite counts or azimuth/elevation. No simulated satellite sky plot is shown.")
                }
            }
            .padding()
        }
        .navigationTitle("Safety")
    }

    private var settings: some View {
        Form {
            Section {
                Picker("Map", selection: $layerID) {
                    ForEach(MapLayer.allCases) { Text($0.name).tag($0.rawValue) }
                }
            } header: { Text("Map") } footer: {
                Text("OS Maps zooms 17 and closer are OS Premium data: they use your plan's allowance and are not stored on the phone. OpenStreetMap is for browsing only.")
            }
            Section {
                if osKey == nil {
                    SecureField("OS Data Hub API key", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        if OSKeyStore.save(keyDraft) { osKey = OSKeyStore.load(); keyDraft = ""; tileProblem = nil }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Label("Key saved on this iPhone", systemImage: "checkmark.seal")
                    Button("Remove key", role: .destructive) { OSKeyStore.delete(); osKey = nil }
                }
                Link("Get a free key at OS Data Hub", destination: URL(string: "https://osdatahub.os.uk/")!)
            } header: { Text("OS Maps") } footer: {
                Text("Use your own key from a Data Hub project with the OS Maps API added. It is kept in this iPhone's Keychain and only sent to Ordnance Survey.")
            }
            Section("Appearance") {
                Slider(value: $opacity, in: 0.70...1.0, step: 0.01) {
                    Text("Menu opacity")
                }
                Text("Menu opacity: \(Int(opacity * 100))%")
                Text("Navigation adapts to the available window width, not a device model.")
                    .font(.caption)
            }
            Section("Private preview") {
                Text("Location runs only while this app is open. Map tiles come from the provider you choose. Nothing is uploaded to TrailMind servers.")
                Text("OS Explorer/Landranger (British National Grid), offline maps, GPX routes, hike recording, what3words, groups, Strava and fall alerts have not been ported to iOS yet.")
            }
        }
        .navigationTitle("Settings")
    }
}
