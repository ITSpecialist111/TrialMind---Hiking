import Combine
import Foundation
import UIKit

/// The followed route on the map (NavigationController.follow and stopFollowing, and MapScreen's route drawing): its
/// saved facilities, the LiDAR stretch picked on its page and, when no other feature does, its line, waypoints and
/// whole-kilometre or whole-mile marks thinned to stay readable. The route followed is `Prefs.activeRouteId`; live
/// guidance along it is the hikes feature's, from the same setting.
final class RouteFollow: ObservableObject {
    static let shared = RouteFollow()

    /// The route drawn on the map, or nil.
    @Published private(set) var route: RouteData?

    private var guide: RouteGuide?
    private var marks: [LatLon] = []
    private var every = 0
    private var facilitiesShown = false
    private var loadJob = 0
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let prefs = Prefs.shared
        // Every setting of the route is acted on, even of the same route: another feature may have drawn something
        // else in its place (retracing your steps) and be handing the map back.
        prefs.$activeRouteId.receive(on: DispatchQueue.main).sink { [weak self] id in self?.load(id) }.store(in: &cancellables)
        prefs.$imperial.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuildMarks() }
            .store(in: &cancellables)
        prefs.$showFacilities.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateFacilities() }
            .store(in: &cancellables)
        MapController.shared.$zoom.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.zoomChanged() }
            .store(in: &cancellables)
        OverpassFacilities.shared.$revision.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateFacilities() }
            .store(in: &cancellables)
        // Heights added or the route renamed: draw the stored route again.
        Store.shared.$revision.dropFirst().debounce(for: .milliseconds(400), scheduler: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshIfChanged()
        }.store(in: &cancellables)
    }

    /// The id of the followed route, or nil.
    var followingId: Int64? { Prefs.shared.activeRouteId > 0 ? Prefs.shared.activeRouteId : nil }

    /// The hikes feature's guidance (the service that sets `FeatureHooks.retrace`) draws the followed route with its
    /// waypoints and distance marks, and swaps in the way back while retracing; without it the line is drawn here.
    private var drawsLine: Bool { FeatureHooks.retrace == nil }

    func isFollowing(_ routeId: Int64) -> Bool { followingId == routeId }

    /// Follows a route: guidance starts and the map shows it. `done` gets the route, or nil if it no longer exists.
    func follow(_ routeId: Int64, done: ((RouteData?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Store.shared.routeData(routeId)
            DispatchQueue.main.async {
                if let data {
                    Prefs.shared.activeRouteId = routeId
                    self.draw(data)
                } else if Prefs.shared.activeRouteId == routeId {
                    Prefs.shared.activeRouteId = -1
                }
                done?(data)
            }
        }
    }

    func stopFollowing() {
        Prefs.shared.activeRouteId = -1
    }

    /// Follows the route if need be, then centres the map on a point of it.
    func show(_ routeId: Int64, at point: LatLon, zoom: Double) {
        if isFollowing(routeId) {
            RouteMap.centerOn(point, zoom: zoom)
        } else {
            follow(routeId) { if $0 != nil { RouteMap.centerOn(point, zoom: zoom) } }
        }
    }

    private func load(_ id: Int64) {
        loadJob += 1
        let job = loadJob
        guard id > 0 else { return clear() }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Store.shared.routeData(id)
            DispatchQueue.main.async {
                guard job == self.loadJob, Prefs.shared.activeRouteId == id else { return }
                if let data { self.draw(data) } else { Prefs.shared.activeRouteId = -1 }
            }
        }
    }

    private func refreshIfChanged() {
        guard let current = route, let id = followingId, current.meta.id == id else { return }
        DispatchQueue.global(qos: .utility).async {
            let meta = Store.shared.route(id)
            DispatchQueue.main.async {
                guard let meta else { return self.stopFollowing() }
                if meta != current.meta { self.load(id) }
            }
        }
    }

    private func clear() {
        route = nil
        guide = nil
        marks = []
        every = 0
        if drawsLine { MapController.shared.clearActiveRoute() }
        MapController.shared.setLine(RouteMap.lidarStretchLine, nil)
        updateFacilities()
    }

    private func draw(_ data: RouteData) {
        let changedRoute = route?.meta.id != data.meta.id
        route = data
        guide = try? RouteGuide(data.points, waypoints: data.waypoints)
        if changedRoute { MapController.shared.setLine(RouteMap.lidarStretchLine, nil) }
        rebuildMarks()
        updateFacilities()
    }

    private func rebuildMarks() {
        marks = guide.map { DistanceMarks.along($0, stepM: DistanceMarks.stepM(imperial: Prefs.shared.imperial)) } ?? []
        every = currentEvery()
        publishLine()
    }

    private func currentEvery() -> Int {
        let map = MapController.shared
        let stepPx = DistanceMarks.stepM(imperial: Prefs.shared.imperial) / WebMercator.metresPerPixel(map.center.lat, map.zoom)
        return DistanceMarks.every(stepPx: stepPx, minPx: 56)
    }

    private func zoomChanged() {
        guard route != nil else { return }
        let next = currentEvery()
        if next != every && drawsLine {
            every = next
            publishLine()
        }
        // Facilities show from zoom 13, as on Android, so a wide view isn't covered in them.
        if (MapController.shared.zoom >= 13) != facilitiesShown { updateFacilities() }
    }

    private func publishLine() {
        guard let data = route, drawsLine else { return }
        var pins = data.waypoints.enumerated().map { i, w in
            MapPin(id: "wp-\(i)", position: w.latLon(), title: w.name, subtitle: w.description, kind: .waypoint)
        }
        if every > 0 {
            for k in stride(from: every, through: marks.count, by: every) {
                pins.append(MapPin(id: "mark-\(k)", position: marks[k - 1], title: "\(k)", kind: .distanceMark))
            }
        }
        MapController.shared.setActiveRoute(data.points.map { $0.latLon() }, pins: pins)
    }

    /// The followed route's saved facilities on the map, when Settings show them (MapScreen.updateFacilities).
    func updateFacilities() {
        let id = followingId
        let show = id != nil && Prefs.shared.showFacilities && MapController.shared.zoom >= 13
        facilitiesShown = show
        guard show, let id else { return MapController.shared.setPins("facilities", []) }
        DispatchQueue.global(qos: .utility).async {
            let items = OverpassFacilities.shared.saved(id)?.items ?? []
            DispatchQueue.main.async {
                guard self.followingId == id, self.facilitiesShown else { return }
                let imperial = Prefs.shared.imperial
                MapController.shared.setPins("facilities", items.enumerated().map { i, item in
                    MapPin(id: "facility-\(i)", position: item.position, title: item.name.isBlank ? item.category.label : item.name,
                           subtitle: "\(item.category.label) · at \(Units.distance(item.alongM, imperial: imperial)), " +
                            "\(Units.distance(item.offM, imperial: imperial)) off route",
                           kind: .facility, symbol: RouteMap.symbol(item.category))
                })
            }
        }
    }
}

/// Map moves and marks the route pages ask for.
enum RouteMap {
    static let lidarStretchLine = "lidar-stretch"

    /// Shows the map and centres it on a point (MapScreen.centerOn).
    static func centerOn(_ p: LatLon, zoom: Double) {
        Navigator.shared.showMap()
        DispatchQueue.main.async { MapController.shared.centerOn(p, zoom: zoom) }
    }

    /// Shows the map and fits a box into its visible part (MapScreen.fit).
    static func fit(_ box: BoundingBox?) {
        guard let box else { return }
        Navigator.shared.showMap()
        DispatchQueue.main.async { MapController.shared.fit(box) }
    }

    /// Highlights a stretch of the followed route that the LiDAR check found.
    static func showStretch(_ points: [LatLon], crag: Bool) {
        MapController.shared.setLine(lidarStretchLine, points, color: crag ? UIColor(red: 130 / 255, green: 20 / 255, blue: 20 / 255, alpha: 1)
                                        : UIColor(red: 211 / 255, green: 47 / 255, blue: 47 / 255, alpha: 1), width: 7)
    }

    /// An SF Symbol for a facility's map pin.
    static func symbol(_ c: FacilityCategory) -> String {
        switch c {
        case .water: return "drop.fill"
        case .toilets: return "toilet.fill"
        case .pub: return "mug.fill"
        case .cafe: return "cup.and.saucer.fill"
        case .restaurant: return "fork.knife"
        case .shop: return "cart.fill"
        case .parking: return "parkingsign"
        case .bus: return "bus.fill"
        case .rail: return "tram.fill"
        case .camp: return "tent.fill"
        case .stay: return "bed.double.fill"
        case .shelter: return "house.fill"
        case .view: return "binoculars.fill"
        case .peak: return "mountain.2.fill"
        }
    }
}
