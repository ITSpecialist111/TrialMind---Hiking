import Combine
import SwiftUI

/// The routes feature: the route library, finder and pages, the planner, GPX import, route checks and the terrain
/// layers. `start()` runs once at launch: it starts the feature's services, sets its hooks and handles .gpx files opened
/// in TrailMind.
enum RoutesFeature {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        RouteNetwork.shared.start()
        LidarService.shared.start()
        RouteFollow.shared.start()
        TerrainOverlays.shared.start()
        RoutePlanner.shared.startService()
        RouteImport.shared.start()
        FeatureHooks.startPlan = { at in RoutePlanner.shared.startPlan(at) }
        FeatureHooks.groundHeight = { at, done in RouteMap.groundHeight(at, done) }
        FeatureHooks.showOldMap = { box, at in RouteMap.showOldMap(box: box, at: at) }
        FeatureHooks.refreshTerrainOverlays = { TerrainOverlays.shared.refresh() }
        FeatureHooks.openRouteDetail = { id in openDetail(id) }
        // Offline packs save terrain heights and 1 m LiDAR along a route through these services.
        FeatureHooks.saveTerrainTiles = { tiles, isCancelled in
            let r = TerrainService.shared.download(AnySequence(tiles), cancelled: isCancelled)
            return (saved: r.saved, unavailable: r.failed)
        }
        FeatureHooks.lidarMissing = { squares in LidarService.shared.missing(squares) }
        FeatureHooks.saveLidarSquares = { squares, isCancelled, progress in
            let r = LidarService.shared.download(squares, cancelled: isCancelled, progress: progress)
            return (saved: r.ok, failed: r.failed)
        }
        AppEvents.shared.urlHandlers.append { url in RouteImport.shared.handle(url) }
    }

    /// A route's page. Its model lives as long as the page is in the stack, so coming back to it (from Settings, or a
    /// page opened from it) finds it as it was left, as Android keeps its pages.
    static func detailRoute(_ id: Int64) -> PageRoute {
        let model = RouteDetailModel(routeId: id)
        return PageRoute("route-detail-\(id)") { RouteDetailPage(model: model) }
    }

    /// The route finder, keeping its results while it is in the stack (back from a route it added).
    static func finderRoute() -> PageRoute {
        let model = RouteFinderModel()
        return PageRoute("route-finder") { RouteFinderPage(model: model) }
    }

    /// Shows a route's page on the Routes tab (after importing, saving a plan, or from another feature).
    static func openDetail(_ id: Int64) {
        Navigator.shared.open(.routes, detailRoute(id))
    }

    /// The base map, as the map shows it (MapScreen.currentSource).
    static func currentSource() -> TileSource {
        let all = TileSources.builtIns()
        return all.first { $0.id == Prefs.shared.baseSourceId } ?? all[0]
    }

    /// A GPX file name from a route's name, short enough that the extension survives AppModel's file-name limit.
    static func gpxFileName(_ name: String) -> String {
        String(AppModel.safeFileName(name).prefix(56)) + ".gpx"
    }

    static func gpx(_ d: RouteData) -> String {
        var out = ""
        GpxWriter.writeRoute(&out, d.meta.name, d.points, waypoints: d.waypoints)
        return out
    }

    // MARK: Other features' pages, through their hooks

    /// "Offline map" for a route (Android's `OfflinePage(host, routeId)`): the Offline page ready to save the route's
    /// corridor, or else the area round the route.
    static func openOffline(_ routeId: Int64, _ line: [LatLon]) {
        if let open = FeatureHooks.offlineForRoute { return open(routeId) }
        guard let here = FeatureHooks.offlineHere, let box = BoundingBox.of(line) else { return Navigator.shared.open(.offline) }
        RouteMap.fit(box)
        // Once the map has moved, so the Offline page offers the area round the route.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { here(box.center) }
    }

    /// Beacon's briefing for a route (Android's `AssistantPage(host, routeId)`).
    static func openBriefing(_ routeId: Int64) {
        if let open = FeatureHooks.openBriefing { open(routeId) } else { Navigator.shared.open(.assist) }
    }

    /// Settings, for the emergency contact (Android pushes SettingsPage).
    static func openSettings() {
        Navigator.shared.push(PageRoute("settings") { SettingsPage() })
    }

    /// Set or edit the check-in for a route (CheckInUi.pickCheckIn): the safety feature's dialog, then `changed` once
    /// the check-in it saves arrives in Prefs.
    static func pickCheckIn(_ routeName: String, planningMinutes: Double, routeId: Int64, changed: @escaping () -> Void) {
        if let pick = FeatureHooks.pickCheckIn {
            // @Published fires before the value is stored: hop to the next main-queue turn before refreshing.
            checkInWatch = Prefs.shared.$checkInDueMs.dropFirst().first().receive(on: DispatchQueue.main).sink { _ in
                changed()
                checkInWatch = nil
            }
            pick(routeName, planningMinutes, routeId)
        } else if let open = FeatureHooks.openCheckIn {
            open()
        } else {
            Navigator.shared.open(.safety)
        }
    }
    private static var checkInWatch: AnyCancellable?

    /// Clears the check-in of a route that was deleted (CheckIn.clear).
    static func clearCheckIn() {
        if let clear = FeatureHooks.clearCheckIn { return clear() }
        let prefs = Prefs.shared
        prefs.checkInDueMs = 0
        prefs.checkInRoute = ""
        prefs.checkInRouteId = 0
        prefs.checkInStage = 0
    }

    /// A stretch the LiDAR check found, on the map with LiDAR shading (RouteDetailPage.showOnMap).
    static func showLidarStretch(_ routeId: Int64, _ points: [LatLon], _ s: LidarSection, crag: Bool) {
        RouteMap.showLidarLayer()
        let stretch = LidarCheckPlan.stretch(points, s.startM, s.endM)
        RouteFollow.shared.show(routeId, at: s.at, zoom: 17) { RouteMap.showStretch(stretch, crag: crag) }
    }
}
