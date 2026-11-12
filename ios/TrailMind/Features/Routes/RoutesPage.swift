import SwiftUI

/// The route library (Pages.kt RoutesPage): every route with its distance, climb, high point and walking time, the one
/// being followed marked as such; find, plan or import routes; select several to delete, the followed one protected.
struct RoutesPage: View {
    @Environment(\.palette) private var p
    @StateObject private var model = RouteListModel()
    @ObservedObject private var prefs = Prefs.shared
    @State private var importing = false

    init() {}

    var body: some View {
        PageScaffold("Routes") {
            TMButton("Find", icon: .route, style: .tonal) { Navigator.shared.push(RoutesFeature.finderRoute()) }
            TMButton("Plan", icon: .map, style: .tonal) { RoutePlanner.shared.startPlan(nil) }
            TMButton("Import", icon: .upload, style: .tonal) { importing = true }
        } content: {
            content
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: RouteImport.contentTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { RouteImport.shared.importFile(url) }
            case .failure(let e): AppModel.shared.info("Import failed", RouteErrors.message(e))
            }
        }
        .onAppear { model.load() }
        .onReceive(Store.shared.$revision.dropFirst().debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)) { _ in model.load() }
        .onChange(of: prefs.activeRouteId) { _, _ in model.reconcile() }
    }

    private var activeId: Int64? { prefs.activeRouteId > 0 ? prefs.activeRouteId : nil }

    @ViewBuilder private var content: some View {
        if let list = model.routes {
            if list.isEmpty {
                TMCard(spacing: 10) {
                    TMText("No routes yet", .title)
                    TMText("Find a waymarked route, plan a walk on the map, or import a GPX track or route. TrailMind shows it on the map, " +
                           "estimates timings and warns you if you stray from it.")
                    TMText("You can also open or share a .gpx file to TrailMind from the Files app or your browser.", .caption)
                    TMButton("Find routes", icon: .route) { Navigator.shared.push(RoutesFeature.finderRoute()) }
                    TMButton("Import GPX file", icon: .upload, style: .tonal) { importing = true }
                }
            } else {
                selectionBar
                if model.selection.enabled {
                    HelpRow(summary: "Select routes to remove.",
                            detail: "The route you are following is protected. Stop following it first to delete it. " +
                                "Select all includes only removable routes.")
                }
                ForEach(list) { r in row(r) }
            }
        } else {
            TMText("Loading…", .caption)
        }
    }

    /// Select, then Select all, Cancel and Delete (LibrarySelectionUi.selectionBar).
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

    @ViewBuilder private func row(_ r: RouteMeta) -> some View {
        let following = r.id == activeId
        if model.selection.enabled {
            ListItemRow(title: r.name + (following ? " (following)" : ""), selected: model.selection.ids.contains(r.id)) { model.toggle(r.id) }
                .disabled(following || model.deleting)
                .opacity(following ? 0.6 : 1)
        } else {
            ListItemRow(title: r.name,
                        subtitle: RouteText.listSubtitle(distanceM: r.distanceM, ascentM: r.ascentM, maxEleM: r.maxEleM, pace: prefs.routePace,
                                                         imperial: prefs.imperial),
                        icon: .route, badge: following ? "Following" : nil) {
                Navigator.shared.push(RoutesFeature.detailRoute(r.id))
            }
        }
    }
}

/// The route list and its selection (LibrarySelection), loaded off the main thread.
final class RouteListModel: ObservableObject {
    @Published private(set) var routes: [RouteMeta]? = nil
    @Published private(set) var deleting = false
    /// Changes whenever the selection does.
    @Published private(set) var selectionRevision = 0
    let selection = LibrarySelection()
    private var loadJob = 0

    func load() {
        loadJob += 1
        let job = loadJob
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Store.shared.routes()
            DispatchQueue.main.async {
                guard job == self.loadJob else { return }
                self.routes = list
                self.reconcile()
            }
        }
    }

    /// Routes that can be deleted: all but the one being followed.
    private var eligible: [Int64] {
        let active = Prefs.shared.activeRouteId
        return (routes ?? []).filter { $0.id != active }.map(\.id)
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
        let ids = selection.ids.subtracting([Prefs.shared.activeRouteId])
        if ids.isEmpty {
            AppModel.shared.toast("Select a route that you are not following.")
            return
        }
        AppModel.shared.confirm("Delete \(ids.count) routes?",
                                "Permanently delete these routes from this phone? Export any you want to keep first. " +
                                    "Recorded hikes and offline maps are kept.",
                                ok: "Delete", danger: true) { [weak self] in
            guard let self else { return }
            self.deleting = true
            self.selectionRevision &+= 1
            DispatchQueue.global(qos: .userInitiated).async {
                let count = Store.shared.deleteRoutes(ids)
                ids.forEach { RouteFiles.deleteSaved($0) }
                DispatchQueue.main.async {
                    self.deleting = false
                    if count > 0 {
                        self.selection.cancel()
                        AppModel.shared.toast("Deleted \(count) routes")
                    } else {
                        AppModel.shared.toast("Could not finish deleting routes. Recheck the list and try again.")
                    }
                    self.selectionRevision &+= 1
                    self.load()
                }
            }
        }
    }
}
