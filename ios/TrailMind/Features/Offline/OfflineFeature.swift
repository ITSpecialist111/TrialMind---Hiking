import Foundation
import UIKit

/// Offline maps, search, settings, onboarding, More and the dashboard. `start()` runs once at launch: it starts the
/// pack store and downloader, the outlines on the map and the renewal reminders, sets this feature's hooks and takes
/// MBTiles files opened in TrailMind.
enum OfflineFeature {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        OfflineNet.shared.start()
        OfflinePacks.shared.start()
        OfflineNotifications.shared.install()
        PackDownloader.shared.start()
        OfflineMapLayers.shared.start()

        FeatureHooks.packCount = { source in OfflinePacks.shared.packsFor(source).count }
        FeatureHooks.offlineHere = { _ in openOffline(routeId: nil) }
        FeatureHooks.offlineForRoute = { id in openOffline(routeId: id) }
        FeatureHooks.openSearch = { Navigator.shared.push(SearchPage.route) }
        FeatureHooks.routeMapCoverage = { route, done in
            let base = OfflineSources.base(Prefs.shared)
            OfflinePacks.shared.queue.async {
                let coverage = OfflinePacks.shared.routeCoverage(route, base: base)
                DispatchQueue.main.async { done(coverage.percent, coverage.detailUntilMs) }
            }
        }
        AppEvents.shared.urlHandlers.append { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "mbtiles" else { return false }
            OfflinePacks.shared.importAndReport(url)
            return true
        }
        // Start-up housekeeping (TileProvider.trimDiskCache and PremiumRenewal.reschedule at launch).
        DispatchQueue.global(qos: .utility).async {
            TileCache.trim()
            OfflineNotifications.shared.reschedule()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            OfflineNotifications.shared.reschedule()
        }
    }

    /// Shows the Offline page ready to download the visible map (nil) or a route's corridor.
    static func openOffline(routeId: Int64?) {
        OfflineRequests.shared.pending = OfflineRequests.Request(routeId: routeId)
        Navigator.shared.open(.offline)
    }

    /// Draws an imported map over the base map and shows where it is.
    static func showImported(_ packId: Int64) {
        Prefs.shared.offlineMapSourceId = "pack:\(packId)"
        if let bounds = OfflinePacks.shared.snapshot().first(where: { $0.id == packId })?.bounds {
            MapController.shared.fit(bounds)
        }
        Navigator.shared.showMap()
    }
}

/// Requests to the Offline page from elsewhere: a route's "Offline map" picks its corridor, the map's long-press menu
/// the area on screen.
final class OfflineRequests: ObservableObject {
    static let shared = OfflineRequests()

    struct Request: Equatable {
        let id = UUID()
        let routeId: Int64?
    }

    @Published var pending: Request? = nil
}
