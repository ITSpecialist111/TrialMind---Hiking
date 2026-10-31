import Foundation

/// How the route finder looks for waymarked routes (RouteFinderPage.Mode).
enum RouteFinderMode: Hashable {
    case nearMe, mapView, search
}

/// What a GPX file gives the route library (MainActivity.importGpx): the line to follow, its name and waypoints.
struct RouteImportPlan: Hashable {
    var name: String
    var line: [TrackPoint]
    var waypoints: [Waypoint]
    /// No point of the line has a height, so the terrain model should fill them in.
    var needsTerrain: Bool

    static let noLineMessage = "No track or route with at least two points was found in this file."

    /// The route to save from `doc`; `fileName` (without its extension) names it when the file doesn't.
    static func prepare(_ doc: GpxDocument, fileName: String?) throws -> RouteImportPlan {
        let line = doc.primaryLine()
        guard line.count >= 2 else { throw GpxParseError(noLineMessage) }
        let name = doc.bestName() ?? fileName.flatMap { $0.isBlank ? nil : $0 } ?? "Imported route"
        return RouteImportPlan(name: name, line: line, waypoints: doc.waypoints, needsTerrain: !line.contains { $0.ele != nil })
    }

    /// A file's name without its extension (Kotlin's `substringBeforeLast('.')`).
    static func baseName(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: ".") else { return fileName }
        return String(fileName[..<dot])
    }
}

extension RouteText {
    // MARK: Route finder

    /// Routes "near me" are those within this of the GPS position.
    static let nearM = 10_000.0

    static func finderSubtitle(_ t: WaymarkedTrails.Trail) -> String {
        ([t.kind] + (t.ref.flatMap { $0 != t.name ? $0 : nil }.map { [$0] } ?? [])).joined(separator: " · ")
    }

    static func finderLoading(_ mode: RouteFinderMode) -> String {
        mode == .search ? "Searching…" : "Looking for waymarked routes…"
    }

    static func finderEmpty(_ mode: RouteFinderMode, searched: String) -> String {
        mode == .search ? "No waymarked route is called \"\(searched)\". Try part of the name."
            : "No waymarked routes here. Zoom the map out and try \"In map view\", or search by name."
    }

    static func finderHeading(_ mode: RouteFinderMode, searched: String, noFix: Bool, imperial: Bool) -> String {
        switch mode {
        case .search: return "Routes matching \"\(searched)\""
        case .mapView: return "Routes in the map view"
        case .nearMe:
            return noFix ? "No GPS fix yet, so these are routes around the map centre"
                : "Routes within \(Units.distance(nearM, imperial: imperial)) of you"
        }
    }

    static let finderNote = "These are signed routes mapped in OpenStreetMap: national trails, regional ways and local waymarked walks. " +
        "Tap one to add it to your routes. " + WaymarkedTrails.attribution

    static func finderAdded(hasElevation: Bool, lengthM: Double, imperial: Bool) -> String {
        if hasElevation { return "Route added" }
        if lengthM > WaymarkedTrails.elevationMaxM {
            return "Route added. Heights are only downloaded for routes up to \(Units.distance(WaymarkedTrails.elevationMaxM, imperial: imperial))."
        }
        return "Route added without heights"
    }

    // MARK: Route planner

    /// The planner card's status line.
    static func plannerStatus(pending: Bool, points: Int) -> String {
        if pending { return "Finding a path…" }
        if points == 0 { return "Tap the map to add a start point." }
        return points == 1 ? "1 point" : "\(points) points"
    }

    static let plannerOffline = "Offline: this leg is a straight line"
    static let plannerNoPath = "No path found here, so this leg is a straight line"
    static let plannerUnavailable = "Routing service unavailable, so this leg is a straight line"

    /// Why a leg stayed a straight line.
    static func plannerNotice(offline: Bool, noPath: Bool) -> String {
        offline ? plannerOffline : (noPath ? plannerNoPath : plannerUnavailable)
    }

    // MARK: Route page

    /// A facility's line under its name: what it is, where along the route, how far off it, hours and height.
    static func facilityDetail(_ item: Facility, imperial: Bool) -> String {
        var s = "\(item.category.label) · at \(Units.distance(item.alongM, imperial: imperial)), " +
            "\(Units.distance(item.offM, imperial: imperial)) off route"
        if !item.openingHours.isBlank { s += " · Hours: \(item.openingHours)" }
        if let ele = RoutesJSON.parseJavaDouble(item.ele), ele.isFinite { s += " · \(Units.elevation(ele, imperial: imperial)) high" }
        return s
    }

    static func facilityTitle(_ item: Facility) -> String { item.name.isBlank ? item.category.label : item.name }

    /// The category chips: each category found, in the order first met along the route, with its count.
    static func facilityCounts(_ items: [Facility]) -> [(category: FacilityCategory, count: Int)] {
        var order: [FacilityCategory] = []
        var counts: [FacilityCategory: Int] = [:]
        for item in items {
            if counts[item.category] == nil { order.append(item.category) }
            counts[item.category, default: 0] += 1
        }
        return order.map { ($0, counts[$0]!) }
    }

    static func lidarSteepTitle(_ s: LidarSection, imperial: Bool) -> String {
        "At \(Units.distance(s.startM, imperial: imperial)) · \(kRound(s.value))°"
    }

    static func lidarSteepDetail(_ s: LidarSection, imperial: Bool) -> String {
        "For \(Units.distance(s.endM - s.startM, imperial: imperial)) along the line. Tap to see it."
    }

    static func lidarCragTitle(_ s: LidarSection, imperial: Bool) -> String {
        "At \(Units.distance(s.startM, imperial: imperial)) · " +
            (s.value < 1 ? "on the line" : "\(Units.distance(s.value, imperial: imperial)) away")
    }

    static func lidarCragDetail(_ s: LidarSection, imperial: Bool) -> String {
        "For \(Units.distance(max(s.endM - s.startM, 1.0), imperial: imperial)) along the line. Tap to see it."
    }

    /// The note under the LiDAR check button: how much it downloads. `squares` is nil while it is worked out.
    static func lidarDownloadNote(squares: Int?, missing: Int, online: Bool, decimalSeparator: String = ".") -> String {
        guard squares != nil else { return "Working out the download…" }
        if missing == 0 { return "The LiDAR for this route is on the phone." }
        let size = LidarSource.megabytes(missing, decimalSeparator: decimalSeparator)
        return online ? "Downloads about \(size) and keeps it on the phone." : "Needs normal signal to download about \(size)."
    }

    static func lidarProgress(done: Int, total: Int) -> String {
        total == 0 ? "Starting…" : "Downloading LiDAR: \(done) of \(total) squares… You can leave this page."
    }

    /// A waypoint's line: six-figure grid reference (or coordinates), height and description.
    static func waypointDetail(_ w: Waypoint, imperial: Bool) -> String {
        (OsGrid.fromWgs84(w.latLon())?.format(6) ?? Units.latLon(w.lat, w.lon)) +
            (w.ele.map { " · \(Units.elevation($0, imperial: imperial))" } ?? "") + (w.description.map { " · \($0)" } ?? "")
    }
}
