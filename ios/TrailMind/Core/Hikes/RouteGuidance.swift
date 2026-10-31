import Foundation

/// A route loaded for guidance (NavigationController's ActiveRoute, without the drawn line).
struct GuidedRoute {
    /// Id of the in-memory "retrace steps" route; stored routes start at 1.
    static let tracBackId: Int64 = 0

    let id: Int64
    let name: String
    let points: [TrackPoint]
    let waypoints: [Waypoint]
    let guide: RouteGuide
    var estimate: HikeEstimate

    var isTracBack: Bool { id == GuidedRoute.tracBackId }

    /// The route ready to follow, or nil for a line without two distinct points (NavigationController.build).
    static func build(id: Int64, name: String, points: [TrackPoint], waypoints: [Waypoint], pace: PaceSettings) -> GuidedRoute? {
        if points.count < 2 { return nil }
        guard let guide = try? RouteGuide(points, waypoints: waypoints) else { return nil }
        return GuidedRoute(id: id, name: name, points: points, waypoints: waypoints, guide: guide,
                           estimate: HikeEstimator.estimate(points, pace: pace))
    }
}

/// The settings guidance reads (Prefs.offRouteThresholdM, pace and daylightMarginMinutes).
struct GuidanceSettings: Hashable {
    var offRouteThresholdM: Int = 60
    var pace = PaceSettings()
    var daylightMarginMinutes: Int = 30
}

/// A GPS fix as guidance uses it.
struct GuidanceFix: Hashable {
    var position: LatLon
    var timeMs: Int64
    var accuracyM: Float
}

/// Something guidance must tell the walker about now (NavigationController's alerts).
enum GuidanceEvent: Hashable {
    /// Off route by `offRouteM`; the nearest route point is at `backBearingDeg` from here.
    case leftRoute(offRouteM: Double, backBearingDeg: Double)
    case rejoinedRoute
    /// The estimated finish is after the sunset safety margin, or it is dark now. `finishDayOffset` is how many
    /// calendar days after today the finish falls.
    case daylightWarning(DaylightEstimate, finishDayOffset: Int64, marginMinutes: Int)
    /// The estimated finish is after civil dusk.
    case darkByFinish
}

/// Guidance along an imported line plus where the walker is on it (NavigationController without its notifications,
/// vibration and listeners, which the app adds around it). This does not create routes: it measures where you are
/// relative to a line you imported. Reads the recording state from `track`, as the Android controller reads
/// TrackingState. All methods run on one thread.
final class RouteGuidance {
    private(set) var active: GuidedRoute? = nil
    private(set) var fix: RouteFix? = nil
    private(set) var lastFix: GuidanceFix? = nil
    private(set) var offRoute = false
    /// Estimated minutes remaining (planning pace) from the snapped position to the end.
    private(set) var remainingMinutes: Double? = nil
    private(set) var daylight: DaylightEstimate? = nil
    private(set) var daylightSun: SunTimes? = nil
    private(set) var routeStarted = false
    /// Which daylight alerts this walk has had, as "walkKey:flags" (Prefs.daylightAlertState); the app saves it.
    var daylightAlertState: String
    private(set) var settings: GuidanceSettings

    private let track: HikeTrack
    private var detector: OffRouteDetector
    private var lastEstimateSeg = -1
    private var lastDaylightMs: Int64 = 0
    private var alertWalkKey: Int64? = nil
    private var sunsetAlerted = false
    private var duskAlerted = false
    private var start = RouteStart()

    init(track: HikeTrack, settings: GuidanceSettings = GuidanceSettings(), daylightAlertState: String = "") {
        self.track = track
        self.settings = settings
        self.daylightAlertState = daylightAlertState
        detector = OffRouteDetector(thresholdM: Double(settings.offRouteThresholdM))
    }

    /// Follows a loaded route (NavigationController.follow once the route has loaded); replays the last fix on it.
    @discardableResult
    func follow(_ route: GuidedRoute, nowMs: Int64, zone: TimeZone = .current) -> [GuidanceEvent] {
        active = route
        resetGuidance()
        guard let last = lastFix else { return [] }
        return onFix(last, nowMs: nowMs, zone: zone)
    }

    /// Stops guidance (NavigationController.stopFollowing). When this was a retrace and a stored route was being
    /// followed (`followedRouteId` > 0), returns that route's id to follow again; otherwise nil, and the caller clears
    /// the followed route.
    func stop(followedRouteId: Int64) -> Int64? {
        let resume: Int64? = active?.isTracBack == true && followedRouteId > 0 ? followedRouteId : nil
        active = nil
        resetGuidance()
        if track.status == .idle {
            alertWalkKey = nil
            daylightAlertState = ""
        }
        return resume
    }

    /// Guides back along the recorded track to where the hike started (NavigationController.traceBack). Nil if too
    /// little is recorded; otherwise the alerts from replaying the last fix.
    func traceBack(nowMs: Int64, zone: TimeZone = .current) -> [GuidanceEvent]? {
        guard let line = TracBack.line(track.points), let start = line.last else { return nil }
        guard let route = GuidedRoute.build(id: GuidedRoute.tracBackId, name: TracBack.routeName, points: line,
                                            waypoints: [Waypoint(lat: start.lat, lon: start.lon, name: TracBack.startName)],
                                            pace: settings.pace) else { return nil }
        return follow(route, nowMs: nowMs, zone: zone)
    }

    /// Re-reads the threshold and pace settings (NavigationController.settingsChanged).
    func settingsChanged(_ s: GuidanceSettings) {
        settings = s
        detector = OffRouteDetector(thresholdM: Double(s.offRouteThresholdM))
        offRoute = false
        lastEstimateSeg = -1
        daylight = nil
        daylightSun = nil
        if var route = active {
            route.estimate = HikeEstimator.estimate(route.points, pace: s.pace)
            active = route
        }
    }

    private func resetGuidance() {
        fix = nil
        offRoute = false
        remainingMinutes = nil
        daylight = nil
        daylightSun = nil
        lastDaylightMs = 0
        lastEstimateSeg = -1
        detector = OffRouteDetector(thresholdM: Double(settings.offRouteThresholdM))
        start = RouteStart()
        routeStarted = false
        active?.guide.reset()
    }

    /// Takes a GPS fix (NavigationController.onFix) and returns what the walker must be told now.
    @discardableResult
    func onFix(_ f: GuidanceFix, nowMs now: Int64, zone: TimeZone = .current) -> [GuidanceEvent] {
        lastFix = f
        guard let route = active else { return [] }
        var events: [GuidanceEvent] = []
        let rf = route.guide.locate(f.position, timeMs: f.timeMs)
        fix = rf
        let wasStarted = routeStarted
        routeStarted = start.update(rf, recording: track.status == .recording)
        if rf.segmentIndex != lastEstimateSeg || remainingMinutes == nil {
            lastEstimateSeg = rf.segmentIndex
            let points = route.guide.points
            var rest = [TrackPoint(lat: rf.snapped.lat, lon: rf.snapped.lon, ele: points[rf.segmentIndex].ele)]
            rest += points[(rf.segmentIndex + 1)...]
            remainingMinutes = rest.count >= 2 ? HikeEstimator.estimate(rest, pace: settings.pace).planningMinutes : 0.0
        }
        let threshold = settings.offRouteThresholdM
        let offRouteDistance = rf.offRouteM - Double(f.accuracyM.clamped(0, Float(threshold)))
        if offRouteDistance > Double(threshold) {
            daylight = nil
            daylightSun = nil
        } else if daylight == nil || now - lastDaylightMs >= 30_000 || routeStarted && !wasStarted {
            events += updateDaylight(route, rf, now, zone)
        }
        switch detector.update(rf.offRouteM, accuracyM: Double(f.accuracyM)) {
        case .leftRoute:
            offRoute = true
            events.append(.leftRoute(offRouteM: rf.offRouteM, backBearingDeg: Geo.bearingDeg(f.position, rf.snapped)))
        case .rejoinedRoute:
            offRoute = false
            events.append(.rejoinedRoute)
        case .none:
            break
        }
        return events
    }

    private func updateDaylight(_ route: GuidedRoute, _ rf: RouteFix, _ now: Int64, _ zone: TimeZone) -> [GuidanceEvent] {
        lastDaylightMs = now
        let guide = route.guide
        let points = guide.points
        let i = rf.segmentIndex
        let ele: Double? = points[i].ele.map { elevation in
            let next = points[i + 1].ele ?? elevation
            let distance = guide.cumulative[i + 1] - guide.cumulative[i]
            return elevation + (next - elevation) * ((rf.alongM - guide.cumulative[i]) / distance).clamped(0.0, 1.0)
        }
        let snapped = TrackPoint(lat: rf.snapped.lat, lon: rf.snapped.lon, ele: ele)
        let walked = Array(points[0...i]) + [snapped]
        let remaining = [snapped] + Array(points[(i + 1)...])
        let today = CivilDate.localEpochDay(now, zone)
        let sun = Sun.times(epochDay: today, rf.snapped)
        daylightSun = sun
        let recorded = track.status != .idle ? TrackStats.summarize(track.points) : nil
        let movingMinutes: Double? = recorded.flatMap { r in
            rf.alongM >= 500 && r.distanceM >= rf.alongM * 0.6 && r.distanceM <= rf.alongM * 1.4 ? Double(r.movingMs) / 60_000.0 : nil
        }
        let margin = settings.daylightMarginMinutes
        let forecast = Daylight.estimate(nowMs: now, remaining: remaining, walked: walked, movingMinutes: movingMinutes,
                                         pace: settings.pace, sun: sun, marginMinutes: margin, zone: zone)
        daylight = forecast
        let walkKey = track.hikeId ?? -route.id
        if walkKey != alertWalkKey {
            alertWalkKey = walkKey
            let saved = daylightAlertState.split(separator: ":", omittingEmptySubsequences: false)
            let flags = saved.first.flatMap { Int64($0) } == walkKey ? (saved.count > 1 ? Int(saved[1]) ?? 0 : 0) : 0
            sunsetAlerted = flags & 1 != 0
            duskAlerted = flags & 2 != 0
        }
        let cutoff = sun.sunsetMs.map { $0 - Int64(margin) * 60_000 }
        var duskDue = false
        if routeStarted, let dusk = sun.civilDuskMs, forecast.afterCivilDusk == true { duskDue = forecast.finishMs > dusk + 2 * 60_000 }
        var sunsetDue = false
        if routeStarted, let cutoff, forecast.afterSafeSunset == true { sunsetDue = forecast.finishMs > cutoff + 2 * 60_000 }
        let alert = Daylight.alertDue(sunsetDue: sunsetDue, duskDue: duskDue, sunsetAlerted: sunsetAlerted, duskAlerted: duskAlerted)
        var events: [GuidanceEvent] = []
        if alert == 1 {
            sunsetAlerted = true
            if duskDue { duskAlerted = true }
            events.append(.daylightWarning(forecast, finishDayOffset: CivilDate.localEpochDay(forecast.finishMs, zone) - today,
                                           marginMinutes: margin))
        }
        if alert == 2 {
            duskAlerted = true
            events.append(.darkByFinish)
        }
        let state = "\(walkKey):\((sunsetAlerted ? 1 : 0) | (duskAlerted ? 2 : 0))"
        if daylightAlertState != state { daylightAlertState = state }
        return events
    }
}
