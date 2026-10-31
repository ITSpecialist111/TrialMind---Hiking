import MapKit
import SwiftUI

/// A marker for a trip-group member (frontier/group): colour, label and how fresh/trustworthy the position is.
struct GroupMarker: Identifiable, Hashable {
    enum Freshness: Hashable { case live, faded, hollow }
    var id: Int
    var name: String
    var position: LatLon
    var colour: UInt32
    var freshness: Freshness = .live
    /// Heard through another member rather than directly (drawn dashed).
    var relayed = false
    var needsHelp = false
}

/// A point of interest drawn on the map (facility, waypoint, LiDAR hazard...).
struct MapPin: Identifiable, Hashable {
    enum Kind: Hashable { case waypoint, facility, search, target, hazard, distanceMark, planner }
    var id: String
    var position: LatLon
    var title: String
    var subtitle: String? = nil
    var kind: Kind
    var symbol: String? = nil
}

/// Everything the map shows and where it looks (the Android MapScreen/TileMapView state), driven by any feature.
/// TrailMapView mirrors it onto MapKit.
final class MapController: ObservableObject {
    static let shared = MapController()

    weak var mapView: MKMapView?

    /// The uncovered part of the map, in map-view coordinates (beside a pane, above the capsule, away from the fold).
    var visibleArea: CGRect = .zero

    // MARK: Camera state
    @Published var follow = false
    @Published private(set) var zoom: Double = Prefs.shared.mapZoom
    @Published private(set) var center = LatLon(Prefs.shared.mapLat, Prefs.shared.mapLon)
    /// Degrees clockwise from north at the top of the map.
    @Published private(set) var mapHeading: Double = 0
    /// Why heading-up cannot turn the map right now (no usable course or compass), shown in orange on the control.
    @Published var headingUnavailable = false

    // MARK: Content (each change bumps `revision`, which TrailMapView syncs)
    @Published private(set) var revision = 0
    private(set) var routeLine: [LatLon] = []
    private(set) var routePins: [MapPin] = []
    private(set) var liveTrack: [[LatLon]] = []
    private(set) var shownTrack: [[LatLon]] = []
    private(set) var pins: [String: [MapPin]] = [:]
    private(set) var lines: [String: (points: [LatLon], color: UIColor, width: CGFloat, dashed: Bool)] = [:]
    private(set) var areas: [String: (rings: [[LatLon]], stroke: UIColor, fill: UIColor)] = [:]
    @Published private(set) var groupMarkers: [GroupMarker] = []
    /// Extra tile overlays from features (steep ground, LiDAR), by id with an opacity, drawn above the base map.
    private(set) var tileOverlays: [String: (overlay: MKTileOverlay, alpha: CGFloat, order: Int)] = [:]
    @Published private(set) var searchPin: MapPin? = nil
    @Published private(set) var target: MapPin? = nil
    @Published private(set) var showingTrack = false

    /// Long-press handler (MapScreen shows the point menu); features can take it over (the route planner).
    var longPressOverride: ((LatLon) -> Void)?
    /// Tap handler for the planner.
    var tapOverride: ((LatLon) -> Void)?
    /// Selection of a pin or group member.
    var onSelectPin: ((MapPin) -> Void)?
    var onSelectMember: ((GroupMarker) -> Void)?

    private func bump() { revision &+= 1 }

    // MARK: Camera

    /// Centres on the GPS position and follows it; asks for permission the first time.
    func locate() {
        let hub = LocationHub.shared
        if !hub.hasPermission { hub.requestPermission(); return }
        follow = true
        if let fix = hub.latest { centerOn(fix.latLon, zoom: max(zoom, 15), keepFollow: true) }
    }

    func centerOn(_ p: LatLon, zoom z: Double? = nil, animated: Bool = true, keepFollow: Bool = false) {
        if !keepFollow { follow = false }
        guard let map = mapView, map.bounds.width > 0 else {
            center = p
            if let z { zoom = z }
            return
        }
        let targetZoom = (z ?? zoom).clamped(2, 21)
        let h = toRadians(mapHeading)
        // Shift so the point sits in the middle of the uncovered part: screen offset -> map points, against the rotation.
        let offset = offsetToVisibleCenter(size: map.bounds.size)
        let scale = pow(2.0, 20.0 - targetZoom)
        let mdx = (offset.x * cos(h) - offset.y * sin(h)) * scale
        let mdy = (offset.x * sin(h) + offset.y * cos(h)) * scale
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
        let centerPoint = MKMapPoint(x: point.x - mdx, y: point.y - mdy)
        let camera = MKMapCamera(lookingAtCenter: centerPoint.coordinate,
                                 fromDistance: distance(forZoom: targetZoom, in: map), pitch: 0, heading: mapHeading)
        map.setCamera(camera, animated: animated)
    }

    /// Camera distance for a zoom level, scaled from the current camera so it holds whatever MapKit's field of view is.
    func distance(forZoom z: Double, in map: MKMapView) -> CLLocationDistance {
        let current = MapController.zoom(of: map) ?? zoom
        return max(50, map.camera.centerCoordinateDistance * pow(2.0, current - z))
    }

    /// The Web Mercator zoom the map is showing, from metres per point measured across the middle of the view.
    static func zoom(of map: MKMapView) -> Double? {
        let mid = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        let a = map.convert(CGPoint(x: mid.x - 50, y: mid.y), toCoordinateFrom: map)
        let b = map.convert(CGPoint(x: mid.x + 50, y: mid.y), toCoordinateFrom: map)
        let metres = Geo.distanceM(a.latitude, a.longitude, b.latitude, b.longitude)
        guard metres > 0 else { return nil }
        let mpp = metres / 100
        let lat = map.centerCoordinate.latitude
        return log2(156_543.033_92 * cos(toRadians(lat)) / mpp)
    }

    /// The vector from the map view's centre to the middle of the visible area, in points.
    private func offsetToVisibleCenter(size: CGSize) -> CGPoint {
        guard visibleArea.width > 0, visibleArea.height > 0 else { return .zero }
        return CGPoint(x: visibleArea.midX - size.width / 2, y: visibleArea.midY - size.height / 2)
    }

    /// Fits a box into the visible area, with a margin.
    func fit(_ box: BoundingBox?, maxZoom: Double = 17) {
        guard let box else { return }
        follow = false
        guard let map = mapView else { center = box.center; return }
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: box.maxLat, longitude: box.minLon))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: box.minLat, longitude: box.maxLon))
        var rect = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: max(abs(b.x - a.x), 1), height: max(abs(b.y - a.y), 1))
        let size = map.bounds.size
        let area = visibleArea.width > 0 ? visibleArea : CGRect(origin: .zero, size: size)
        let padding = UIEdgeInsets(top: area.minY + 32, left: area.minX + 32, bottom: size.height - area.maxY + 32, right: size.width - area.maxX + 32)
        let minWidth = size.width * pow(2.0, 20.0 - maxZoom)
        if rect.size.width < minWidth {
            rect = rect.insetBy(dx: -(minWidth - rect.size.width) / 2, dy: -(minWidth - rect.size.width) / 2)
        }
        mapHeading = 0
        map.setVisibleMapRect(rect, edgePadding: padding, animated: true)
    }

    /// Turns the map so `deg` (true) is at the top, animating along the shortest arc.
    func setHeading(_ deg: Double, animated: Bool = true) {
        mapHeading = Geo.normalizeDeg(deg)
        guard let map = mapView else { return }
        if follow, let fix = LocationHub.shared.latest {
            centerOn(fix.latLon, zoom: nil, animated: animated, keepFollow: true)
        } else {
            let cam = map.camera.copy() as! MKMapCamera
            cam.heading = mapHeading
            map.setCamera(cam, animated: animated)
        }
    }

    /// Called by TrailMapView when the camera settles.
    func cameraChanged(center c: LatLon, zoom z: Double, heading h: Double) {
        center = c
        zoom = z
        mapHeading = h
    }

    func saveCamera() {
        Prefs.shared.mapLat = center.lat
        Prefs.shared.mapLon = center.lon
        Prefs.shared.mapZoom = zoom
    }

    /// Following: keep the newest fix in the middle of the visible area.
    func onFix(_ fix: Fix) {
        guard follow else { return }
        centerOn(fix.latLon, zoom: nil, animated: true, keepFollow: true)
    }

    // MARK: Content

    /// The followed route's line, waypoints and distance marks.
    func setActiveRoute(_ points: [LatLon], pins routePins: [MapPin]) {
        routeLine = points
        self.routePins = routePins
        bump()
    }

    func clearActiveRoute() { setActiveRoute([], pins: []) }

    /// The hike being recorded: one array per segment (pauses break the line).
    func setLiveTrack(_ segments: [[LatLon]]) {
        liveTrack = segments
        bump()
    }

    /// A past hike drawn from the Hikes page, with a chip to clear it.
    func showTrack(_ segments: [[TrackPoint]]) {
        shownTrack = segments.map { $0.map { $0.latLon() } }
        showingTrack = !shownTrack.isEmpty
        bump()
        let all = segments.flatMap { $0 }.map { $0.latLon() }
        fit(BoundingBox.of(all))
    }

    func clearShownTrack() {
        shownTrack = []
        showingTrack = false
        bump()
    }

    /// A named group of pins (facilities, LiDAR hazards, planner points...). An empty array removes the group.
    func setPins(_ group: String, _ list: [MapPin]) {
        if list.isEmpty { pins[group] = nil } else { pins[group] = list }
        bump()
    }

    /// A named extra line (go-to bearing line, planned route, LiDAR stretch). Nil removes it.
    func setLine(_ id: String, _ points: [LatLon]?, color: UIColor = .systemPurple, width: CGFloat = 4, dashed: Bool = false) {
        if let points, points.count >= 2 { lines[id] = (points, color, width, dashed) } else { lines[id] = nil }
        bump()
    }

    /// Named outlined areas (offline packs' coverage). Nil removes them.
    func setAreas(_ id: String, _ rings: [[LatLon]]?, stroke: UIColor, fill: UIColor) {
        if let rings, !rings.isEmpty { areas[id] = (rings, stroke, fill) } else { areas[id] = nil }
        bump()
    }

    func setGroupMarkers(_ markers: [GroupMarker]) {
        groupMarkers = markers
        bump()
    }

    /// Adds, replaces or (with nil) removes a feature's tile overlay. Higher `order` draws on top.
    func setTileOverlay(_ id: String, _ overlay: MKTileOverlay?, alpha: CGFloat = 1, order: Int = 0) {
        if let overlay { tileOverlays[id] = (overlay, alpha, order) } else { tileOverlays[id] = nil }
        bump()
    }

    func showSearchPin(name: String, position: LatLon, zoom z: Double) {
        searchPin = MapPin(id: "search", position: position, title: name, kind: .search)
        bump()
        centerOn(position, zoom: z)
    }

    func clearSearchPin() {
        searchPin = nil
        bump()
    }

    /// "Go to" a point: a target pin and a dashed bearing line from the GPS position.
    func setTarget(_ name: String?, _ position: LatLon?) {
        if let name, let position {
            target = MapPin(id: "target", position: position, title: name, kind: .target)
        } else {
            target = nil
        }
        bump()
    }
}
