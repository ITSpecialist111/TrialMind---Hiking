import Foundation

struct PlanPart: Hashable {
    var points: [TrackPoint]
    var snapped: Bool
}

/// One leg of a plan, between two control points. A class because a router reply names the leg it was asked about:
/// a leg undone and added again must not match it, even though the two are equal by value.
final class PlanLeg: Hashable {
    let start: LatLon
    let end: LatLon
    let points: [TrackPoint]
    let snapped: Bool
    let parts: [PlanPart]

    init(start: LatLon, end: LatLon, points: [TrackPoint], snapped: Bool, parts: [PlanPart]? = nil) {
        self.start = start
        self.end = end
        self.points = points
        self.snapped = snapped
        self.parts = parts ?? [PlanPart(points: points, snapped: snapped)]
    }

    func copy(points: [TrackPoint]? = nil, snapped: Bool? = nil, parts: [PlanPart]? = nil) -> PlanLeg {
        PlanLeg(start: start, end: end, points: points ?? self.points, snapped: snapped ?? self.snapped, parts: parts ?? self.parts)
    }

    static func == (a: PlanLeg, b: PlanLeg) -> Bool {
        a.start == b.start && a.end == b.end && a.points == b.points && a.snapped == b.snapped && a.parts == b.parts
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(start)
        hasher.combine(end)
        hasher.combine(points)
        hasher.combine(snapped)
        hasher.combine(parts)
    }
}

final class RoutePlan {
    private var controls: [LatLon] = []
    private var segments: [PlanLeg] = []
    var controlPoints: [LatLon] { controls }
    var legs: [PlanLeg] { segments }
    var isLoop: Bool { !segments.isEmpty && controls.last == controls.first }

    @discardableResult
    func add(_ point: LatLon) -> Bool {
        if !point.isValid || isLoop || controls.last == point { return false }
        if let start = controls.last {
            segments.append(PlanLeg(start: start, end: point,
                points: [TrackPoint(lat: start.lat, lon: start.lon), TrackPoint(lat: point.lat, lon: point.lon)], snapped: false))
        }
        controls.append(point)
        return true
    }

    @discardableResult
    func backToStart() -> Bool { controls.count >= 2 && !isLoop ? add(controls[0]) : false }

    @discardableResult
    func replaceLeg(_ index: Int, _ points: [TrackPoint], expected: PlanLeg? = nil) -> Bool {
        guard segments.indices.contains(index) else { return false }
        let leg = segments[index]
        if let expected, leg !== expected { return false }
        if points.count < 2 || points.contains(where: { !$0.latLon().isValid || $0.ele?.isFinite == false }) { return false }
        let first = points[0].latLon()
        let last = points[points.count - 1].latLon()
        if !zip(points, points.dropFirst()).contains(where: { a, b in a.lat != b.lat || a.lon != b.lon }) { return false }
        if Geo.distanceM(first, leg.start) > 250 || Geo.distanceM(last, leg.end) > 250 { return false }
        var line: [TrackPoint] = []
        line.append(TrackPoint(lat: leg.start.lat, lon: leg.start.lon, ele: points[0].ele))
        if first != leg.start { line.append(points[0]) }
        line.append(contentsOf: points.dropFirst())
        if last != leg.end { line.append(TrackPoint(lat: leg.end.lat, lon: leg.end.lon, ele: points[points.count - 1].ele)) }
        var parts: [PlanPart] = []
        let startConnector = Geo.distanceM(first, leg.start) > 5
        let endConnector = Geo.distanceM(last, leg.end) > 5
        if startConnector { parts.append(PlanPart(points: Array(line.prefix(2)), snapped: false)) }
        parts.append(PlanPart(points: Array(line[(startConnector ? 1 : 0)..<(line.count - (endConnector ? 1 : 0))]), snapped: true))
        if endConnector { parts.append(PlanPart(points: Array(line.suffix(2)), snapped: false)) }
        segments[index] = leg.copy(points: line, snapped: true, parts: parts)
        return true
    }

    @discardableResult
    func undo() -> Bool {
        if controls.isEmpty { return false }
        controls.removeLast()
        if !segments.isEmpty { segments.removeLast() }
        return true
    }

    func clear() {
        controls.removeAll()
        segments.removeAll()
    }

    var line: [TrackPoint] {
        if segments.isEmpty { return controls.first.map { [TrackPoint(lat: $0.lat, lon: $0.lon)] } ?? [] }
        var joined: [TrackPoint] = []
        for leg in segments {
            if joined.isEmpty {
                joined.append(leg.points[0])
            } else if joined[joined.count - 1].ele == nil && leg.points[0].ele != nil {
                joined[joined.count - 1] = leg.points[0]
            }
            joined.append(contentsOf: leg.points.dropFirst())
        }
        return joined
    }

    func estimate(_ pace: PaceSettings) -> HikeEstimate { HikeEstimator.estimate(line, pace: pace) }
}
