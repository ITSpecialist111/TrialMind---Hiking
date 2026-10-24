import SwiftUI

@main
struct TrailMindApp: App {
    @StateObject private var location = LocationService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(location)
                .tint(Color(red: 31.0 / 255, green: 91.0 / 255, blue: 69.0 / 255))
        }
    }
}
