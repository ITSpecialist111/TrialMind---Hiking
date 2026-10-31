import Combine
import Foundation
import UIKit

/// BRouter legs for the planner (BRouter.kt): one request per leg, cancellable, with the last 50 legs kept.
enum BRouterClient {
    struct Cancelled: Error, LocalizedError {
        var errorDescription: String? { "Routing cancelled" }
    }

    /// A leg's request, which the planner can cancel when the leg is undone or the plan cleared.
    final class Request {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func attach(_ t: URLSessionDataTask) -> Bool {
            lock.withLock {
                if cancelled { return false }
                task = t
                return true
            }
        }

        func cancel() {
            let t: URLSessionDataTask? = lock.withLock {
                cancelled = true
                let current = task
                task = nil
                return current
            }
            t?.cancel()
        }

        /// Runs `action` unless the request was cancelled.
        func ifActive(_ action: () -> Void) -> Bool {
            lock.withLock {
                if cancelled { return false }
                action()
                return true
            }
        }
    }

    private struct Key: Hashable {
        let start: LatLon
        let end: LatLon
    }

    private static let cacheLock = NSLock()
    private static var cache: [Key: [TrackPoint]] = [:]
    /// Least recently used first.
    private static var order: [Key] = []

    private static func cached(_ key: Key) -> [TrackPoint]? {
        cacheLock.withLock {
            guard let hit = cache[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return hit
        }
    }

    private static func remember(_ key: Key, _ points: [TrackPoint]) {
        cacheLock.withLock {
            cache[key] = points
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > BRouter.cacheSize { cache[order.removeFirst()] = nil }
        }
    }

    /// The path from `start` to `end` on the hiking-mountain profile. Blocks: call it off the main thread.
    static func leg(_ start: LatLon, _ end: LatLon, _ request: Request = Request()) throws -> [TrackPoint] {
        if request.isCancelled { throw Cancelled() }
        let key = Key(start: start, end: end)
        if let hit = cached(key) { return hit }
        guard let url = BRouter.url(start, end) else { throw BRouter.HTTPFailure(message: "BRouter request could not be made") }
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        let response = try RouteHTTP.shared.fetch(r, maxBytes: 16 * 1024 * 1024, tooLarge: "BRouter's answer was too large.") { task in
            if !request.attach(task) { task.cancel() }
        }
        if request.isCancelled { throw Cancelled() }
        if response.status != 200 { throw BRouter.failure(status: response.status, body: response.text) }
        let points = try BRouter.parse(RoutesJSON.parse(response.data))
        if !request.ifActive({ remember(key, points) }) { throw Cancelled() }
        return points
    }
}

/// The route planner (RoutePlanner.kt with MapScreen's startPlan, updatePlanner, closePlanner and savePlan): tap the map
/// to add points; each leg is snapped to paths with BRouter when there is signal, else drawn straight; undo, clear,
/// close the loop and save it as a route. While it is open, taps on the map add points.
final class RoutePlanner: ObservableObject {
    static let shared = RoutePlanner()

    let plan = RoutePlan()
    @Published private(set) var active = false
    @Published private(set) var snap = true
    @Published private(set) var notice: String? = nil
    @Published private(set) var saving = false
    /// Changes whenever the plan does.
    @Published private(set) var version = 0

    var pending: Bool { !requests.isEmpty }

    private var generation = 0
    private var requests: [Int: (leg: PlanLeg, request: BRouterClient.Request)] = [:]
    private let routeQueue = DispatchQueue(label: "trailmind-routing", qos: .userInitiated)
    private var lineIds = Set<String>()
    private var pendingTaps: [(id: Int, point: LatLon, atMs: Int64, work: DispatchWorkItem)] = []
    private var tapSeq = 0
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    /// Planned legs: teal, dashed where a leg is a straight line (TileMapView.planPaint and straightPaint).
    static let lineColour = UIColor(red: 0, green: 83 / 255.0, blue: 92 / 255.0, alpha: 1)
    /// Two taps closer together than this are a double tap (Android's double-tap timeout), which zooms the map.
    private static let doubleTapMs = 300
    private static let doubleTapSlopPt = 100.0

    /// Runs once at launch (RoutesFeature.start).
    func startService() {
        guard !started else { return }
        started = true
        // Leaving the map for another destination stops waiting for paths (MainActivity.showTab).
        Navigator.shared.$tab.removeDuplicates().dropFirst().sink { [weak self] tab in
            if tab != .map { self?.cancelPending() }
        }.store(in: &cancellables)
    }

    // MARK: Starting and closing (MapScreen)

    /// Starts a plan, optionally from a point, after asking to discard an unsaved one.
    func startPlan(_ at: LatLon?) {
        flushPendingTaps()
        if active && !plan.controlPoints.isEmpty {
            // After a moment, so a sheet that asked for this (the long-press menu) has gone first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                AppModel.shared.confirm("Start a new plan?", "The unsaved plan will be discarded.", ok: "Discard", danger: true) {
                    self.begin(at)
                }
            }
        } else {
            begin(at)
        }
    }

    private func begin(_ at: LatLon?) {
        start(at)
        RouteMap.revealMap()
    }

    func askToClose() {
        flushPendingTaps()
        if plan.controlPoints.isEmpty {
            close()
        } else {
            AppModel.shared.confirm("Discard this plan?", "The unsaved points will be lost.", ok: "Discard", danger: true) {
                self.close()
            }
        }
    }

    func askToSave() {
        flushPendingTaps()
        if saving || pending || plan.legs.isEmpty { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "'Walk' d MMM"
        promptForName(f.string(from: Date()), message: nil)
    }

    private func promptForName(_ initial: String, message: String?) {
        AppModel.shared.prompt("Save route", initial: initial, hint: "Route name", message: message, ok: "Save") { title in
            if title.isEmpty {
                // Android keeps its dialog open with the error under the box; an alert closes, so ask again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.promptForName("", message: "Give the walk a name.") }
                return
            }
            if !self.active || self.pending || self.plan.legs.isEmpty { return }
            self.save(title)
        }
    }

    func setSnap(_ on: Bool) {
        flushPendingTaps()
        snap = on
        notify()
    }

    // MARK: RoutePlanner.kt

    func save(_ title: String) {
        if saving || !active || pending || plan.legs.isEmpty || title.isBlank { return }
        saving = true
        let line = plan.line
        let savedVersion = generation
        notify()
        DispatchQueue.global(qos: .userInitiated).async {
            let id = Store.shared.insertRoute(name: title, points: line, waypoints: [])
            DispatchQueue.main.async {
                self.saving = false
                if id != nil && self.generation == savedVersion { self.close() }
                self.notify()
                if let id {
                    RoutesFeature.openDetail(id)
                } else {
                    AppModel.shared.toast("Could not save this route.")
                }
            }
        }
    }

    func start(_ at: LatLon? = nil) {
        if saving { return }
        generation += 1
        plan.clear()
        requests.values.forEach { $0.request.cancel() }
        requests.removeAll()
        notice = nil
        snap = true
        active = true
        if let at { plan.add(at) }
        notify()
    }

    func add(_ at: LatLon) {
        if saving || !active || !plan.add(at) { return }
        generation += 1
        notice = nil
        routeLast()
    }

    func backToStart() {
        if saving || !active || !plan.backToStart() { return }
        generation += 1
        notice = nil
        routeLast()
    }

    private func routeLast() {
        notify()
        if !snap || plan.legs.isEmpty { return }
        let legIndex = plan.legs.count - 1
        let leg = plan.legs[legIndex]
        if !RouteNetwork.shared.networkAllowed {
            showNotice(RouteText.plannerOffline)
            return
        }
        let request = BRouterClient.Request()
        requests[legIndex] = (leg, request)
        notify()
        routeQueue.async {
            if request.isCancelled { return }
            let result = Result { try BRouterClient.leg(leg.start, leg.end, request) }
            DispatchQueue.main.async {
                guard self.active, self.requests[legIndex]?.request === request else { return }
                self.requests[legIndex] = nil
                let snapped = (try? result.get()).map { self.plan.replaceLeg(legIndex, $0, expected: leg) } ?? false
                if snapped {
                    self.notify()
                } else {
                    var noPath = false
                    if case .failure(let e) = result { noPath = e is BRouter.NoPath }
                    self.showNotice(RouteText.plannerNotice(offline: !RouteNetwork.shared.networkAllowed, noPath: noPath))
                }
            }
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        notify(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if self.notice == text && self.active {
                self.notice = nil
                self.notify()
            }
        }
    }

    func undo() {
        if saving { return }
        generation += 1
        requests.removeValue(forKey: plan.legs.count - 1)?.request.cancel()
        plan.undo()
        notice = nil
        notify()
    }

    func clear() {
        if saving { return }
        generation += 1
        requests.values.forEach { $0.request.cancel() }
        requests.removeAll()
        plan.clear()
        notice = nil
        notify()
    }

    func cancelPending() {
        if requests.isEmpty { return }
        requests.values.forEach { $0.request.cancel() }
        requests.removeAll()
        notify()
    }

    func close() {
        if saving { return }
        clear()
        active = false
        notify()
    }

    // MARK: Taps on the map

    /// A tap is held for the double-tap time: a second tap close to it is a double tap, which zooms the map and adds no
    /// point (TileMapView's pending taps).
    private func tapped(_ p: LatLon) {
        if let last = pendingTaps.last, nowMs() - last.atMs < Int64(Self.doubleTapMs), near(last.point, p) {
            last.work.cancel()
            pendingTaps.removeLast()
            return
        }
        tapSeq += 1
        let id = tapSeq
        let work = DispatchWorkItem { [weak self] in self?.deliverTap(id) }
        pendingTaps.append((id, p, nowMs(), work))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.doubleTapMs), execute: work)
    }

    private func deliverTap(_ id: Int) {
        guard let i = pendingTaps.firstIndex(where: { $0.id == id }) else { return }
        let tap = pendingTaps.remove(at: i)
        add(tap.point)
    }

    /// Adds the taps still waiting to be told from a double tap, before a button changes the plan.
    func flushPendingTaps() {
        let taps = pendingTaps
        pendingTaps.removeAll()
        for tap in taps {
            tap.work.cancel()
            add(tap.point)
        }
    }

    private func near(_ a: LatLon, _ b: LatLon) -> Bool {
        let map = MapController.shared
        return Geo.distanceM(a, b) <= Self.doubleTapSlopPt * WebMercator.metresPerPixel(map.center.lat, map.zoom)
    }

    // MARK: The map (MapScreen.updatePlanner)

    private func notify(_ message: String? = nil) {
        if let message { AppModel.shared.toast(message) }
        version &+= 1
        updateMap()
    }

    /// The planned legs and control points on the map, and the map's taps while planning. The planner's pins are set
    /// last, so the map's revision changes after its tap handler does and cards such as the record bar give way.
    private func updateMap() {
        let map = MapController.shared
        if active {
            if map.tapOverride == nil { map.tapOverride = { [weak self] p in self?.tapped(p) } }
        } else {
            map.tapOverride = nil
            pendingTaps.forEach { $0.work.cancel() }
            pendingTaps.removeAll()
        }
        var ids = Set<String>()
        if active {
            for (i, leg) in plan.legs.enumerated() {
                for (j, part) in leg.parts.enumerated() {
                    let id = "plan-\(i)-\(j)"
                    ids.insert(id)
                    map.setLine(id, part.points.map { $0.latLon() }, color: Self.lineColour, width: 5, dashed: !part.snapped)
                }
            }
        }
        for id in lineIds.subtracting(ids) { map.setLine(id, nil) }
        lineIds = ids
        map.setPins("planner", active ? plan.controlPoints.enumerated().map { i, point in
            MapPin(id: "plan-point-\(i)", position: point, title: "\(i + 1)", subtitle: i == 0 ? "Start" : nil, kind: .planner)
        } : [])
    }
}
