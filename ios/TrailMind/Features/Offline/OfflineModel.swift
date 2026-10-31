import Combine
import MapKit
import SwiftUI

extension MapController {
    /// The part of the map you can see (beside the pane, above the navigation), as a box (TileMapView.visibleBounds).
    /// Before the map is laid out, a phone screen's worth around its centre.
    func visibleBounds() -> BoundingBox {
        if let map = mapView, map.bounds.width > 0, map.bounds.height > 0 {
            let area = visibleArea.width > 0 && visibleArea.height > 0 ? visibleArea : map.bounds
            let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                           CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY)]
                .map { map.convert($0, toCoordinateFrom: map) }
                .map { LatLon($0.latitude, $0.longitude) }
            if let box = BoundingBox.of(corners) { return box }
        }
        let mpp = WebMercator.metresPerPixel(center.lat, zoom)
        let north = Geo.destination(center, bearingDeg: 0, distanceM: 400 * mpp)
        let south = Geo.destination(center, bearingDeg: 180, distanceM: 400 * mpp)
        let east = Geo.destination(center, bearingDeg: 90, distanceM: 200 * mpp)
        let west = Geo.destination(center, bearingDeg: 270, distanceM: 200 * mpp)
        return BoundingBox(south.lat, west.lon, north.lat, east.lon)
    }
}

/// The Offline page's state (OfflinePage on Android): the new download's choices and tile count, and every pack with
/// its 24-hour detail.
final class OfflineModel: ObservableObject {
    @Published private(set) var packs: [PackMeta] = []
    @Published private(set) var routes: [RouteMeta] = []
    @Published private(set) var routeId: Int64?
    @Published private(set) var routeData: RouteData? = nil
    @Published private(set) var sourceId: String? = nil
    @Published var maxZoom = 15
    @Published var premiumMaxZoom = 0
    @Published var bufferM = 500.0
    @Published private(set) var count: Int64? = nil
    @Published private(set) var countedArea: BoundingBox? = nil
    @Published private(set) var premiumCount: Int64 = 0
    @Published private(set) var lidarMissing = 0
    @Published private(set) var lidarSquares = 0
    @Published private(set) var premiumExpiries: [Int64: PackPlan.PremiumDetail] = [:]
    @Published private(set) var cacheBytes: Int64? = nil
    @Published private(set) var naming = false
    private var countJob = 0
    private var reloadJob = 0
    private var shownPacksKey = ""
    private var cancellables = Set<AnyCancellable>()
    private static var premiumProbed = false

    init(routeId: Int64?) {
        self.routeId = routeId
        let packs = OfflinePacks.shared
        packs.$packs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.packsChanged(list) }
            .store(in: &cancellables)
        // The live bar follows the running download; when it ends the list is read again.
        packs.$progress
            .map { $0 == nil }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] idle in if idle { self?.reload() } }
            .store(in: &cancellables)
        // The visible area follows the map, so the count is for what you see.
        MapController.shared.$center
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in if self?.routeId == nil { self?.recount() } }
            .store(in: &cancellables)
        Prefs.shared.$osPremium
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recount() }
            .store(in: &cancellables)
    }

    func appear() {
        reload()
        probePremium()
    }

    /// A request from a route page or the map's menu: that route's corridor, or the visible area.
    func take(_ request: OfflineRequests.Request) {
        if routeId != request.routeId { pickRoute(request.routeId) } else { recount() }
    }

    private func packsChanged(_ list: [PackMeta]) {
        let key = list.map { "\($0.id)|\($0.status.rawValue)|\($0.premiumMs)|\($0.message ?? "")" }.joined(separator: ",")
        if key != shownPacksKey { reload() }
    }

    /// The Premium choices need to know the key's plan; one Premium tile answers that.
    private func probePremium() {
        let prefs = Prefs.shared
        if prefs.osPremium || KotlinText.isBlank(prefs.osApiKey) || Self.premiumProbed { return }
        Self.premiumProbed = true
        guard let os = TileSources.builtIns().first(where: { $0.id == TileSources.osOutdoor }) else { return }
        OfflineNet.shared.fetchTile(os, TileKey(17, 64462, 41754)) { _ in }
    }

    func reload() {
        reloadJob += 1
        let job = reloadJob
        let custom = OfflineSources.custom(Prefs.shared)
        DispatchQueue.global(qos: .userInitiated).async {
            let packs = Store.shared.packs()
            let routes = Store.shared.routes()
            var expiry: [Int64: PackPlan.PremiumDetail] = [:]
            for p in packs {
                if let d = OfflinePacks.shared.premiumDetail(p, custom: custom, packs: packs) { expiry[p.id] = d }
            }
            let bytes = TileLoader.shared.cacheBytes()
            DispatchQueue.main.async {
                guard job == self.reloadJob else { return }
                self.shownPacksKey = packs.map { "\($0.id)|\($0.status.rawValue)|\($0.premiumMs)|\($0.message ?? "")" }.joined(separator: ",")
                self.packs = packs
                self.routes = routes
                self.premiumExpiries = expiry
                self.cacheBytes = bytes
                self.loadRoute()
            }
        }
    }

    private func loadRoute() {
        guard let id = routeId, routeData?.meta.id != id else {
            recount()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Store.shared.routeData(id)
            DispatchQueue.main.async {
                guard self.routeId == id else { return }
                self.routeData = data
                self.recount()
            }
        }
    }

    // MARK: Choices

    func downloadable() -> [TileSource] { OfflineSources.downloadable(custom: OfflineSources.custom(Prefs.shared), packs) }

    func source() -> TileSource? {
        let list = downloadable()
        return list.first { $0.id == sourceId } ?? list.first { $0.id == Prefs.shared.baseSourceId } ?? list.first
    }

    func pickSource(_ id: String) {
        sourceId = id
        let selected = source()
        maxZoom = selected?.effectiveDownloadMaxZoom ?? maxZoom
        premiumMaxZoom = selected?.id == TileSources.osLeisure && Prefs.shared.osPremium ? 9 : 0
        recount()
    }

    func pickRoute(_ id: Int64?) {
        routeId = id
        routeData = nil
        count = nil
        countJob += 1
        loadRoute()
    }

    func pickBuffer(_ m: Double) {
        bufferM = m
        recount()
    }

    func pickMaxZoom(_ z: Int) {
        maxZoom = z
        recount()
    }

    func pickPremium(_ z: Int) {
        premiumMaxZoom = z
        recount()
    }

    private func area() -> BoundingBox {
        if let points = routeData?.points.map({ $0.latLon() }), let box = BoundingBox.of(points) { return box.expandedByMetres(bufferM) }
        return MapController.shared.visibleBounds()
    }

    func premiumZooms(_ s: TileSource) -> ClosedRange<Int>? {
        PackPlan.premiumZooms(s, osPremium: Prefs.shared.osPremium, premiumMaxZoom: premiumMaxZoom)
    }

    /// Whether 1 m LiDAR can be saved with this route's map (the routes feature provides it, in England).
    var lidarAvailable: Bool { FeatureHooks.saveLidarSquares != nil && FeatureHooks.lidarMissing != nil }

    func recount() {
        guard let s = source() else {
            count = nil
            return
        }
        countJob += 1
        let job = countJob
        let route = routeData?.points.map { $0.latLon() }
        let box = area()
        let buffer = bufferM
        let minZ = PackPlan.minZoom(s)
        let maxZ = min(maxZoom, s.effectiveDownloadMaxZoom)
        let premium = premiumZooms(s)
        let missingHook = lidarAvailable ? FeatureHooks.lidarMissing : nil
        count = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let open = PackPlan.count(route: route, box: box, bufferM: buffer, grid: s.grid, from: minZ, to: maxZ)
            let detail = premium.map { PackPlan.count(route: route, box: box, bufferM: buffer, grid: s.grid, from: $0.lowerBound, to: $0.upperBound) } ?? 0
            var squares: [Lidar.Square] = []
            var missing = 0
            if let route, let missingHook {
                squares = Lidar.corridor(route.map { OsGrid.project($0) }, PackPlan.lidarCorridorM)
                missing = squares.isEmpty ? 0 : missingHook(squares)
            }
            DispatchQueue.main.async {
                guard job == self.countJob else { return }
                self.count = open + detail
                self.premiumCount = detail
                self.countedArea = box
                self.lidarSquares = squares.count
                self.lidarMissing = missing
            }
        }
    }

    // MARK: Downloading

    /// The Download button: name the area after the nearest OS place when it can, then ask for a name.
    func download() {
        guard let s = source(), let c = count, c > 0, c <= Int64(TilePolicy.maxTilesPerDownload), !naming else { return }
        if PackDownloader.shared.isBusy {
            AppModel.shared.toast("Another download is running.")
            return
        }
        let fallback = routeData?.meta.name ?? OfflineText.areaFallbackName()
        let key = Prefs.shared.osApiKey
        guard routeData == nil, let box = countedArea, !KotlinText.isBlank(key), OfflineNet.shared.networkAllowed() else {
            askName(s, fallback, c)
            return
        }
        naming = true
        Task { @MainActor in
            let name = await OfflineNet.shared.areaName(box, key: key)
            self.naming = false
            self.askName(s, name ?? fallback, c)
        }
    }

    private func askName(_ s: TileSource, _ defaultName: String, _ tiles: Int64) {
        AppModel.shared.prompt("Name this offline map", initial: defaultName) { [weak self] name in
            guard let self else { return }
            let chosen = KotlinText.isBlank(name) ? defaultName : name
            if self.premiumCount > 0 {
                let detail = self.premiumCount
                // The next question waits for the name prompt to finish closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    AppModel.shared.confirm("Use OS Premium transactions?",
                                            "Downloading \(detail) detail tiles uses transactions from your OS Data Hub plan. Detail expires within 24 hours; overview maps stay saved.",
                                            ok: "Download") { self.startDownload(s, chosen, tiles) }
                }
            } else {
                self.startDownload(s, chosen, tiles)
            }
        }
    }

    private func startDownload(_ s: TileSource, _ name: String, _ tiles: Int64) {
        guard let box = countedArea else { return }
        let route = routeData
        let minZ = PackPlan.minZoom(s)
        let maxZ = min(maxZoom, s.effectiveDownloadMaxZoom)
        let detailZoom = premiumZooms(s)?.upperBound ?? 0
        let buffer = route != nil ? bufferM : 0
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Int64, Error> = Result {
                let fileName = "dl_\(nowMs()).mbtiles"
                _ = try MbTilesFile.create(OfflinePacks.fileURL(fileName), name: name, bounds: box, minZoom: minZ, maxZoom: maxZ,
                                           attribution: s.attribution, grid: s.grid)
                let id = Store.shared.insertPack(name: name, kind: .download, sourceId: s.id, fileName: fileName, minZoom: minZ,
                                                 maxZoom: maxZ, bounds: box, routeId: route?.meta.id, bufferM: buffer, tileTotal: tiles,
                                                 status: .queued, format: "png", attribution: s.attribution, premiumMaxZoom: detailZoom)
                OfflinePacks.shared.reloadNow()
                return id
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let id):
                    OfflineNotifications.shared.requestAuthorization()
                    PackDownloader.shared.download(id)
                    AppModel.shared.toast("Downloading \(name) in the background")
                    self.reload()
                case .failure(let error):
                    AppModel.shared.toast("Could not start download: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Resumes, renews or downloads again the area a pack already covers, so nothing has to be chosen again.
    func downloadAgain(_ pack: PackMeta, title: String) {
        if PackDownloader.shared.isBusy {
            AppModel.shared.toast("Another download is running.")
            return
        }
        let start = {
            OfflineNotifications.shared.requestAuthorization()
            PackDownloader.shared.download(pack.id)
        }
        let tiles = premiumExpiries[pack.id]?.toFetch ?? 0
        if tiles == 0 {
            start()
            return
        }
        let label = PackPlan.premiumLabel(sourceId: pack.sourceId, premiumMaxZoom: pack.premiumMaxZoom)
        AppModel.shared.confirm(title, PackPlan.downloadAgainText(tiles: tiles, label: label), ok: "Download") { start() }
    }

    func clearCache() {
        AppModel.shared.confirm("Clear cached maps?", "This also removes pre-loaded 24-hour detail. Saved overview packs stay on the phone.",
                                ok: "Clear") { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                TileLoader.shared.clearCache()
                OfflineNotifications.shared.reschedule()
                DispatchQueue.main.async {
                    OfflinePacks.refreshMap()
                    self?.reload()
                }
            }
        }
    }
}
