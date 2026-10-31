import SwiftUI

/// The Waymarked Trails API over the network (WaymarkedTrails.kt's search, inArea, download and get). Blocking: call
/// off the main thread.
enum WaymarkedTrailsClient {
    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func get(_ url: String) throws -> RoutesJSON.Value {
        guard let request = RouteHTTP.get(url, timeout: 30) else { throw Failure(message: "Waymarked Trails could not be asked for that.") }
        let response = try RouteHTTP.shared.fetch(request, maxBytes: WaymarkedTrails.maxBytes,
                                                  tooLarge: "This route is too large to download in one piece.")
        if response.status != 200 { throw Failure(message: "Waymarked Trails answered HTTP \(response.status).") }
        return try RoutesJSON.parse(response.data)
    }

    static func search(_ query: String) throws -> [WaymarkedTrails.Trail] {
        try WaymarkedTrails.trails(get(WaymarkedTrails.searchURL(query)))
    }

    /// Routes crossing `box`, most important (international, national) first.
    static func inArea(_ box: BoundingBox) throws -> [WaymarkedTrails.Trail] {
        try WaymarkedTrails.trails(get(WaymarkedTrails.areaURL(box)))
    }

    /// The route's line, with Waymarked Trails' heights when it is short enough for them.
    static func download(_ trail: WaymarkedTrails.Trail) throws -> WaymarkedTrails.Download {
        let details = try get(WaymarkedTrails.detailsURL(trail.id))
        let lengthM = try WaymarkedTrails.lengthM(details: details)
        let heights = WaymarkedTrails.wantsHeights(lengthM: lengthM)
            ? (try? WaymarkedTrails.heights(get(WaymarkedTrails.elevationURL(trail.id)))) : nil
        return try WaymarkedTrails.download(details: details, heights: heights, trail: trail)
    }

    /// Network failures in the finder's words.
    static func friendly(_ e: Error) -> String {
        RouteErrors.isUnreachable(e) ? "Waymarked Trails could not be reached. Check your mobile data or Wi-Fi." : RouteErrors.message(e)
    }
}

/// Waymarked routes from OpenStreetMap, listed near you or found by name, added in one tap (Pages.kt RouteFinderPage).
struct RouteFinderPage: View {
    @Environment(\.palette) private var p
    @StateObject private var model: RouteFinderModel
    @ObservedObject private var prefs = Prefs.shared
    @FocusState private var typing: Bool

    init() {
        _model = StateObject(wrappedValue: RouteFinderModel())
    }

    /// The page for a model kept by its page route, so its results are still there on coming back to it.
    init(model: RouteFinderModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        PageScaffold("Find routes") {
            HStack(alignment: .center, spacing: 8) {
                TMField(hint: "Route name, e.g. Offa's Dyke", text: $model.query)
                    .focused($typing)
                    .submitLabel(.search)
                    .onSubmit { submit() }
                TMButton("Search", style: .tonal) { submit() }
            }
            FlowLayout(spacing: 8) {
                TMChip("Near me", selected: model.mode == .nearMe) { model.load(.nearMe) }
                TMChip("In map view", selected: model.mode == .mapView) { model.load(.mapView) }
            }
            results
            TMText(RouteText.finderNote, .caption)
        }
        .disabled(model.adding != nil)
        .overlay { if let trail = model.adding { addingCard(trail) } }
        .onAppear { if model.results == nil && model.error == nil && !model.loading { model.load(.nearMe) } }
    }

    @ViewBuilder private var results: some View {
        if let error = model.error {
            TMBanner(message: error)
        } else if let list = model.results {
            if list.isEmpty {
                TMText(RouteText.finderEmpty(model.mode, searched: model.searched), .caption)
            } else {
                SectionLabel(RouteText.finderHeading(model.mode, searched: model.searched, noFix: model.noFix, imperial: prefs.imperial))
                ForEach(list) { t in
                    ListItemRow(title: t.name, subtitle: RouteText.finderSubtitle(t), icon: .route) { model.add(t) }
                }
            }
        } else {
            TMText(RouteText.finderLoading(model.mode), .caption)
        }
    }

    /// The download in progress, over the page (Android's progress dialog).
    private func addingCard(_ trail: WaymarkedTrails.Trail) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            TMCard(padding: 20, spacing: 12) {
                TMText(trail.name, .title)
                HStack(spacing: 12) {
                    ProgressView().tint(p.primary)
                    TMText("Downloading the route…", .body)
                }
            }
            .frame(maxWidth: 360)
            .padding(24)
        }
        .accessibilityElement(children: .combine)
    }

    private func submit() {
        typing = false
        model.load(.search)
    }
}

/// What the finder is showing, and adding a route.
final class RouteFinderModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var mode: RouteFinderMode = .nearMe
    @Published private(set) var searched = ""
    @Published private(set) var results: [WaymarkedTrails.Trail]? = nil
    @Published private(set) var error: String? = nil
    @Published private(set) var noFix = false
    @Published private(set) var loading = false
    @Published private(set) var adding: WaymarkedTrails.Trail? = nil
    private var job = 0

    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func load(_ m: RouteFinderMode) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if m == .search && q.count < 2 {
            AppModel.shared.toast("Type at least two letters of the route name")
            return
        }
        mode = m
        if m == .search { searched = q }
        let fix = LocationHub.shared.latest
        noFix = m == .nearMe && fix == nil
        let area: BoundingBox?
        if m == .search {
            area = nil
        } else if m == .nearMe, let fix {
            area = BoundingBox(fix.lat, fix.lon, fix.lat, fix.lon).expandedByMetres(RouteText.nearM)
        } else {
            area = RouteMap.visibleBox()
        }
        job += 1
        let id = job
        results = nil
        error = nil
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> [WaymarkedTrails.Trail] in
                if let area { return try WaymarkedTrailsClient.inArea(area) }
                return try WaymarkedTrailsClient.search(q)
            }
            DispatchQueue.main.async {
                guard id == self.job else { return }
                self.loading = false
                switch result {
                case .success(let list): self.results = list
                case .failure(let e): self.error = WaymarkedTrailsClient.friendly(e)
                }
            }
        }
    }

    func add(_ t: WaymarkedTrails.Trail) {
        guard adding == nil else { return }
        adding = t
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> (download: WaymarkedTrails.Download, id: Int64) in
                let d = try WaymarkedTrailsClient.download(t)
                guard let id = Store.shared.insertRoute(name: d.name, points: d.points, waypoints: []) else {
                    throw Failure(message: "Could not save the route on this phone.")
                }
                return (d, id)
            }
            DispatchQueue.main.async {
                self.adding = nil
                switch result {
                case .success(let r):
                    AppModel.shared.toast(RouteText.finderAdded(hasElevation: r.download.hasElevation, lengthM: r.download.lengthM,
                                                                imperial: Prefs.shared.imperial))
                    Navigator.shared.push(RoutesFeature.detailRoute(r.id))
                case .failure(let e):
                    AppModel.shared.info("Could not add the route", WaymarkedTrailsClient.friendly(e))
                }
            }
        }
    }
}
