import Combine
import Foundation
import UniformTypeIdentifiers

/// GPX files into the route library (MainActivity.pickGpx, importGpx and handleIntent): picked in Files, or opened or
/// shared to TrailMind from another app. A route without heights gets them from the terrain model when there is signal.
final class RouteImport {
    static let shared = RouteImport()

    /// What the file picker offers: GPX files, and XML files that may hold GPX.
    static let contentTypes: [UTType] = {
        var types: [UTType] = []
        for t in [UTType("com.topografix.gpx"), UTType(filenameExtension: "gpx"), UTType.xml] {
            if let t, !types.contains(t) { types.append(t) }
        }
        return types
    }()

    private var pending: [URL] = []
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func start() {
        guard !started else { return }
        started = true
        // A file opened while onboarding was showing is imported once it has been accepted (handlePendingIntent).
        Prefs.shared.$onboardingAccepted.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] accepted in
            guard let self, accepted, !self.pending.isEmpty else { return }
            let urls = self.pending
            self.pending = []
            urls.forEach { self.importFile($0) }
        }.store(in: &cancellables)
    }

    /// "Open in TrailMind": takes .gpx files; anything else is left to the other features.
    func handle(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "gpx" else { return false }
        if Prefs.shared.onboardingAccepted { importFile(url) } else { pending.append(url) }
        return true
    }

    /// Imports a GPX file and shows the new route (MainActivity.importGpx).
    func importFile(_ url: URL) {
        let fileName = RouteImportPlan.baseName(url.lastPathComponent)
        AppModel.shared.toast("Importing GPX…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> (id: Int64, needsTerrain: Bool) in
                let doc = try GpxParser.parse(Self.read(url))
                let plan = try RouteImportPlan.prepare(doc, fileName: fileName)
                guard let id = Store.shared.insertRoute(name: plan.name, points: plan.line, waypoints: plan.waypoints) else {
                    throw Failure(message: "Could not save the route on this phone.")
                }
                return (id, plan.needsTerrain)
            }
            Self.removeInboxCopy(url)
            DispatchQueue.main.async { self.imported(result) }
        }
    }

    private func imported(_ result: Result<(id: Int64, needsTerrain: Bool), Error>) {
        switch result {
        case .success(let r):
            let fetchTerrain = r.needsTerrain && RouteNetwork.shared.networkAllowed
            AppModel.shared.toast(fetchTerrain ? "Route imported. Adding heights…" : "Route imported")
            RoutesFeature.openDetail(r.id)
            if fetchTerrain { addHeights(r.id) }
        case .failure(let e):
            AppModel.shared.info("Import failed", RouteErrors.message(e))
        }
    }

    /// Fills a new route's heights from the terrain model; the route page shows them when they arrive.
    private func addHeights(_ id: Int64) {
        DispatchQueue.global(qos: .utility).async {
            guard let route = Store.shared.routeData(id) else { return }
            let changed = Store.shared.updateRouteHeights(id, sampled: TerrainService.shared.fill(route.points))
            if changed { DispatchQueue.main.async { AppModel.shared.toast("Terrain heights added") } }
        }
    }

    /// The file's bytes, through file coordination so a file in iCloud Drive is downloaded first, with access granted
    /// for a file picked outside the app's own folders.
    private static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do { data = try Data(contentsOf: readURL, options: .mappedIfSafe) } catch { readError = error }
        }
        if let data { return data }
        let reason = (readError ?? coordinationError).map { $0.localizedDescription } ?? "the file is unavailable"
        throw GpxParseError("Could not read GPX: \(reason)")
    }

    /// iOS copies a file opened in TrailMind into Documents/Inbox; once read, the route holds everything it had.
    private static func removeInboxCopy(_ url: URL) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).resolvingSymlinksInPath().path
        let file = url.resolvingSymlinksInPath().path
        if file.hasPrefix(inbox + "/") { try? FileManager.default.removeItem(atPath: file) }
    }
}
