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
        RoutePlanner.shared.start()
        RouteImport.shared.start()
        FeatureHooks.startPlan = { at in RoutePlanner.shared.startPlan(at) }
        FeatureHooks.groundHeight = { at, done in RouteMap.groundHeight(at, done) }
        FeatureHooks.showOldMap = { box, at in RouteMap.showOldMap(box: box, at: at) }
        FeatureHooks.refreshTerrainOverlays = { TerrainOverlays.shared.refresh() }
        FeatureHooks.openRouteDetail = { id in openDetail(id) }
        AppEvents.shared.urlHandlers.append { url in RouteImport.shared.handle(url) }
    }

    static func detailRoute(_ id: Int64) -> PageRoute {
        PageRoute("route-detail-\(id)") { RouteDetailPage(routeId: id) }
    }

    static func finderRoute() -> PageRoute {
        PageRoute("route-finder") { RouteFinderPage() }
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
}
