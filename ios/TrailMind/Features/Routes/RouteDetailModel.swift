import Combine
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// "You are here" on a followed route's profile: where route guidance places you along it (Android's
/// `app.nav.fix?.alongM`), kept apart from the page so a new fix redraws only the chart. Guidance has followed you since
/// you set off, so on a loop or an out-and-back route it knows which leg you are on.
final class RouteCursor: ObservableObject {
    @Published private(set) var alongM: Double? = nil
    private var routeId: Int64?
    private var cancellable: AnyCancellable?

    /// Shows where you are along `routeId` while guidance follows it; nil stops.
    func track(_ routeId: Int64?) {
        self.routeId = routeId
        guard routeId != nil else { return stop() }
        if cancellable == nil {
            cancellable = Guidance.shared.$revision.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() }
        }
        update()
    }

    func stop() {
        cancellable = nil
        routeId = nil
        if alongM != nil { alongM = nil }
    }

    private func update() {
        let core = Guidance.shared.core
        let along = routeId != nil && core.active?.id == routeId ? core.fix?.alongM : nil
        guard let along else {
            if alongM != nil { alongM = nil }
            return
        }
        if alongM.map({ abs($0 - along) >= 1 }) ?? true { alongM = along }
    }
}

/// One route and everything its page shows (Pages.kt RouteDetailPage's state): the route, its saved facilities,
/// forecast, offline-map coverage, LiDAR check and the phone's readiness for the walk. Loads off the main thread.
final class RouteDetailModel: ObservableObject {
    let routeId: Int64
    @Published private(set) var data: RouteData? = nil
    @Published private(set) var loaded = false
    @Published private(set) var profile: [RouteProfileSample] = []
    @Published private(set) var facilities: SavedFacilities? = nil
    @Published private(set) var facilityCacheUnreadable = false
    @Published var facilityFilter: FacilityCategory? = nil
    @Published var showAllFacilities = false
    @Published private(set) var forecast: PointForecast? = nil
    @Published private(set) var mapCoverage: Int? = nil
    @Published private(set) var mapCoverageUntilMs: Int64? = nil
    @Published private(set) var coverageSourceId: String? = nil
    @Published private(set) var fetchingWeather = false
    @Published private(set) var addingTerrain = false
    @Published private(set) var lidarCheck: SavedLidarCheck? = nil
    @Published private(set) var lidarSquares: Int? = nil
    @Published private(set) var lidarMissing = 0
    /// Notifications allowed (nil until known), and Location Services switched on.
    @Published private(set) var alertsAllowed: Bool? = nil
    @Published private(set) var locationServicesOn = true
    /// Battery percentage (-1 when the phone doesn't say) and whether it is charging or full.
    @Published private(set) var batteryLevel = -1
    @Published private(set) var charging = false
    let cursor = RouteCursor()

    private var loading = false
    private var checking = false
    private var facilityListener: UUID?
    private var estimateKey: PaceSettings?
    private var estimateValue: HikeEstimate?
    private var highKey: PaceSettings?
    private var highValue: HighPoint?

    init(routeId: Int64) { self.routeId = routeId }

    /// The walking-time estimate over the whole profile, for the current pace.
    func estimate(_ pace: PaceSettings) -> HikeEstimate {
        if let value = estimateValue, estimateKey == pace { return value }
        let value = HikeEstimator.estimate(data?.points ?? [], pace: pace)
        estimateKey = pace
        estimateValue = value
        return value
    }

    /// The route's highest point and when you would get there, for the weather check.
    func highPoint(_ pace: PaceSettings) -> HighPoint? {
        if highKey == pace { return highValue }
        highValue = HikeEstimator.highPoint(data?.points ?? [], pace: pace)
        highKey = pace
        return highValue
    }

    // MARK: Showing and hiding (Page.onShow / onHide)

    func show() {
        if facilityListener == nil {
            facilityListener = OverpassFacilities.shared.addListener(routeId) { [weak self] result in self?.facilitiesArrived(result) }
        }
        refreshDevice()
        // Facilities found while the page was away are read again each time it shows, as Android does.
        if !loading {
            loading = true
            let id = routeId
            DispatchQueue.global(qos: .userInitiated).async {
                let data = Store.shared.routeData(id)
                let saved = OverpassFacilities.shared.saved(id)
                let hasSaved = OverpassFacilities.shared.hasSaved(id)
                DispatchQueue.main.async {
                    if !self.loaded || data != self.data { self.setData(data) }
                    self.facilities = saved
                    self.facilityCacheUnreadable = hasSaved && saved == nil
                    self.loaded = true
                    self.loading = false
                    self.updateReadiness()
                    self.loadLidar()
                    self.updateCursor()
                }
            }
        }
        if loaded {
            updateReadiness()
            loadLidar()
            updateCursor()
        }
    }

    func hide() {
        if let facilityListener { OverpassFacilities.shared.removeListener(routeId, facilityListener) }
        facilityListener = nil
        cursor.stop()
    }

    /// The route again after a change to it (heights added, renamed) or to the library.
    func reload() {
        guard loaded else { return }
        let id = routeId
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Store.shared.routeData(id)
            DispatchQueue.main.async {
                if data != self.data {
                    let pointsChanged = data?.points != self.data?.points
                    self.setData(data)
                    if pointsChanged {
                        self.updateReadiness()
                        self.loadLidar()
                    }
                }
                self.updateCursor()
            }
        }
    }

    private func setData(_ d: RouteData?) {
        if d?.points != data?.points {
            profile = RouteProfileSample.of(d?.points ?? [])
            estimateValue = nil
            estimateKey = nil
            highValue = nil
            highKey = nil
        }
        data = d
    }

    /// The profile's cursor follows you while this route is the one followed.
    func updateCursor() {
        cursor.track(Prefs.shared.activeRouteId == routeId && data != nil ? routeId : nil)
    }

    // MARK: Facilities

    private func facilitiesArrived(_ result: Result<SavedFacilities, Error>) {
        switch result {
        case .success(let saved):
            facilities = saved
            facilityCacheUnreadable = false
            showAllFacilities = false
            RouteFollow.shared.updateFacilities()
        case .failure(let e):
            let message = RouteErrors.message(e)
            AppModel.shared.toast("Could not find facilities: \(message.isEmpty ? "connection failed" : message)")
        }
        updateReadiness()
    }

    func findFacilities() {
        guard let d = data else { return }
        OverpassFacilities.shared.start(routeId, d.points.map { $0.latLon() })
    }

    // MARK: LiDAR

    /// The saved LiDAR check, and how many squares a check needs and still has to download.
    func loadLidar() {
        guard let points = data?.points.map({ $0.latLon() }) else { return }
        let id = routeId
        DispatchQueue.global(qos: .utility).async {
            let squares = LidarCheckPlan.squares(points)
            let saved = LidarChecks.shared.saved(id)
            let missing = LidarService.shared.missing(squares)
            DispatchQueue.main.async {
                self.lidarCheck = saved
                self.lidarSquares = squares.count
                self.lidarMissing = missing
            }
        }
    }

    func startLidarCheck() {
        guard let d = data else { return }
        LidarChecks.shared.start(routeId, d.points.map { $0.latLon() })
    }

    // MARK: Heights

    func addHeights() {
        guard let d = data, !addingTerrain else { return }
        addingTerrain = true
        let id = routeId
        DispatchQueue.global(qos: .userInitiated).async {
            let filled = TerrainService.shared.fill(d.points)
            let changed = Store.shared.updateRouteHeights(id, sampled: filled)
            let updated = Store.shared.routeData(id)
            DispatchQueue.main.async {
                self.addingTerrain = false
                if changed {
                    self.setData(updated)
                    AppModel.shared.toast("Terrain heights added")
                    self.updateReadiness()
                } else {
                    AppModel.shared.toast("Terrain heights unavailable")
                }
            }
        }
    }

    // MARK: Readiness

    /// The saved forecast and how much of the route the base map's offline packs cover (RouteDetailPage.updateReadiness).
    func updateReadiness() {
        guard let route = data, !checking else { return }
        checking = true
        let source = RoutesFeature.currentSource()
        let id = routeId
        let points = route.points.map { $0.latLon() }
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = RouteForecasts.saved(id)
            let samples = TripReadiness.sampleRoute(points)
            let packs = Store.shared.packs().filter { $0.kind == .download && $0.sourceId == source.id }
                .map { ReadinessPack(id: $0.id, maxZoom: $0.maxZoom, premiumMaxZoom: $0.premiumMaxZoom, premiumMs: $0.premiumMs) }
            let lookup = TileLoader.shared.packLookup
            let coverage = RouteReadiness.mapCoverage(source: source, points: samples, packs: packs, nowMs: nowMs(),
                                                      hasTile: { _, key in lookup?(source, key) != nil },
                                                      premiumCachedAt: { RouteDetailModel.premiumCachedAt(source, $0) })
            DispatchQueue.main.async {
                self.forecast = saved
                self.mapCoverage = coverage.coverage
                self.coverageSourceId = source.id
                self.mapCoverageUntilMs = coverage.untilMs
                self.checking = false
                if Prefs.shared.baseSourceId != source.id { self.updateReadiness() }
            }
        }
    }

    /// When the map cached a Premium tile, from its file in TileLoader's browse cache (Caches/tiles/<source>/z/x/y.tile),
    /// or 0 when it isn't there (TileProvider.premiumCachedAt).
    private static func premiumCachedAt(_ source: TileSource, _ key: TileKey) -> Int64 {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let file = caches.appendingPathComponent("tiles", isDirectory: true).appendingPathComponent(source.id, isDirectory: true)
            .appendingPathComponent("\(key.z)/\(key.x)/\(key.y).tile")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    func fetchForecast(_ high: HighPoint) {
        guard !fetchingWeather else { return }
        fetchingWeather = true
        RouteForecasts.fetch(routeId, at: high.position, eleM: high.eleM) { [weak self] result in
            guard let self else { return }
            self.fetchingWeather = false
            switch result {
            case .success(let f): self.forecast = f
            case .failure(let e): AppModel.shared.toast("Forecast unavailable: \(RouteErrors.message(e))")
            }
        }
    }

    /// The battery as the readiness check reads it (Android's battery-changed broadcast). Call on the main queue.
    func readBattery() {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        batteryLevel = level < 0 ? -1 : Int((Double(level) * 100).rounded())
        charging = device.batteryState == .charging || device.batteryState == .full
    }

    /// Whether notifications may alert and Location Services are on; asked off the main thread, as iOS wants.
    func refreshDevice() {
        readBattery()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            DispatchQueue.main.async { self.alertsAllowed = allowed }
        }
        DispatchQueue.global(qos: .utility).async {
            let on = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async { self.locationServicesOn = on }
        }
    }

    /// Location permission, Location Services or notifications, whichever is missing first (the readiness "Fix settings").
    func fixSettings() {
        let hub = LocationHub.shared
        if !hub.hasPermission {
            if hub.authorization == .notDetermined { hub.requestPermission() } else { AppModel.shared.openSettings() }
            return
        }
        if !locationServicesOn {
            AppModel.shared.info("Location Services are off", "Turn on Location Services in Settings › Privacy & Security › Location Services.")
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .notDetermined {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                        DispatchQueue.main.async { self.refreshDevice() }
                    }
                } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    AppModel.shared.open(url)
                }
            }
        }
    }
}
