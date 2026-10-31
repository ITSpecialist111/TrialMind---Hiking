import Foundation

struct GpxTrack: Hashable {
    var name: String?
    var segments: [[TrackPoint]]
}

struct GpxRoute: Hashable {
    var name: String?
    var points: [TrackPoint]
}

struct GpxDocument: Hashable {
    var name: String?
    var tracks: [GpxTrack]
    var routes: [GpxRoute]
    var waypoints: [Waypoint]

    var isEmpty: Bool {
        tracks.allSatisfy { t in t.segments.allSatisfy { $0.isEmpty } } && routes.allSatisfy { $0.points.isEmpty } && waypoints.isEmpty
    }

    /// Best display name: metadata, then first track/route name.
    func bestName() -> String? {
        if let n = name, !n.isBlank { return n }
        if let t = tracks.first(where: { !($0.name ?? "").isBlank }) { return t.name }
        return routes.first(where: { !($0.name ?? "").isBlank })?.name
    }

    /// The line to follow: planned routes (`rte`) win over tracks (`trk`) because they are the intended path; tracks are
    /// concatenated in order.
    func primaryLine() -> [TrackPoint] {
        if let route = routes.max(by: { $0.points.count < $1.points.count }), route.points.count >= 2 { return route.points }
        return tracks.flatMap { $0.segments.flatMap { $0 } }
    }
}

struct GpxParseError: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension String {
    /// Kotlin's `isBlank()`.
    var isBlank: Bool { allSatisfy { $0.isWhitespace } }
}
