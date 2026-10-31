import Foundation

/// What Beacon has worked out for the chosen route and start time.
struct BeaconBriefing {
    var input: BriefingInput
    var lines: [String]
    var prompt: String
    var startBy: String
}

/// Beacon's state (AssistantPage): the routes, the chosen one with its saved forecast and facilities, the planned start,
/// and the Apple Intelligence write-up.
final class BeaconModel: ObservableObject {
    @Published private(set) var routes: [RouteMeta] = []
    @Published private(set) var routesLoaded = false
    @Published private(set) var routeId: Int64?
    @Published private(set) var data: RouteData?
    @Published private(set) var forecast: PointForecast?
    @Published private(set) var facilities: BeaconFacilities?
    @Published private(set) var fetching = false
    @Published var startMs: Int64 = BeaconDaylight.nextQuarterHour()

    @Published private(set) var writeUp: String?
    @Published private(set) var writing = false

    private var loadGeneration = 0
    private var briefingKey: BriefingKey?
    private var briefingMemo: BeaconBriefing?

    init(presetRouteId: Int64?) {
        routeId = presetRouteId
    }

    // MARK: Routes

    /// Reads the routes (on show, and whenever the store changes) and loads the chosen one if it changed.
    func reloadRoutes() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Store.shared.routes()
            DispatchQueue.main.async { self.routesLoaded(list) }
        }
    }

    private func routesLoaded(_ list: [RouteMeta]) {
        routes = list
        routesLoaded = true
        let known = Set(list.map(\.id))
        if routeId == nil || !known.contains(routeId ?? -1) {
            let active = Prefs.shared.activeRouteId
            routeId = known.contains(active) ? active : list.first?.id
        }
        guard let id = routeId else {
            data = nil
            return
        }
        // Reload when the route itself changed (renamed, heights added) or hasn't been read yet.
        if data?.meta.id != id || list.first(where: { $0.id == id }) != data?.meta { load() }
    }

    func select(_ id: Int64) {
        guard id != routeId || data == nil else { return }
        routeId = id
        load()
    }

    private func load() {
        guard let id = routeId else { return }
        loadGeneration += 1
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let route = Store.shared.routeData(id)
            let saved = MountainForecasts.saved(id)
            let found = BeaconFeature.facilities(id)
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.data = route
                self.forecast = saved
                self.facilities = found
            }
        }
    }

    // MARK: Forecast

    func fetchForecast(_ id: Int64, _ high: HighPoint) {
        guard !fetching else { return }
        fetching = true
        Task.detached {
            do {
                let fresh = try await MountainForecasts.fetch(routeId: id, at: high.position, eleM: high.eleM)
                DispatchQueue.main.async {
                    self.fetching = false
                    if id == self.routeId { self.forecast = fresh }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async {
                    self.fetching = false
                    AppModel.shared.toast("Couldn't get the forecast: \(message.isEmpty ? "no connection" : message)")
                }
            }
        }
    }

    // MARK: Briefing

    private struct BriefingKey: Hashable {
        var meta: RouteMeta
        var points: Int
        var startMs: Int64
        var forecastMs: Int64?
        var facilitiesMs: Int64?
        var imperial: Bool
        var flatSpeedKmh: Double
        var conditionsFactor: Double
        var marginMinutes: Int
    }

    static func pace(_ prefs: Prefs) -> PaceSettings {
        (try? PaceSettings(flatSpeedKmh: prefs.flatSpeedKmh, conditionsFactor: prefs.conditionsFactor)) ?? PaceSettings()
    }

    /// The briefing for the route on show, worked out again only when something it depends on changes.
    func briefing(_ prefs: Prefs) -> BeaconBriefing? {
        guard let d = data, d.meta.id == routeId, let first = d.points.first, let last = d.points.last else { return nil }
        let key = BriefingKey(meta: d.meta, points: d.points.count, startMs: startMs, forecastMs: forecast?.fetchedMs,
                              facilitiesMs: facilities?.fetchedMs, imperial: prefs.imperial, flatSpeedKmh: prefs.flatSpeedKmh,
                              conditionsFactor: prefs.conditionsFactor, marginMinutes: prefs.daylightMarginMinutes)
        if key == briefingKey, let memo = briefingMemo { return memo }
        let pace = Self.pace(prefs)
        let start = first.latLon()
        let input = BriefingInput(
            routeName: d.meta.name,
            estimate: HikeEstimator.estimate(d.points, pace: pace),
            start: start,
            end: last.latLon(),
            maxEleM: d.meta.maxEleM,
            waypointNames: d.waypoints.map(\.name),
            sun: Sun.times(epochDay: CivilDate.localEpochDay(startMs, .current), start),
            plannedStartMs: startMs,
            zone: .current,
            imperial: prefs.imperial,
            highPoint: HikeEstimator.highPoint(d.points, pace: pace),
            forecast: forecast,
            facilities: facilities?.items ?? [],
            facilitiesPartial: facilities?.partial == true
        )
        let result = BeaconBriefing(
            input: input,
            lines: Briefing.ruleBased(input),
            prompt: Briefing.gemmaPrompt(input),
            startBy: BeaconDaylight.startByText(d.points, pace: pace, marginMinutes: prefs.daylightMarginMinutes, forMs: startMs)
        )
        briefingKey = key
        briefingMemo = result
        return result
    }

    // MARK: Apple Intelligence

    /// Has the on-device model write up `prompt`; nil clears the write-up (turned off, or nothing to write up).
    @MainActor
    func writeUp(_ prompt: String?) async {
        guard let prompt else {
            writing = false
            writeUp = nil
            return
        }
        if let done = BeaconAI.cached(prompt) {
            writing = false
            writeUp = done
            return
        }
        writeUp = nil
        writing = true
        // Choosing another route or time in quick succession cancels this before the model starts.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if Task.isCancelled { return }
        let text = await BeaconAI.writeUp(prompt)
        if Task.isCancelled { return }
        writing = false
        writeUp = text
    }
}
