import MapKit
import SwiftUI

/// A Web Mercator raster source drawn through TileLoader (packs, cache, network, enlargement).
final class SourceTileOverlay: MKTileOverlay {
    let source: TileSource

    init(source: TileSource, replacesMap: Bool) {
        self.source = source
        super.init(urlTemplate: nil)
        minimumZ = max(0, source.minZoom)
        maximumZ = 21
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = replacesMap
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        TileLoader.shared.load(source, TileKey(path.z, path.x, path.y)) { data in result(data, nil) }
    }
}

/// OS Explorer & Landranger: British National Grid tiles, each warped onto the requested Web Mercator tile through its
/// corners (TileMapView's BNG drawing), so routes and the GPS dot line up with the paper-map style.
final class BngTileOverlay: MKTileOverlay {
    let source: TileSource
    private static func span(_ z: Int) -> Double { Double(BngTiles.tileSize) * BngTiles.resolution(z) }

    init(source: TileSource, replacesMap: Bool) {
        self.source = source
        super.init(urlTemplate: nil)
        minimumZ = 5
        maximumZ = 21
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = replacesMap
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let z = Double(path.z)
        let x0 = Double(path.x) * 256, y0 = Double(path.y) * 256
        let corners = [(x0, y0), (x0 + 256, y0), (x0, y0 + 256), (x0 + 256, y0 + 256)].map {
            LatLon(WebMercator.yToLat($0.1, z), WebMercator.xToLon($0.0, z))
        }
        let refs = corners.map { OsGrid.project($0) }
        let minE = refs.map(\.easting).min()!, maxE = refs.map(\.easting).max()!
        let minN = refs.map(\.northing).min()!, maxN = refs.map(\.northing).max()!
        if maxE < 0 || minE > BngTiles.gbMaxE || maxN < 0 || minN > BngTiles.gbMaxN { return result(nil, nil) }
        let midLat = (corners[0].lat + corners[3].lat) / 2
        let mpp = WebMercator.metresPerPixel(midLat, z)
        var bz = BngTiles.zoomFor(mpp, source.minZoom, source.maxZoom)
        if source.isPremium(bz), TileLoader.shared.premiumDenied(source), let from = source.premiumFromZoom { bz = from - 1 }
        let col0 = BngTiles.column(max(minE, 0), bz)
        let col1 = BngTiles.column(min(maxE, BngTiles.gbMaxE), bz)
        let row0 = BngTiles.row(min(maxN, BngTiles.gbMaxN), bz)
        let row1 = BngTiles.row(max(minN, 0), bz)
        guard col1 >= col0, row1 >= row0, (col1 - col0 + 1) * (row1 - row0 + 1) <= 16 else { return result(nil, nil) }
        let group = DispatchGroup()
        let lock = NSLock()
        var images: [(col: Int, row: Int, image: CGImage)] = []
        for col in col0...col1 {
            for row in row0...row1 {
                group.enter()
                TileLoader.shared.load(source, TileKey(bz, col, row)) { data in
                    if let data, let image = UIImage(data: data)?.cgImage { lock.withLock { images.append((col, row, image)) } }
                    group.leave()
                }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            guard !images.isEmpty else { return result(nil, nil) }
            func pixel(_ e: Double, _ n: Double) -> CGPoint {
                let p = OsGrid.toWgs84(e, n)
                return CGPoint(x: WebMercator.lonToX(p.lon, z) - x0, y: WebMercator.latToY(p.lat, z) - y0)
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { ctx in
                let cg = ctx.cgContext
                cg.interpolationQuality = .medium
                for tile in images {
                    let e0 = BngTiles.easting(tile.col, bz)
                    let n0 = BngTiles.northing(tile.row, bz)
                    let tl = pixel(e0, n0)
                    let tr = pixel(e0 + Self.span(bz), n0)
                    let bl = pixel(e0, n0 - Self.span(bz))
                    // Affine through three corners; half a pixel of overlap so neighbouring tiles leave no seams.
                    let w = CGFloat(tile.image.width), h = CGFloat(tile.image.height)
                    let t = CGAffineTransform(a: (tr.x - tl.x) / w, b: (tr.y - tl.y) / w, c: (bl.x - tl.x) / h, d: (bl.y - tl.y) / h,
                                              tx: tl.x, ty: tl.y)
                    cg.saveGState()
                    cg.concatenate(t)
                    UIImage(cgImage: tile.image).draw(in: CGRect(x: -0.5, y: -0.5, width: w + 1, height: h + 1))
                    cg.restoreGState()
                }
            }
            result(image.pngData(), nil)
        }
    }
}

/// A styled line: route (purple with a white casing), track (orange), dashed bearing lines and the like.
final class StyledPolyline: MKPolyline {
    var color: UIColor = .systemPurple
    var width: CGFloat = 4
    var dashed = false
    var casing = false
}

final class AreaPolygon: MKPolygon {
    var stroke: UIColor = .systemGreen
    var fill: UIColor = .clear
}

final class PinAnnotation: NSObject, MKAnnotation {
    let pin: MapPin
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: pin.position.lat, longitude: pin.position.lon) }
    var title: String? { pin.title }
    var subtitle: String? { pin.subtitle }
    init(_ pin: MapPin) { self.pin = pin }
}

final class MemberAnnotation: NSObject, MKAnnotation {
    let marker: GroupMarker
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: marker.position.lat, longitude: marker.position.lon) }
    var title: String? { marker.name }
    init(_ marker: GroupMarker) { self.marker = marker }
}

/// The map (TileMapView): MapKit with TrailMind's own tile sources, overlays and markers.
struct TrailMapView: UIViewRepresentable {
    @ObservedObject var controller: MapController
    @ObservedObject var prefs: Prefs
    var palette: Palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        let start = CLLocationCoordinate2D(latitude: prefs.mapLat, longitude: prefs.mapLon)
        let span = 360.0 / pow(2.0, prefs.mapZoom) * 2
        map.setRegion(MKCoordinateRegion(center: start, span: MKCoordinateSpan(latitudeDelta: span / 2, longitudeDelta: span)), animated: false)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        press.minimumPressDuration = 0.5
        map.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userPanned(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        controller.mapView = map
        context.coordinator.syncBase(map, force: true)
        context.coordinator.syncContent(map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncBase(map, force: false)
        if context.coordinator.shownRevision != controller.revision { context.coordinator.syncContent(map) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: TrailMapView
        var shownRevision = -1
        private var baseKey = ""
        private var historicKey = ""
        private var baseOverlay: MKTileOverlay?
        private var historicOverlay: MKTileOverlay?
        private var historicAlpha: CGFloat = 0.55
        private var featureOverlays: [String: MKTileOverlay] = [:]
        private var featureAlpha: [ObjectIdentifier: CGFloat] = [:]
        private var lineOverlays: [MKOverlay] = []
        private var annotations: [MKAnnotation] = []

        init(_ parent: TrailMapView) { self.parent = parent }

        // MARK: Layers

        func syncBase(_ map: MKMapView, force: Bool) {
            let prefs = parent.prefs
            let source = TileSources.builtIns().first { $0.id == prefs.baseSourceId } ?? TileSources.builtIns()[0]
            let key = "\(source.id)|\(prefs.osApiKey.isEmpty)|\(prefs.offlineOnly)"
            if force || key != baseKey {
                baseKey = key
                if let old = baseOverlay { map.removeOverlay(old) }
                baseOverlay = nil
                if !source.appleMap {
                    // Apple's muted map stays underneath, so places a layer doesn't cover (outside Great Britain for
                    // OS maps) and tiles still on their way show a map rather than an empty grid. Offline-only mode
                    // replaces it, so MapKit fetches nothing of its own.
                    let replaces = prefs.offlineOnly
                    let overlay: MKTileOverlay = source.grid == .britishNationalGrid
                        ? BngTileOverlay(source: source, replacesMap: replaces) : SourceTileOverlay(source: source, replacesMap: replaces)
                    map.insertOverlay(overlay, at: 0, level: .aboveLabels)
                    baseOverlay = overlay
                }
            }
            let historic = TileSources.historic().first { $0.id == prefs.historicOverlayId }
            let hKey = "\(historic?.id ?? "")|\(prefs.mapTilerKey.isEmpty)"
            let alpha = CGFloat(prefs.historicOverlayPercent) / 100
            if force || hKey != historicKey {
                historicKey = hKey
                if let old = historicOverlay { map.removeOverlay(old) }
                historicOverlay = nil
                if let historic {
                    let overlay = SourceTileOverlay(source: historic, replacesMap: false)
                    historicAlpha = alpha
                    if let base = baseOverlay { map.insertOverlay(overlay, above: base) } else { map.addOverlay(overlay, level: .aboveLabels) }
                    historicOverlay = overlay
                }
            } else if alpha != historicAlpha, let overlay = historicOverlay {
                historicAlpha = alpha
                (map.renderer(for: overlay) as? MKTileOverlayRenderer)?.alpha = alpha
            }
        }

        // MARK: Content

        func syncContent(_ map: MKMapView) {
            let c = parent.controller
            shownRevision = c.revision
            let p = parent.palette

            // Feature tile overlays (steep ground, LiDAR...).
            let wanted = c.tileOverlays
            for (id, overlay) in featureOverlays where wanted[id]?.overlay !== overlay {
                map.removeOverlay(overlay)
                featureOverlays[id] = nil
            }
            for (id, entry) in wanted.sorted(by: { $0.value.order < $1.value.order }) {
                featureAlpha[ObjectIdentifier(entry.overlay)] = entry.alpha
                if featureOverlays[id] == nil {
                    map.addOverlay(entry.overlay, level: .aboveLabels)
                    featureOverlays[id] = entry.overlay
                } else {
                    (map.renderer(for: entry.overlay) as? MKTileOverlayRenderer)?.alpha = entry.alpha
                }
            }

            map.removeOverlays(lineOverlays)
            lineOverlays = []
            func addLine(_ points: [LatLon], color: UIColor, width: CGFloat, dashed: Bool = false, casing: Bool = false) {
                guard points.count >= 2 else { return }
                var coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                if casing {
                    let under = StyledPolyline(coordinates: &coords, count: coords.count)
                    under.color = UIColor.white.withAlphaComponent(0.9)
                    under.width = width + 3
                    under.casing = true
                    lineOverlays.append(under)
                }
                let line = StyledPolyline(coordinates: &coords, count: coords.count)
                line.color = color
                line.width = width
                line.dashed = dashed
                lineOverlays.append(line)
            }
            for (id, area) in c.areas.sorted(by: { $0.key < $1.key }) {
                _ = id
                for ring in area.rings where ring.count >= 3 {
                    var coords = ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    let poly = AreaPolygon(coordinates: &coords, count: coords.count)
                    poly.stroke = area.stroke
                    poly.fill = area.fill
                    lineOverlays.append(poly)
                }
            }
            addLine(c.routeLine, color: p.routeUI, width: 5, casing: true)
            for seg in c.shownTrack { addLine(seg, color: p.trackUI, width: 4, casing: true) }
            for seg in c.liveTrack { addLine(seg, color: p.trackUI, width: 4, casing: true) }
            for (_, line) in c.lines.sorted(by: { $0.key < $1.key }) {
                addLine(line.points, color: line.color, width: line.width, dashed: line.dashed, casing: !line.dashed)
            }
            if let target = c.target, let fix = LocationHub.shared.latest {
                addLine([fix.latLon, target.position], color: UIColor(p.accent), width: 3, dashed: true)
            }
            map.addOverlays(lineOverlays, level: .aboveLabels)

            map.removeAnnotations(annotations)
            var list: [MKAnnotation] = c.routePins.map { PinAnnotation($0) }
            list += c.pins.values.flatMap { $0 }.map { PinAnnotation($0) }
            if let s = c.searchPin { list.append(PinAnnotation(s)) }
            if let t = c.target { list.append(PinAnnotation(t)) }
            list += c.groupMarkers.map { MemberAnnotation($0) }
            annotations = list
            map.addAnnotations(list)
        }

        // MARK: Rendering

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tiles)
                if tiles === historicOverlay { r.alpha = historicAlpha }
                if let a = featureAlpha[ObjectIdentifier(tiles)] { r.alpha = a }
                return r
            }
            if let line = overlay as? StyledPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = line.color
                r.lineWidth = line.width
                r.lineCap = .round
                r.lineJoin = .round
                if line.dashed { r.lineDashPattern = [8, 6] }
                return r
            }
            if let poly = overlay as? AreaPolygon {
                let r = MKPolygonRenderer(polygon: poly)
                r.strokeColor = poly.stroke
                r.fillColor = poly.fill
                r.lineWidth = 2
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let p = parent.palette
            if let member = annotation as? MemberAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "member") as? MemberAnnotationView)
                    ?? MemberAnnotationView(annotation: annotation, reuseIdentifier: "member")
                view.annotation = annotation
                view.configure(member.marker, danger: UIColor(p.danger))
                return view
            }
            guard let pa = annotation as? PinAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "pin") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
            view.annotation = annotation
            view.canShowCallout = true
            view.displayPriority = .required
            switch pa.pin.kind {
            case .search: view.markerTintColor = UIColor(p.accent); view.glyphImage = UIImage(systemName: "mappin")
            case .target: view.markerTintColor = UIColor(p.accent); view.glyphImage = UIImage(systemName: "scope")
            case .waypoint: view.markerTintColor = p.routeUI; view.glyphImage = UIImage(systemName: pa.pin.symbol ?? "flag.fill")
            case .facility: view.markerTintColor = UIColor(p.primary); view.glyphImage = UIImage(systemName: pa.pin.symbol ?? "info")
            case .hazard: view.markerTintColor = UIColor(p.danger); view.glyphImage = UIImage(systemName: pa.pin.symbol ?? "exclamationmark.triangle.fill")
            case .planner: view.markerTintColor = p.routeUI; view.glyphText = pa.pin.title
            case .distanceMark:
                view.markerTintColor = UIColor.white
                view.glyphTintColor = p.routeUI
                view.glyphText = pa.pin.title
                view.displayPriority = .defaultLow
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if let pa = annotation as? PinAnnotation { parent.controller.onSelectPin?(pa.pin) }
            if let m = annotation as? MemberAnnotation {
                parent.controller.onSelectMember?(m.marker)
                mapView.deselectAnnotation(annotation, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let c = mapView.centerCoordinate
            let zoom = MapController.zoom(of: mapView) ?? parent.controller.zoom
            DispatchQueue.main.async {
                self.parent.controller.cameraChanged(center: LatLon(c.latitude, c.longitude), zoom: zoom, heading: mapView.camera.heading)
            }
        }

        // MARK: Gestures

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            let c = map.convert(g.location(in: map), toCoordinateFrom: map)
            let p = LatLon(c.latitude, c.longitude)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if let handler = parent.controller.longPressOverride { handler(p) } else { MapScreenState.shared.longPressed = p }
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView, let handler = parent.controller.tapOverride else { return }
            let c = map.convert(g.location(in: map), toCoordinateFrom: map)
            handler(LatLon(c.latitude, c.longitude))
        }

        @objc func userPanned(_ g: UIPanGestureRecognizer) {
            if g.state == .began, parent.controller.follow {
                DispatchQueue.main.async { self.parent.controller.follow = false }
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// A trip-group member: a coloured disc with initials, faded after 2 minutes, hollow after 15, dashed when passed on by
/// another phone, red when they need help.
final class MemberAnnotationView: MKAnnotationView {
    private let label = UILabel()
    private let ring = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        layer.addSublayer(ring)
        label.frame = bounds
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13, weight: .bold)
        addSubview(label)
        displayPriority = .required
        canShowCallout = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ m: GroupMarker, danger: UIColor) {
        let base = UIColor(Color(argb: m.colour))
        let colour = m.needsHelp ? danger : base
        let path = UIBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        ring.path = path.cgPath
        ring.lineWidth = 3
        ring.strokeColor = UIColor.white.cgColor
        ring.lineDashPattern = m.relayed ? [4, 3] : nil
        switch m.freshness {
        case .live: ring.fillColor = colour.cgColor; alpha = 1
        case .faded: ring.fillColor = colour.cgColor; alpha = 0.55
        case .hollow: ring.fillColor = UIColor.clear.cgColor; ring.strokeColor = colour.cgColor; alpha = 0.8
        }
        label.text = String(m.name.prefix(2)).uppercased()
        label.textColor = m.freshness == .hollow ? colour : .white
        accessibilityLabel = "\(m.name)\(m.needsHelp ? ", needs help" : "")"
    }
}
