import Charts
import SwiftUI

// MARK: - Hikes

/// The hike library (Pages.kt HikesPage): totals, every hike with its date, distance, time and climb, the one recording
/// marked as such, and selection to delete finished hikes. Recording, paused and unfinished hikes are protected from
/// bulk deletion.
struct HikesPage: View {
    @StateObject private var model = HikeListModel()
    @ObservedObject private var recorder = HikeRecorder.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        PageScaffold("Hikes") {
            content
        }
        .onAppear { model.load() }
        .onReceive(Store.shared.$revision.dropFirst().debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)) { _ in model.load() }
        .onChange(of: recorder.hikeId) { _, _ in model.reconcile() }
    }

    @ViewBuilder private var content: some View {
        let imperial = prefs.imperial
        if let list = model.hikes, !list.isEmpty {
            selectionBar
            if model.selection.enabled {
                HelpRow(summary: "Select finished hikes to remove.",
                        detail: "Recording, paused and unfinished hikes are protected from bulk deletion. Finish or manage those hikes individually.")
            }
        }
        if let list = model.hikes {
            if list.isEmpty {
                TMCard(spacing: 10) {
                    TMText("No hikes recorded yet", .title)
                    TMText("Tap Start hike on the map. TrailMind records a breadcrumb trail with GPS, even with the screen off, and saves every point immediately so nothing is lost if the phone restarts.")
                    TMButton("Go to map", icon: .map) { Navigator.shared.showMap() }
                }
            } else {
                let done = list.filter { $0.status == .done }
                TMCard {
                    StatGrid(items: [
                        ("Hikes", "\(done.count)"),
                        ("Distance", Units.distance(done.reduce(0) { $0 + $1.distanceM }, imperial: imperial)),
                        ("Ascent", "↑" + Units.elevation(done.reduce(0) { $0 + $1.ascentM }, imperial: imperial)),
                    ])
                }
                ForEach(list) { h in row(h, imperial: imperial) }
            }
        } else {
            TMText("Loading…", .caption)
        }
    }

    private var selectionBar: some View {
        let selection = model.selection
        return FlowLayout(spacing: 8) {
            if !selection.enabled {
                TMButton("Select", style: .tonal) { model.begin() }
            } else {
                TMButton("Select all", style: .tonal) { model.selectAll() }.disabled(model.deleting)
                TMButton("Cancel", style: .text) { model.cancel() }.disabled(model.deleting)
                TMButton(model.deleting ? "Deleting..." : "Delete (\(selection.ids.count))", icon: .delete, style: .danger) {
                    model.deleteSelected()
                }
                .disabled(model.deleting || selection.ids.isEmpty)
            }
        }
    }

    @ViewBuilder private func row(_ h: HikeMeta, imperial: Bool) -> some View {
        let live = h.id == recorder.hikeId
        if model.selection.enabled {
            let eligible = h.status == .done && !live
            ListItemRow(title: "\(h.name) · \(HikeTime.dateTime(h.startMs))" + (eligible ? "" : " (unfinished)"),
                        selected: model.selection.ids.contains(h.id)) { model.toggle(h.id) }
                .disabled(!eligible || model.deleting)
                .opacity(eligible ? 1 : 0.6)
        } else {
            ListItemRow(title: h.name,
                        subtitle: "\(HikeTime.dateTime(h.startMs)) · \(nb(Units.distance(h.distanceM, imperial: imperial))) · " +
                            "\(nb(Units.duration(h.durationMs))) · \(nb("↑" + Units.elevation(h.ascentM, imperial: imperial)))",
                        icon: .walk,
                        badge: live ? "Recording" : (h.status != .done ? "Unfinished" : nil)) {
                Navigator.shared.push(HikesFeature.detailRoute(h.id))
            }
        }
    }
}

/// The hike list and its selection (LibrarySelection), loaded off the main thread.
final class HikeListModel: ObservableObject {
    @Published private(set) var hikes: [HikeMeta]? = nil
    @Published private(set) var deleting = false
    /// Changes whenever the selection does.
    @Published private(set) var selectionRevision = 0
    let selection = LibrarySelection()
    private var loadJob = 0

    func load() {
        loadJob += 1
        let job = loadJob
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Store.shared.hikes()
            DispatchQueue.main.async {
                guard job == self.loadJob else { return }
                self.hikes = list
                self.reconcile()
            }
        }
    }

    /// Finished hikes that aren't recording: the only ones that can be deleted together.
    private var eligible: [Int64] {
        let live = HikeRecorder.shared.hikeId
        return (hikes ?? []).filter { $0.status == .done && $0.id != live }.map(\.id)
    }

    func reconcile() {
        selection.reconcile(eligible)
        selectionRevision &+= 1
    }

    func begin() {
        selection.begin()
        selectionRevision &+= 1
    }

    func cancel() {
        selection.cancel()
        selectionRevision &+= 1
    }

    func selectAll() {
        selection.selectAll(eligible)
        selectionRevision &+= 1
    }

    func toggle(_ id: Int64) {
        selection.toggle(id)
        selectionRevision &+= 1
    }

    func deleteSelected() {
        let ids = selection.ids.intersection(eligible)
        if ids.isEmpty {
            AppModel.shared.toast("Select a finished hike.")
            return
        }
        AppModel.shared.confirm("Delete \(ids.count) hikes?",
                                "Permanently delete these hikes and GPS tracks from this phone? Export them first if needed. This does not delete copies on Strava or exported GPX files. An upload already in progress may finish.",
                                ok: "Delete", danger: true) { [weak self] in
            guard let self else { return }
            self.deleting = true
            DispatchQueue.global(qos: .userInitiated).async {
                let count = Store.shared.deleteFinishedHikes(ids)
                DispatchQueue.main.async {
                    self.deleting = false
                    if count > 0 {
                        self.selection.cancel()
                        self.selectionRevision &+= 1
                        MapController.shared.clearShownTrack()
                        AppModel.shared.toast("Deleted \(count) hikes")
                    } else {
                        AppModel.shared.toast("Could not delete hikes. No success was confirmed; check the list and retry.")
                    }
                    self.load()
                }
            }
        }
    }
}

// MARK: - Hike detail

/// One hike (Pages.kt HikeDetailPage): statistics, elevation profile, show on the map, GPX export, Strava, rename and
/// delete.
struct HikeDetailPage: View {
    @Environment(\.palette) private var p
    @StateObject private var model: HikeDetailModel
    @ObservedObject private var recorder = HikeRecorder.shared
    @ObservedObject private var prefs = Prefs.shared

    init(hikeId: Int64) {
        _model = StateObject(wrappedValue: HikeDetailModel(hikeId: hikeId))
    }

    var body: some View {
        Group {
            if let h = model.meta {
                detail(h)
            } else {
                PageScaffold("Hike") {
                    TMText(model.loaded ? "This hike no longer exists." : "Loading…", .caption)
                }
            }
        }
        .onAppear { model.load() }
        .onReceive(Store.shared.$revision.dropFirst().debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)) { _ in model.load() }
    }

    private func detail(_ h: HikeMeta) -> some View {
        let imperial = prefs.imperial
        let all = model.points
        let live = h.id == recorder.hikeId
        let avg = h.movingMs > 0 ? h.distanceM / (Double(h.movingMs) / 1000.0) : 0.0
        return PageScaffold(h.name) {
            if live { TMBanner(message: "This hike is still being recorded. Finish it from the map to finalise the stats.") }
            TMText(HikeTime.dateTime(h.startMs) + (h.endMs.map { " – " + HikeTime.time($0) } ?? ""), .caption)
            TMCard {
                StatGrid(items: [
                    ("Distance", Units.distance(h.distanceM, imperial: imperial)),
                    ("Time", Units.duration(h.durationMs)),
                    ("Moving", Units.duration(h.movingMs)),
                    ("Ascent", "↑" + Units.elevation(h.ascentM, imperial: imperial)),
                    ("Descent", "↓" + Units.elevation(h.descentM, imperial: imperial)),
                    ("Avg moving", Units.speedKmh(avg, imperial: imperial)),
                    ("Highest", h.maxEleM.map { Units.elevation($0, imperial: imperial) } ?? "—"),
                    ("Lowest", h.minEleM.map { Units.elevation($0, imperial: imperial) } ?? "—"),
                    ("Points", "\(all.count)"),
                ])
                TMText("Ascent uses a \(Int(TrackStats.defaultElevationThresholdM)) m hysteresis to ignore GPS altitude noise; GPS altitude is typically ±10–20 m.", .caption)
            }
            TMCard(padding: 12) {
                Text("Elevation profile").tm(.label, p)
                HikeProfileChart(points: all, imperial: imperial)
            }
            if all.count >= 2 {
                TMButton("Show on map", icon: .map, style: .outlined) { showOnMap() }
            }
            TMCard(spacing: 10) {
                Text("Export").tm(.label, p)
                ActionRow {
                    TMButton("Save GPX", icon: .folder, fill: true) { AppModel.shared.saveFile(HikesFeature.gpxFileName(h.name), gpx(h)) }
                    TMButton("Share GPX", icon: .share, style: .tonal, fill: true) {
                        AppModel.shared.shareFile(HikesFeature.gpxFileName(h.name), gpx(h))
                    }
                }
            }
            stravaCard(h, live: live)
            ActionRow {
                TMButton("Rename", style: .text, fill: true) {
                    AppModel.shared.prompt("Rename hike", initial: h.name) { name in
                        if !name.isBlank { Store.shared.renameHike(h.id, name) }
                    }
                }
                if !live {
                    TMButton("Delete", icon: .delete, style: .text, fill: true) {
                        AppModel.shared.confirm("Delete hike?",
                                                "\"\(h.name)\" and its GPS track will be permanently deleted. Export it first if you want a copy.",
                                                ok: "Delete", danger: true) {
                            Store.shared.deleteHike(h.id)
                            Navigator.shared.pop()
                        }
                    }
                }
            }
        }
    }

    /// The track on the map; while another hike records only the view moves there (MapScreen.showTrack).
    private func showOnMap() {
        let segments = model.segments
        Navigator.shared.showMap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if HikeRecorder.shared.status == .idle {
                MapController.shared.showTrack(segments)
            } else {
                MapController.shared.fit(BoundingBox.of(segments.flatMap { $0 }.map { $0.latLon() }))
            }
        }
    }

    private func gpx(_ h: HikeMeta) -> String {
        var out = ""
        GpxWriter.writeTrack(&out, h.name, model.segments, description: "Recorded with TrailMind", activityType: "hiking")
        return out
    }

    // MARK: Strava

    /// Where this hike is with Strava, and what you can do about it (HikeDetailPage.stravaCard).
    private func stravaCard(_ h: HikeMeta, live: Bool) -> some View {
        let linked = prefs.hasStravaRefreshToken && !prefs.stravaNeedsReconnect
        let needsReconnect = prefs.hasStravaRefreshToken && prefs.stravaNeedsReconnect
        return TMCard(spacing: 8) {
            Text("Strava").tm(.label, p)
            if needsReconnect {
                TMText("Strava stopped accepting TrailMind, so this hike can't be posted by itself.", .caption, color: p.danger)
                if let open = FeatureHooks.openStrava { TMButton("Connect to Strava again", icon: .upload, style: .text) { open() } }
                byHand(h, live: live)
            } else if !linked {
                byHand(h, live: live)
                TMText("Automatic posting needs a Strava subscription: Strava only lets subscribers create the app that posting uses.", .caption)
                if let open = FeatureHooks.openStrava { TMButton("Set up automatic posting…", icon: .upload, style: .text) { open() } }
            } else {
                linkedCard(h, live: live)
            }
        }
    }

    /// A linked account (HikeDetailPage.stravaCard): where the post is, and posting it now through Strava.
    @ViewBuilder private func linkedCard(_ h: HikeMeta, live: Bool) -> some View {
        if let row = model.post {
            switch row.state {
            case "QUEUED":
                TMText("Waiting to post. \(row.message ?? "It goes as soon as the phone has signal.")", .caption)
                postButton("Post now", h)
            case "PROCESSING":
                TMText("Strava is processing this hike…", .caption)
            case "POSTED":
                TMText(row.activityId != nil ? "Posted to Strava ✓" : row.message ?? "On Strava ✓", .body, color: p.primary)
                if let activity = row.activityId, let url = URL(string: "https://www.strava.com/activities/\(activity)") {
                    TMButton("View on Strava", style: .tonal) { AppModel.shared.open(url) }
                }
            case "FAILED":
                TMText("Couldn't post this hike. \(row.message ?? "")", .caption, color: p.danger)
                postButton("Try again", h)
            default:
                TMText(row.message ?? "Not posted to Strava.", .caption)
                if !live { postButton("Post anyway", h) }
            }
        } else {
            TMText(live ? "You can post it once it's finished." : "Not posted to Strava.", .caption)
            if !live { postButton("Post to Strava", h) }
        }
    }

    @ViewBuilder private func postButton(_ label: String, _ h: HikeMeta) -> some View {
        if let post = FeatureHooks.stravaPostNow {
            TMButton(label, icon: .upload, style: .tonal) { post(h.id) }
        }
    }

    /// The way in that works for everyone: Strava's own upload page with the GPX saved first.
    @ViewBuilder private func byHand(_ h: HikeMeta, live: Bool) -> some View {
        if live {
            TMText("You can upload it to Strava once it's finished.", .caption)
        } else {
            TMText("Saves the GPX to Files and opens Strava's upload page. Tap Choose file, pick it, then Save.", .caption)
            TMButton("Upload to Strava", icon: .upload, style: .tonal) {
                if let upload = FeatureHooks.stravaUploadHike { upload(h.id) } else { stravaHelp(h) }
            }
        }
    }

    private func stravaHelp(_ h: HikeMeta) {
        let message = "To upload this hike to Strava:\n" +
            "1. Save the GPX (to Files, say).\n" +
            "2. Open Strava's upload page in your browser and choose the file.\n\n" +
            "The GPX includes timestamps, elevation and the activity type 'hiking'."
        AppModel.shared.choose("Upload to Strava", message, options: [
            ("Save GPX", { AppModel.shared.saveFile(HikesFeature.gpxFileName(h.name), gpx(h)) }),
            ("Open upload page", { if let url = URL(string: "https://www.strava.com/upload/select") { AppModel.shared.open(url) } }),
        ], cancel: "Close")
    }
}

/// One hike, its track and its Strava post, loaded off the main thread.
final class HikeDetailModel: ObservableObject {
    let hikeId: Int64
    @Published private(set) var meta: HikeMeta? = nil
    @Published private(set) var segments: [[TrackPoint]] = []
    @Published private(set) var post: StravaPostRow? = nil
    @Published private(set) var loaded = false
    private(set) var points: [TrackPoint] = []
    private var loadJob = 0

    init(hikeId: Int64) { self.hikeId = hikeId }

    func load() {
        loadJob += 1
        let job = loadJob
        let id = hikeId
        DispatchQueue.global(qos: .userInitiated).async {
            let meta = Store.shared.hike(id)
            let segments = meta == nil ? [] : Store.shared.hikeSegments(id)
            let post = meta == nil ? nil : Store.shared.stravaPost(id)
            DispatchQueue.main.async {
                guard job == self.loadJob else { return }
                self.points = segments.flatMap { $0 }
                self.segments = segments
                self.post = post
                self.meta = meta
                self.loaded = true
            }
        }
    }
}

// MARK: - Elevation profile

/// Distance against height (ElevationProfileView), with an optional "you are here" cursor, drawn with Swift Charts.
struct HikeProfileChart: View {
    @Environment(\.palette) private var p
    let points: [TrackPoint]
    let imperial: Bool
    var cursorM: Double? = nil

    private struct Sample: Identifiable {
        let id: Int
        let distanceM: Double
        let eleM: Double
    }

    /// At most about 600 samples, from the points that have a height, at their distance along the whole line.
    private static func samples(_ points: [TrackPoint]) -> [Sample] {
        let withEle = points.indices.filter { points[$0].ele != nil }
        if withEle.count < 2 { return [] }
        let step = max(1, withEle.count / 600)
        let cumulative = Geo.cumulativeDistances(points)
        return withEle.enumerated().filter { $0.offset % step == 0 }.map { n, i in
            Sample(id: n, distanceM: cumulative[i], eleM: points[i].ele!)
        }
    }

    var body: some View {
        let samples = Self.samples(points)
        if samples.count < 2 {
            Text("No elevation data in this GPX").tm(.caption, p)
                .frame(maxWidth: .infinity, minHeight: 140)
        } else {
            chart(samples)
        }
    }

    private func chart(_ samples: [Sample]) -> some View {
        var low = samples.map(\.eleM).min()!
        var high = samples.map(\.eleM).max()!
        if high - low < 50 {
            let mid = (high + low) / 2
            low = mid - 25
            high = mid + 25
        }
        let lo = low
        let hi = high
        let total = max(samples[samples.count - 1].distanceM, 1.0)
        let fill = LinearGradient(colors: [p.primary.opacity(0.4), p.primary.opacity(0.03)], startPoint: .top, endPoint: .bottom)
        return Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("Distance", s.distanceM), yStart: .value("Floor", lo), yEnd: .value("Height", s.eleM))
                    .foregroundStyle(fill)
                LineMark(x: .value("Distance", s.distanceM), y: .value("Height", s.eleM))
                    .foregroundStyle(p.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
            if let cursorM {
                let at = cursorM.clamped(0, total)
                RuleMark(x: .value("You", at))
                    .foregroundStyle(p.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                if let near = samples.first(where: { $0.distanceM >= at }) ?? samples.last {
                    PointMark(x: .value("You", at), y: .value("Height", near.eleM))
                        .foregroundStyle(p.accent)
                        .symbolSize(80)
                }
            }
        }
        .chartXScale(domain: 0...total)
        .chartYScale(domain: lo...hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: [lo, (lo + hi) / 2, hi]) { value in
                AxisGridLine().foregroundStyle(p.outline)
                AxisValueLabel {
                    if let e = value.as(Double.self) {
                        Text(Units.elevation(e, imperial: imperial)).font(.caption2).foregroundStyle(p.muted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: [0.0, total]) { value in
                AxisValueLabel(anchor: (value.as(Double.self) ?? 0) > 0 ? .topTrailing : .topLeading) {
                    Text((value.as(Double.self) ?? 0) > 0 ? Units.distance(total, imperial: imperial) : "0")
                        .font(.caption2).foregroundStyle(p.muted)
                }
            }
        }
        .frame(height: 140)
        .accessibilityElement()
        .accessibilityLabel("Elevation profile")
        .accessibilityValue("\(Units.distance(total, imperial: imperial)), from \(Units.elevation(samples.map(\.eleM).min()!, imperial: imperial)) to \(Units.elevation(samples.map(\.eleM).max()!, imperial: imperial))")
    }
}
