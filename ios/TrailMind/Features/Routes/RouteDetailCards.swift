import SwiftUI
import UIKit

/// "Ready to go?" (RouteDetailPage.readinessCard): offline map, daylight, weather, facilities, battery, location and
/// alerts, and the check-in, each ready or to check, with a button to put it right where there is one.
struct RouteReadinessCard: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: RouteDetailModel
    @ObservedObject private var prefs = Prefs.shared
    let route: RouteData
    let planningMinutes: Double
    /// The start-by line the statistics card shows.
    let startBy: String
    let nowMs: Int64

    private struct Check: Identifiable {
        let title: String
        let detail: String
        let ready: Bool
        var fix: String? = nil
        var action: (() -> Void)? = nil
        var id: String { title }
    }

    var body: some View {
        let checks = makeChecks()
        TMCard(spacing: 6) {
            TMText("Ready to go?", .title)
            TMText(TripReadiness.summary(ready: checks.filter(\.ready).count, total: checks.count), .body)
            ForEach(checks) { check in
                TMText("\(check.ready ? "Ready" : "Check") · \(check.title): \(check.detail)", .caption)
                if let fix = check.fix, let action = check.action {
                    TMButton(fix, style: .text, action: action)
                }
            }
            if prefs.emergencyContact.isBlank {
                TMButton("Save emergency contact", icon: .tune, style: .text) { RoutesFeature.openSettings() }
            }
            if let url = URL(string: RouteWeather.url) { TMLink(label: RouteWeather.attribution, url: url) }
        }
    }

    private func makeChecks() -> [Check] {
        let imperial = prefs.imperial
        let id = route.meta.id
        let source = RoutesFeature.currentSource()
        let needsSignal = RouteReadiness.needsSignal(source)
        let coverage = model.coverageSourceId == source.id ? model.mapCoverage : nil
        let untilMs = model.coverageSourceId == source.id ? model.mapCoverageUntilMs : nil
        let explorerExpired = source.id == TileSources.osLeisure && (untilMs.map { $0 <= nowMs } ?? false)
        let currentCoverage = explorerExpired ? 0 : coverage
        let canDownload = RouteReadiness.canDownload(source)
        let map = RouteText.mapCheck(source: source, needsSignal: needsSignal, coverage: coverage, untilMs: untilMs, nowMs: nowMs,
                                     dateTime: RouteFormat.shortDateTime)
        let offerDownload = canDownload && currentCoverage != 100
        let line = route.points.map { $0.latLon() }

        let high = model.highPoint(prefs.routePace)
        let weather = RouteText.weatherCheck(high: high, forecast: model.forecast, nowMs: nowMs, imperial: imperial)
        let canFetch = high != nil && !model.fetchingWeather

        let threshold = RouteText.batteryThreshold(planningMinutes: planningMinutes)
        let location = LocationHub.shared.hasPermission && model.locationServicesOn
        let alerts = model.alertsAllowed ?? false
        let checkIn = RouteText.checkInDetail(dueMs: prefs.checkInDueMs, nowMs: nowMs, contact: !prefs.emergencyContact.isBlank,
                                              alerts: alerts, clock: RouteFormat.clock)
        let due = prefs.checkInDueMs

        return [
            Check(title: "Offline map", detail: map.detail, ready: map.ready, fix: offerDownload ? "Download route corridor" : nil,
                  action: offerDownload ? { RoutesFeature.openOffline(id, line) } : nil),
            Check(title: "Daylight", detail: startBy, ready: RouteText.daylightReady(startBy)),
            Check(title: "Weather", detail: weather.detail, ready: weather.ready, fix: canFetch ? "Fetch forecast" : nil,
                  action: canFetch ? { if let high { model.fetchForecast(high) } } : nil),
            Check(title: "Facilities", detail: model.facilities != nil ? "Saved for offline use" : "Not saved for offline use",
                  ready: model.facilities != nil, fix: model.facilities == nil ? "Find facilities" : nil,
                  action: model.facilities == nil ? { model.findFacilities() } : nil),
            Check(title: "Battery", detail: RouteText.batteryDetail(level: model.batteryLevel, charging: model.charging, threshold: threshold),
                  ready: model.batteryLevel >= threshold),
            Check(title: "Location & alerts", detail: RouteText.locationDetail(location: location, alerts: alerts), ready: location && alerts,
                  fix: location && alerts ? nil : "Fix settings", action: { model.fixSettings() }),
            Check(title: "Check-in & contact", detail: checkIn.detail, ready: checkIn.ready, fix: due > 0 ? "Edit check-in" : "Set check-in",
                  action: { RoutesFeature.pickCheckIn(route.meta.name, planningMinutes: planningMinutes, routeId: id) { model.refreshDevice() } }),
        ]
    }
}

/// "Terrain check (1 m LiDAR)" (RouteDetailPage.lidarCard): steep ground and crags along the line from the Environment
/// Agency's survey, each stretch shown on the map when tapped.
struct RouteLidarCard: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: RouteDetailModel
    @ObservedObject private var checks = LidarChecks.shared
    @ObservedObject private var prefs = Prefs.shared
    let route: RouteData

    var body: some View {
        TMCard(spacing: 6) {
            TMText("Terrain check (1 m LiDAR)", .title)
            if model.lidarSquares == 0 {
                TMText("The Environment Agency's LiDAR covers England, and this route is outside it.", .caption)
            } else {
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        let id = route.meta.id
        let imperial = prefs.imperial
        let progress = checks.progress(id)
        let saved = model.lidarCheck
        if let progress {
            TMText(RouteText.lidarProgress(done: progress.done, total: progress.total), .caption)
        } else if saved == nil {
            TMText("Looks along the route for ground steep enough to need hands (35° or more over 10 m) and for crags " +
                   "within 10 m, from the Environment Agency's 1 m survey of England.", .caption)
        }
        if progress == nil, let error = checks.error(id) { TMText(error, .caption, color: p.danger) }
        if let saved, progress == nil {
            let report = saved.report
            let coverage = LidarCheckPlan.coverage(report)
            TMText("Checked \(RouteFormat.dateTime(saved.checkedMs)) · LiDAR covers \(coverage.percent)% of the route", .caption)
            if let clear = LidarCheckPlan.clearText(report) {
                TMText(clear, .body)
            } else if !coverage.full {
                TMText("Only the \(coverage.percent)% of the route that LiDAR covers was checked.", .caption)
            }
            if !report.steep.isEmpty {
                Text("Steep enough for hands: \(report.steep.count)").tm(.label, p)
                ForEach(Array(report.steep.prefix(12).enumerated()), id: \.offset) { _, s in
                    ListItemRow(title: RouteText.lidarSteepTitle(s, imperial: imperial), subtitle: RouteText.lidarSteepDetail(s, imperial: imperial)) {
                        RoutesFeature.showLidarStretch(id, route.points.map { $0.latLon() }, s, crag: false)
                    }
                }
            }
            if !report.crags.isEmpty {
                Text("Crag within 10 m: \(report.crags.count)").tm(.label, p)
                ForEach(Array(report.crags.prefix(12).enumerated()), id: \.offset) { _, s in
                    ListItemRow(title: RouteText.lidarCragTitle(s, imperial: imperial), subtitle: RouteText.lidarCragDetail(s, imperial: imperial)) {
                        RoutesFeature.showLidarStretch(id, route.points.map { $0.latLon() }, s, crag: true)
                    }
                }
            }
            TMText("Measured along the route line: a path that zigzags up a slope is less steep than the line, and the line " +
                   "can be a few metres off the path. LiDAR is the bare ground, without walls, trees or buildings. Look at the map before you rely on it.",
                   .caption)
        }
        if progress == nil {
            let online = RouteNetwork.shared.networkAllowed
            let missing = model.lidarMissing
            TMButton(saved == nil ? "Check with LiDAR" : "Check again", icon: .route, style: .tonal) { model.startLidarCheck() }
                .disabled(!(model.lidarSquares != nil && (online || missing == 0)))
            TMText(RouteText.lidarDownloadNote(squares: model.lidarSquares, missing: missing, online: online,
                                               decimalSeparator: Locale.current.decimalSeparator ?? "."), .caption)
        }
        if let url = URL(string: LidarSource.datasetURL) { TMLink(label: LidarSource.credit, url: url) }
    }
}

/// "Facilities along the way" (RouteDetailPage's facilities card): parking, toilets, water, food, transport and places
/// to stay near the route from OpenStreetMap, saved for offline use, filtered by kind, and shown on the map.
struct RouteFacilitiesCard: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: RouteDetailModel
    @ObservedObject private var overpass = OverpassFacilities.shared
    @ObservedObject private var prefs = Prefs.shared
    let route: RouteData

    /// Android lists this many before "Show all".
    private static let shown = 60

    var body: some View {
        let id = route.meta.id
        let imperial = prefs.imperial
        let saved = model.facilities
        TMCard(spacing: 8) {
            TMText("Facilities along the way", .title)
            if model.facilityCacheUnreadable {
                TMText("Saved facilities couldn't be read. Update to fetch them again.", .caption)
            } else if let saved {
                TMText("Updated \(RouteFormat.dateTime(saved.fetchedMs))", .caption)
                if saved.partial {
                    TMText("Long route or response limit: showing a limited selection of nearby facilities.", .caption)
                }
                if saved.items.isEmpty {
                    TMText(saved.partial ? "No facilities returned in the limited results." : "No mapped facilities found near this route.", .caption)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(RouteText.facilityCounts(saved.items), id: \.category) { entry in
                            TMChip("\(entry.category.label) \(entry.count)", selected: model.facilityFilter == entry.category) {
                                model.facilityFilter = model.facilityFilter == entry.category ? nil : entry.category
                            }
                        }
                    }
                    let visible = saved.items.filter { model.facilityFilter == nil || $0.category == model.facilityFilter }
                    let list = model.showAllFacilities ? visible : Array(visible.prefix(Self.shown))
                    ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                        ListItemRow(title: RouteText.facilityTitle(item), subtitle: RouteText.facilityDetail(item, imperial: imperial)) {
                            RouteFollow.shared.show(id, at: item.position, zoom: 16)
                        }
                    }
                    if !model.showAllFacilities && visible.count > Self.shown {
                        TMButton("Show all \(visible.count)", icon: .search, style: .tonal) { model.showAllFacilities = true }
                    }
                }
                TMToggle(label: "Show facilities on the map", isOn: $prefs.showFacilities)
            } else {
                TMText("Find parking, toilets, water, food, transport and places to stay near this route. Save the results for offline use.",
                       .caption)
            }
            let label = saved == nil && !model.facilityCacheUnreadable ? "Find facilities" : "Update"
            if overpass.isFetching(id) {
                TMButton("Finding facilities", icon: .search, style: .tonal) {}.disabled(true)
            } else if !overpass.online {
                TMText("Connect to the internet to find or update facilities. Saved results are still available.", .caption)
                TMButton(label, icon: .search, style: .tonal) {}.disabled(true)
            } else {
                TMButton(label, icon: .search, style: .tonal) { model.findFacilities() }
            }
            TMText(Overpass.attribution, .caption)
        }
    }
}
