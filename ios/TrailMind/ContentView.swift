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
    @State private var destination: Destination? = .map
    @State private var position: MapCameraPosition = .automatic
    @State private var headingUp = false

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
        Map(position: $position) { UserAnnotation() }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Text("iPhone preview · Apple Maps · no offline hiking maps or recording yet")
                        .font(.caption)
                    HStack {
                        Button {
                            location.requestLocation()
                            position = .userLocation(followsHeading: headingUp, fallback: .automatic)
                        } label: { Label("Locate", systemImage: "location") }
                        Button {
                            headingUp.toggle()
                            location.requestLocation()
                            position = .userLocation(followsHeading: headingUp, fallback: .automatic)
                        } label: { Label(headingUp ? "Heading up" : "North up", systemImage: "location.north.line") }
                    }
                    Text(location.message).font(.caption)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding()
            }
            .navigationTitle("Map")
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
            Section("Appearance") {
                Slider(value: $opacity, in: 0.70...1.0, step: 0.01) {
                    Text("Menu opacity")
                }
                Text("Menu opacity: \(Int(opacity * 100))%")
                Text("Navigation adapts to the available window width, not a device model.")
                    .font(.caption)
            }
            Section("Private preview") {
                Text("Location runs only while this app is open. Apple Maps may request map data from Apple. Nothing is uploaded to TrailMind servers.")
                Text("OS maps, GPX routes, hike recording, what3words, groups, Strava and fall alerts have not been ported to iOS.")
                Text("This starter needs its first Xcode build and device validation before distribution.")
            }
        }
        .navigationTitle("Settings")
    }
}
