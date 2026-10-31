import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

/// The map tab's pane in the wide layout (Pages2.kt DashboardPage), the first thing iPhone Duo shows open: where you
/// are now, the hike recording and the route you follow, quick actions, safety and the offline maps for this map.
struct DashboardPage: View {
    @Environment(\.palette) private var p
    @ObservedObject private var location = LocationHub.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var guidance = Guidance.shared
    @ObservedObject private var recorder = HikeRecorder.shared
    @ObservedObject private var offline = OfflinePacks.shared
    @State private var pickingGpx = false

    var body: some View {
        PageScaffold("TrailMind", showBack: false) {
            nowCard
            quickActions
            if recorder.status != .idle { recordingCard }
            routeCard
            safetyCard
            offlineCard
            VStack(alignment: .leading, spacing: 8) {
                TMButton("Offline maps", icon: .download, style: .outlined, fill: true) {
                    Navigator.shared.push(PageRoute("offline") { OfflinePage() })
                }
                TMButton("Briefing", icon: .sparkle, style: .outlined, fill: true) {
                    if let briefing = FeatureHooks.openBriefing {
                        briefing(prefs.activeRouteId > 0 ? prefs.activeRouteId : nil)
                    } else {
                        Navigator.shared.open(.assist)
                    }
                }
            }
            HelpRow(summary: "Map shortcuts",
                    detail: "Long-press the map to set a go-to point. Tap the GPS chip for your grid reference and safety tools.")
        }
    }

    // MARK: Now

    @ViewBuilder private var nowCard: some View {
        let imperial = prefs.imperial
        TMCard(spacing: 6) {
            TMText("Now", .label)
            if let f = location.latest {
                let here = f.latLon
                TMText(OsGrid.fromWgs84(here)?.format(8) ?? Units.latLon(f.lat, f.lon), .title)
                let sun = Sun.today(here)
                TMText("±" + Units.distance(Double(f.accuracyM), imperial: imperial) +
                       (f.altitudeM.map { " · " + Units.elevation($0, imperial: imperial) } ?? "") +
                       " · sunset " + (sun.sunsetMs.map { OfflineText.clock($0) } ?? "—"), .caption)
            } else if !location.hasPermission {
                TMText(location.authorization == .notDetermined ? "Location is off." : "TrailMind has no location access.", .caption)
                TMButton(location.authorization == .notDetermined ? "Turn on location" : "Open iPhone Settings", icon: .myLocation, style: .tonal) {
                    if location.authorization == .notDetermined { MapController.shared.locate() } else { AppModel.shared.openSettings() }
                }
            } else {
                TMText("Waiting for GPS…", .caption)
            }
        }
    }

    private var quickActions: some View {
        FlowLayout(spacing: 8) {
            if let search = FeatureHooks.openSearch { TMButton("Search", icon: .search, style: .tonal, action: search) }
            TMButton("My position", icon: .myLocation, style: .tonal) { MapController.shared.locate() }
            if recorder.status == .idle {
                TMButton("Start hike", icon: .play) { HikeRecorder.shared.startRecording() }
            }
        }
    }

    // MARK: Recording

    @ViewBuilder private var recordingCard: some View {
        let paused = recorder.status == .paused
        let imperial = prefs.imperial
        TMCard(spacing: 8) {
            TMText(paused ? "Paused" : "Recording", .label)
            TMText(recorder.hikeName, .title)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                StatGrid(items: [
                    ("Time", Units.duration(recorder.activeMs)),
                    ("Distance", Units.distance(recorder.track.distanceM, imperial: imperial)),
                    ("Ascent", "↑" + Units.elevation(recorder.track.ascentM, imperial: imperial)),
                ])
            }
            ActionRow {
                TMButton(paused ? "Resume" : "Pause", icon: paused ? .play : .pause, style: .tonal) {
                    if paused { HikeRecorder.shared.resume() } else { HikeRecorder.shared.pause() }
                }
                TMButton("Finish", icon: .stop, style: .danger) { HikeRecorder.shared.confirmFinish() }
            }
        }
    }

    // MARK: Route

    @ViewBuilder private var routeCard: some View {
        let imperial = prefs.imperial
        if let route = guidance.core.active {
            TMCard(spacing: 8) {
                TMText("Following", .label)
                TMText(route.name, .title)
                StatGrid(items: [
                    ("Distance", Units.distance(route.guide.totalM, imperial: imperial)),
                    ("Ascent", "↑" + Units.elevation(route.estimate.ascentM, imperial: imperial)),
                    ("Plan", Units.minutes(route.estimate.planningMinutes)),
                ])
                HikeProfileChart(points: route.points, imperial: imperial, cursorM: guidance.core.fix?.alongM)
                if let line = guidance.daylightLine() { TMText(line, .caption) }
                if route.isTracBack {
                    TMButton("Stop retracing", icon: .close, style: .tonal) { Guidance.shared.stopFollowing() }
                } else if let open = FeatureHooks.openRouteDetail {
                    TMButton("Route details", icon: .route, style: .tonal) { open(route.id) }
                }
            }
        } else {
            TMCard(spacing: 10) {
                TMText("No route loaded", .title)
                TMText("Import a GPX to follow it, or just start recording.", .caption)
                TMButton("Import GPX", icon: .upload) { pickingGpx = true }
            }
            .fileImporter(isPresented: $pickingGpx, allowedContentTypes: Self.gpxTypes) { result in
                if case .success(let url) = result { Self.openGpx(url) }
            }
        }
    }

    private static let gpxTypes: [UTType] = [UTType("com.topografix.gpx"), UTType(filenameExtension: "gpx"), .xml].compactMap { $0 }

    /// Hands a picked GPX file to the routes feature as "Open in TrailMind" does, from a copy TrailMind can read later.
    private static func openGpx(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gpx-import", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = url.pathExtension.lowercased() == "gpx" ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent + ".gpx"
        let copy = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            AppEvents.shared.open(copy)
        } catch {
            AppModel.shared.info("Import failed", error.localizedDescription)
        }
    }

    // MARK: Safety and offline maps

    @ViewBuilder private var safetyCard: some View {
        let summary = FeatureHooks.safetySummary?()
        let group = FeatureHooks.groupSummary?()
        if summary != nil || group != nil {
            TMCard(spacing: 6) {
                TMText("Safety", .label)
                if let summary { TMText(summary) }
                if let group {
                    if let openGroup = FeatureHooks.openGroup { TMChip(group, icon: .walk, action: openGroup) } else { TMText(group, .caption) }
                }
                TMButton("Safety", icon: .sos, style: .tonal) { Navigator.shared.open(.safety) }
            }
        }
    }

    @ViewBuilder private var offlineCard: some View {
        let base = OfflineSources.base(prefs)
        let packs = offline.packs.filter { $0.kind == .download && $0.sourceId == base.id }
        if let progress = offline.progress, let pack = offline.packs.first(where: { $0.id == progress.packId }) {
            TMCard(spacing: 6) {
                TMText("Downloading", .label)
                TMText(pack.name, .title)
                TMProgress(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
                TMText(progress.note.map { "\($0): \(progress.done) / \(progress.total)" }
                       ?? PackPlan.progressText(done: progress.done, total: progress.total, failed: progress.failed), .caption)
            }
        } else if !packs.isEmpty {
            TMCard(spacing: 6) {
                TMText("Offline", .label)
                TMText("\(packs.count) offline map\(packs.count == 1 ? "" : "s") of \(base.name) on this phone" +
                       (prefs.offlineOnly ? ". Offline only: no mobile data is used for maps." : "."), .caption)
            }
        }
    }
}
