import SwiftUI
import UIKit

/// One route (Pages.kt RouteDetailPage): statistics and timings, the "Ready to go?" checks, the elevation profile,
/// the LiDAR terrain check, follow or show it on the map, its offline map, briefing and old map, facilities along the
/// way, the start and waypoints, GPX export, rename and delete.
struct RouteDetailPage: View {
    @Environment(\.palette) private var p
    @StateObject private var model: RouteDetailModel
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var lidarChecks = LidarChecks.shared
    let routeId: Int64

    init(routeId: Int64) {
        self.routeId = routeId
        _model = StateObject(wrappedValue: RouteDetailModel(routeId: routeId))
    }

    /// The page for a model kept by its page route, so the page comes back as it was left.
    init(model: RouteDetailModel) {
        routeId = model.routeId
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Group {
            if let d = model.data {
                detail(d)
            } else {
                PageScaffold("Route") {
                    TMText(model.loaded ? "This route no longer exists." : "Loading…", .caption)
                }
            }
        }
        .onAppear { model.show() }
        .onDisappear { model.hide() }
        .onReceive(Store.shared.$revision.dropFirst().debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)) { _ in model.reload() }
        .onReceive(lidarChecks.$revision.dropFirst()) { _ in model.loadLidar() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.refreshDevice() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in model.readBattery() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in model.readBattery() }
        .onChange(of: prefs.activeRouteId) { _, _ in model.updateCursor() }
        // RouteDetailPage.onBaseMapChanged: the offline-map check is for the map on show.
        .onChange(of: prefs.baseSourceId) { _, _ in model.updateReadiness() }
    }

    private var following: Bool { prefs.activeRouteId == routeId }

    private func detail(_ d: RouteData) -> some View {
        let imperial = prefs.imperial
        let pace = prefs.routePace
        let est = model.estimate(pace)
        let now = nowMs()
        let startBy = RouteText.startBy(d.points, pace: pace, marginMinutes: prefs.daylightMarginMinutes, forMs: now,
                                        clock: RouteFormat.clock, finish: RouteFormat.finish)
        let line = d.points.map { $0.latLon() }
        return PageScaffold(d.meta.name) {
            TMCard {
                StatGrid(items: [
                    ("Distance", Units.distance(d.meta.distanceM, imperial: imperial)),
                    ("Ascent", "↑" + Units.elevation(d.meta.ascentM, imperial: imperial)),
                    ("Descent", "↓" + Units.elevation(d.meta.descentM, imperial: imperial)),
                    ("Naismith", Units.minutes(est.naismithMinutes)),
                    ("Tobler", Units.minutes(est.toblerMinutes)),
                    ("Highest", d.meta.maxEleM.map { Units.elevation($0, imperial: imperial) } ?? "—"),
                ])
                TMText(RouteText.planningCaption(est, flatSpeedKmh: prefs.flatSpeedKmh, conditionsFactor: prefs.conditionsFactor,
                                                 imperial: imperial), .caption)
                TMText(startBy, .body)
            }
            RouteReadinessCard(model: model, route: d, planningMinutes: est.planningMinutes, startBy: startBy, nowMs: now)
            profileCard(d, imperial: imperial)
            RouteLidarCard(model: model, route: d)
            ActionRow {
                if following {
                    TMButton("Stop following", icon: .close, style: .tonal, fill: true) { RouteFollow.shared.stopFollowing() }
                } else {
                    TMButton("Follow route", icon: .navigation, fill: true) {
                        RouteFollow.shared.follow(routeId) { r in
                            if let r { RouteMap.fit(BoundingBox.of(r.points.map { $0.latLon() })) }
                        }
                    }
                }
                TMButton("Show on map", icon: .map, style: .outlined, fill: true) {
                    if !following { RouteFollow.shared.follow(routeId) }
                    RouteMap.fit(BoundingBox.of(line))
                }
            }
            ActionRow {
                TMButton("Offline map", icon: .download, style: .tonal, fill: true) { RoutesFeature.openOffline(routeId, line) }
                TMButton("Briefing", icon: .sparkle, style: .tonal, fill: true) { RoutesFeature.openBriefing(routeId) }
            }
            TMButton("See it on an old map", icon: .layers, style: .tonal) {
                if !following { RouteFollow.shared.follow(routeId) }
                RouteMap.showOldMap(box: BoundingBox.of(line), at: nil)
            }
            RouteFacilitiesCard(model: model, route: d)
            if !d.points.isEmpty { startCard(d) }
            if !d.waypoints.isEmpty {
                SectionLabel("Waypoints")
                ForEach(Array(d.waypoints.prefix(100).enumerated()), id: \.offset) { _, w in
                    ListItemRow(title: w.name, subtitle: RouteText.waypointDetail(w, imperial: imperial)) {
                        RouteMap.centerOn(w.latLon(), zoom: 15)
                    }
                }
            }
            ActionRow {
                TMButton("Save GPX", icon: .folder, style: .outlined, fill: true) {
                    AppModel.shared.saveFile(RoutesFeature.gpxFileName(d.meta.name), RoutesFeature.gpx(d))
                }
                TMButton("Share", icon: .share, style: .outlined, fill: true) {
                    AppModel.shared.shareFile(RoutesFeature.gpxFileName(d.meta.name), RoutesFeature.gpx(d))
                }
            }
            ActionRow {
                TMButton("Rename", style: .text, fill: true) { rename(d) }
                TMButton("Delete", icon: .delete, style: .text, fill: true) { delete(d) }
            }
        }
    }

    private func profileCard(_ d: RouteData, imperial: Bool) -> some View {
        TMCard(padding: 12) {
            Text("Elevation profile").tm(.label, p)
            RouteCursorProfile(cursor: model.cursor, samples: model.profile, imperial: imperial)
            if d.meta.terrainDerived { TMText(TerrainSource.credit, .caption) }
            if !d.points.isEmpty && d.points.contains(where: { $0.ele == nil }) {
                TMButton(model.addingTerrain ? "Adding heights…" : "Add heights", icon: .add, style: .tonal) { model.addHeights() }
                    .disabled(model.addingTerrain)
            }
        }
    }

    private func startCard(_ d: RouteData) -> some View {
        let start = d.points[0].latLon()
        return TMCard(spacing: 4) {
            Text("Start").tm(.label, p)
            TMText(OsGrid.fromWgs84(start)?.format(8) ?? Units.latLon(start.lat, start.lon), .mono)
                .textSelection(.enabled)
            TMText(Units.latLon(start.lat, start.lon) + " · \(d.points.count) points · imported \(RouteFormat.dateTime(d.meta.createdMs))", .caption)
        }
    }

    private func rename(_ d: RouteData) {
        let id = routeId
        AppModel.shared.prompt("Rename route", initial: d.meta.name) { name in
            guard !name.isBlank else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                Store.shared.renameRoute(id, name)
                DispatchQueue.main.async {
                    if Prefs.shared.checkInRouteId == id { Prefs.shared.checkInRoute = name }
                    model.reload()
                }
            }
        }
    }

    private func delete(_ d: RouteData) {
        let id = routeId
        let wasFollowing = following
        AppModel.shared.confirm("Delete route?", "\"\(d.meta.name)\" will be removed. Recorded hikes are kept.", ok: "Delete", danger: true) {
            if wasFollowing { RouteFollow.shared.stopFollowing() }
            DispatchQueue.global(qos: .userInitiated).async {
                let removed = Store.shared.deleteRoutes([id]) > 0
                RouteFiles.deleteSaved(id)
                DispatchQueue.main.async {
                    if removed && Prefs.shared.checkInRouteId == id { RoutesFeature.clearCheckIn() }
                    Navigator.shared.pop()
                }
            }
        }
    }
}

/// The profile with "you are here" while the route is followed; only the chart redraws as you move.
private struct RouteCursorProfile: View {
    @ObservedObject var cursor: RouteCursor
    let samples: [RouteProfileSample]
    let imperial: Bool

    var body: some View {
        RouteProfileChart(samples: samples, imperial: imperial, cursorM: cursor.alongM)
    }
}
