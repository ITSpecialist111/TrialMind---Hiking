import SwiftUI
import UIKit

@main
struct TrailMindApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            PaletteProvider {
                RootView()
            }
            .tint(Color(argb: 0xFF1F5B45))
            .onOpenURL { url in AppEvents.shared.open(url) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppEvents.shared.start()
        return true
    }
}

/// Launch-time wiring and incoming URLs (GPX files "Open in TrailMind", trailmind:// invites, Strava sign-in).
final class AppEvents {
    static let shared = AppEvents()
    /// Features register handlers for incoming URLs; the first that returns true has handled it.
    var urlHandlers: [(URL) -> Bool] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        TestLaunch.apply()
        #endif
        TileLoader.shared.purgeExpiredPremium()
        TileLoader.shared.onProblem = { problem in
            if problem.hasPrefix("premium:") {
                let name = problem.dropFirst("premium:".count)
                AppModel.shared.toast("\(name): your OS plan does not include closer detail, so the map enlarges the last available overview tile.")
            }
        }
        FeatureStartup.startAll()
    }

    func open(_ url: URL) {
        for handler in urlHandlers where handler(url) { return }
        AppModel.shared.toast("TrailMind can't open \(url.lastPathComponent)")
    }
}
