import Combine
import SwiftUI
import UIKit

/// Guidance along the followed route plus the "go to" target (NavigationController on Android), around the Core
/// `RouteGuidance`. The followed route is `Prefs.activeRouteId`, which the route pages set and clear; this follows it,
/// draws it on the map with its waypoints and distance marks, and gives the off-route, daylight and rejoin alerts as
/// notifications and vibration. "Retrace my steps" follows the recorded track back to the start without changing the
/// followed route, which comes back when the retrace stops. This does not create routes: it measures where you are
/// relative to a line you imported or planned.
final class Guidance: ObservableObject {
    static let shared = Guidance()

    let core: RouteGuidance
    /// Changes whenever anything the guidance card shows may have changed.
    @Published private(set) var revision = 0

    private var started = false
    private var listener: UUID?
    private var loadJob = 0
    private var cancellables = Set<AnyCancellable>()
    private var marks: [LatLon] = []
    private var marksKey = ""
    private var shownEvery = 0
    private var startByKey = ""
    private var startByLine: String?
    private var targetLineFrom: LatLon?
    private var seenMapRevision = -1

    private init() {
        core = RouteGuidance(track: HikeRecorder.shared.track, settings: Guidance.settings(),
                             daylightAlertState: Prefs.shared.daylightAlertState)
    }

    static func settings() -> GuidanceSettings {
        let prefs = Prefs.shared
        return GuidanceSettings(offRouteThresholdM: prefs.offRouteThresholdM, pace: HikeTime.pace,
                                daylightMarginMinutes: prefs.daylightMarginMinutes)
    }

    func start() {
        guard !started else { return }
        started = true
        listener = LocationHub.shared.addListener { [weak self] fix in self?.onFix(fix) }
        let prefs = Prefs.shared
        prefs.$activeRouteId
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.followedRouteChanged(id) }
            .store(in: &cancellables)
        Publishers.MergeMany(
            prefs.$offRouteThresholdM.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            prefs.$flatSpeedKmh.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            prefs.$conditionsFactor.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            prefs.$daylightMarginMinutes.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.settingsChanged() }
        .store(in: &cancellables)
        prefs.$imperial
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMap()
                self?.changed()
            }
            .store(in: &cancellables)
        MapController.shared.$zoom
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMarks() }
            .store(in: &cancellables)
        let id = prefs.activeRouteId
        if id > 0 { follow(id) }
    }

    // MARK: Following

    private func follow(_ routeId: Int64) {
        loadJob += 1
        let job = loadJob
        let pace = HikeTime.pace
        DispatchQueue.global(qos: .userInitiated).async {
            let route = Store.shared.routeData(routeId).flatMap { d in
                GuidedRoute.build(id: d.meta.id, name: d.meta.name, points: d.points, waypoints: d.waypoints, pace: pace)
            }
            DispatchQueue.main.async {
                guard job == self.loadJob else { return }
                if let route {
                    self.handle(self.core.follow(route, nowMs: nowMs()))
                    self.saveAlertState()
                    // Off-route and daylight alerts reach you as notifications with the screen off.
                    HikeNotifications.shared.requestAuthorization()
                } else if Prefs.shared.activeRouteId == routeId {
                    Prefs.shared.activeRouteId = -1
                }
                self.updateMap()
                self.changed()
            }
        }
    }

    private func followedRouteChanged(_ id: Int64) {
        if id > 0 {
            if core.active?.id != id { follow(id) }
        } else if let active = core.active, !active.isTracBack {
            loadJob += 1
            _ = core.stop(followedRouteId: -1)
            afterStop()
        } else {
            // A retrace carries on; put its line back if a route page cleared the map.
            updateMap()
        }
    }

    /// "Stop following" (NavigationController.stopFollowing): a retrace gives way to the followed route again.
    func stopFollowing() {
        loadJob += 1
        let resume = core.stop(followedRouteId: Prefs.shared.activeRouteId)
        afterStop()
        if let resume { follow(resume) } else { Prefs.shared.activeRouteId = -1 }
    }

    private func afterStop() {
        saveAlertState()
        HikeNotifications.shared.cancel(.offRoute)
        updateMap()
        changed()
    }

    /// Retrace my steps: guides back along the recorded track to where the hike started. False if too little is
    /// recorded (nothing is, unless a hike is recording or paused).
    @discardableResult
    func retrace() -> Bool {
        guard let events = core.traceBack(nowMs: nowMs()) else { return false }
        loadJob += 1
        handle(events)
        saveAlertState()
        updateMap()
        changed()
        return true
    }

    /// Re-reads the threshold, pace and daylight margin (NavigationController.settingsChanged).
    private func settingsChanged() {
        core.settingsChanged(Guidance.settings())
        startByKey = ""
        changed()
    }

    // MARK: Go to

    /// "Go to here": a target with a bearing line from your position (Compass and the map card show it).
    func goTo(_ name: String, _ position: LatLon) {
        MapController.shared.setTarget(name, position)
        targetLineFrom = LocationHub.shared.latest?.latLon
        seenMapRevision = MapController.shared.revision
    }

    func clearTarget() {
        MapController.shared.setTarget(nil, nil)
        targetLineFrom = nil
    }

    /// The map draws the bearing line from the position at its last redraw; redraw it every 10 m you move.
    private func refreshTargetLine(_ here: LatLon) {
        let map = MapController.shared
        guard let target = map.target else {
            targetLineFrom = nil
            return
        }
        if map.revision != seenMapRevision {
            // Something else redrew the map, with the latest position.
            seenMapRevision = map.revision
            targetLineFrom = here
            return
        }
        if let from = targetLineFrom, Geo.distanceM(from, here) < 10 { return }
        targetLineFrom = here
        map.setTarget(target.title, target.position)
        seenMapRevision = map.revision
    }

    // MARK: Fixes and alerts

    private func onFix(_ f: Fix) {
        let events = core.onFix(GuidanceFix(position: f.latLon, timeMs: f.timeMs, accuracyM: f.accuracyM), nowMs: nowMs())
        handle(events)
        saveAlertState()
        refreshTargetLine(f.latLon)
        if core.active != nil { changed() }
    }

    private func handle(_ events: [GuidanceEvent]) {
        let imperial = Prefs.shared.imperial
        for event in events {
            switch event {
            case .leftRoute(let offRouteM, let back):
                HikeHaptics.play(.offRoute)
                HikeNotifications.shared.post(.offRoute, title: HikeText.offRouteTitle,
                                              body: HikeText.offRouteAlert(offRouteM: offRouteM, backBearingDeg: back, imperial: imperial))
            case .rejoinedRoute:
                HikeNotifications.shared.cancel(.offRoute)
                HikeHaptics.play(.rejoined)
            case .daylightWarning(let forecast, let dayOffset, let margin):
                HikeHaptics.play(.daylight)
                HikeNotifications.shared.post(.daylight, title: HikeText.daylightTitle,
                                              body: HikeText.daylightWarning(forecast, finishDayOffset: dayOffset, marginMinutes: margin,
                                                                             clock: HikeTime.clock))
            case .darkByFinish:
                HikeHaptics.play(.daylight)
                HikeNotifications.shared.post(.dusk, title: HikeText.darkByFinishTitle, body: HikeText.darkByFinishText)
            }
        }
    }

    private func saveAlertState() {
        let state = core.daylightAlertState
        if Prefs.shared.daylightAlertState != state { Prefs.shared.daylightAlertState = state }
    }

    private func changed() { revision &+= 1 }

    // MARK: The guidance card's daylight line

    /// Before the walk has started, when to set off; after, the finish against sunset (MapScreen.updateNav).
    func daylightLine() -> String? {
        guard let route = core.active, core.fix != nil else { return nil }
        let prefs = Prefs.shared
        let now = nowMs()
        if !core.routeStarted {
            let key = "\(route.id)|\(route.points.count)|\(core.settings.pace)|\(prefs.daylightMarginMinutes)|\(now / 60_000)"
            if key != startByKey {
                startByKey = key
                startByLine = HikeText.startBy(route.points, pace: core.settings.pace, marginMinutes: prefs.daylightMarginMinutes,
                                               forMs: now, clock: HikeTime.clock)
            }
            return startByLine
        }
        return HikeText.daylightLine(core.daylight, sun: core.daylightSun, marginMinutes: prefs.daylightMarginMinutes, nowMs: now,
                                     clock: HikeTime.clock)
    }

    /// The "Daylight check" dialog behind the daylight line.
    func showDaylightCheck() {
        guard let daylight = core.daylight, let sunset = core.daylightSun?.sunsetMs else { return }
        AppModel.shared.info("Daylight check", HikeText.daylightCheck(daylight, sunsetMs: sunset, civilDuskMs: core.daylightSun?.civilDuskMs,
                                                                       marginMinutes: Prefs.shared.daylightMarginMinutes, nowMs: nowMs(),
                                                                       clock: HikeTime.clock))
    }

    // MARK: The map

    /// The followed route's line, waypoints and distance marks, or nothing.
    private func updateMap() {
        guard let route = core.active else {
            marks = []
            marksKey = ""
            MapController.shared.clearActiveRoute()
            return
        }
        let imperial = Prefs.shared.imperial
        let key = "\(route.id)|\(route.points.count)|\(imperial)"
        if key != marksKey {
            marksKey = key
            marks = DistanceMarks.along(route.guide, stepM: DistanceMarks.stepM(imperial: imperial))
        }
        shownEvery = markEvery()
        MapController.shared.setActiveRoute(route.points.map { $0.latLon() }, pins: pins(route))
    }

    /// Every n-th mark, so the labels stay readable at the map's zoom (TileMapView.drawDistanceMarks).
    private func markEvery() -> Int {
        let map = MapController.shared
        let stepPt = DistanceMarks.stepM(imperial: Prefs.shared.imperial) / WebMercator.metresPerPixel(map.center.lat, map.zoom)
        return DistanceMarks.every(stepPx: stepPt, minPx: 56.0)
    }

    private func updateMarks() {
        guard core.active != nil, !marks.isEmpty, markEvery() != shownEvery else { return }
        updateMap()
    }

    private func pins(_ route: GuidedRoute) -> [MapPin] {
        var pins = route.waypoints.enumerated().map { i, w in
            MapPin(id: "route-\(route.id)-wp-\(i)", position: w.latLon(), title: w.name, subtitle: w.description, kind: .waypoint)
        }
        let unit = Prefs.shared.imperial ? "mi" : "km"
        if shownEvery > 0 && shownEvery <= marks.count {
            for k in stride(from: shownEvery, through: marks.count, by: shownEvery) {
                pins.append(MapPin(id: "route-\(route.id)-mark-\(k)", position: marks[k - 1], title: "\(k)", subtitle: "\(k) \(unit)",
                                   kind: .distanceMark))
            }
        }
        return pins
    }
}
