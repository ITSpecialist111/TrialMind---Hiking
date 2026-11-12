import Foundation

/// Turns the map for heading-up (MapScreen.updateHeading): GPS course while walking, a fresh reliable compass when
/// still, otherwise the last direction is held and the north control turns orange (`MapController.headingUnavailable`).
final class MapHeadingDriver {
    static let shared = MapHeadingDriver()
    private var timer: Timer?
    private var lastApplied: Double?
    private var wasHeadingUp = false

    func start() {
        guard timer == nil else { return }
        LocationHub.shared.addHeadingListener { [weak self] in self?.update() }
        LocationHub.shared.addListener { [weak self] _ in self?.update() }
        // Readings expire (2 s compass, 5 s course), so re-evaluate even when nothing new arrives.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
    }

    func update() {
        let map = MapController.shared
        let headingUp = Prefs.shared.mapHeadingUp
        defer { wasHeadingUp = headingUp }
        guard headingUp else {
            if map.headingUnavailable { map.headingUnavailable = false }
            lastApplied = nil
            return
        }
        let hub = LocationHub.shared
        let now = nowMs()
        let compass = hub.headingDeg.map { MapHeading.Reading($0, hub.headingAtMs) }
        var course: MapHeading.Course? = nil
        if let f = hub.latest, let c = f.courseDeg, let speed = f.speedMps {
            course = MapHeading.Course(MapHeading.Reading(c, f.timeMs), speed, Double(f.accuracyM), f.courseAccuracyDeg, f.speedAccuracyMps)
        }
        let result = MapHeading.choose(now, compass, !hub.compassUnreliable, course)
        guard let degrees = result.degrees else {
            if !map.headingUnavailable { map.headingUnavailable = true }
            return
        }
        if map.headingUnavailable { map.headingUnavailable = false }
        // Turn only for a visible change, so the map is calm while walking a straight line.
        if !wasHeadingUp || lastApplied == nil || abs(Geo.angleDiffDeg(lastApplied!, degrees)) >= 2 {
            lastApplied = degrees
            map.setHeading(degrees)
        }
    }
}
