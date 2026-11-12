import CoreGraphics
import MapKit
import UIKit

/// The Reveal slider's map layer (TileMapView.drawReveal): opaque LiDAR pictures of the ground over the part of the
/// map to the left of the slider's line, drawn through each 256 m square's own corners on the National Grid.
final class RevealOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

/// Draws only what is already built; squares still to build or download are asked for in the background and the
/// layer redraws them as they arrive. MapKit draws overlays on background threads, so the state is locked.
final class RevealRenderer: MKOverlayRenderer {
    private let lock = NSLock()
    private var style = LidarReveal.Style.svf
    private var clip: [MKMapPoint] = []
    private var clipBounds = MKMapRect.null

    init(overlay: RevealOverlay, style: LidarReveal.Style, clip: [MKMapPoint]) {
        super.init(overlay: overlay)
        set(style: style, clip: clip)
        settledObserver = NotificationCenter.default.addObserver(forName: LidarService.settled, object: nil, queue: .main) { [weak self] _ in
            self?.setNeedsDisplay()
        }
    }

    deinit {
        if let settledObserver { NotificationCenter.default.removeObserver(settledObserver) }
    }

    private var settledObserver: NSObjectProtocol?

    /// The picture to show and the part of the map it covers (a quadrilateral in map points). Main queue.
    func update(style: LidarReveal.Style, clip: [MKMapPoint]) {
        set(style: style, clip: clip)
        setNeedsDisplay()
    }

    private func set(style: LidarReveal.Style, clip: [MKMapPoint]) {
        var bounds = MKMapRect.null
        for p in clip { bounds = bounds.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0)) }
        lock.withLock {
            self.style = style
            self.clip = clip
            clipBounds = bounds
        }
    }

    /// The Web Mercator zoom of a 256-point tile at this zoom scale, as `MapController.zoom` counts it.
    private static func zoom(_ zoomScale: MKZoomScale) -> Double {
        log2(Double(zoomScale) * MKMapSize.world.width / 256)
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        Self.zoom(zoomScale) >= LidarSource.minZoom
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let zoom = Self.zoom(zoomScale)
        let (style, clip, bounds) = lock.withLock { (self.style, self.clip, clipBounds) }
        guard zoom >= LidarSource.minZoom, clip.count >= 3, bounds.intersects(mapRect) else { return }

        var minE = Double.greatestFiniteMagnitude, maxE = -Double.greatestFiniteMagnitude
        var minN = Double.greatestFiniteMagnitude, maxN = -Double.greatestFiniteMagnitude
        for i in 0...2 {
            for j in 0...2 {
                let at = MKMapPoint(x: mapRect.minX + mapRect.width * Double(i) / 2, y: mapRect.minY + mapRect.height * Double(j) / 2)
                let g = OsGrid.project(LatLon(at.coordinate.latitude, at.coordinate.longitude))
                minE = min(minE, g.easting); maxE = max(maxE, g.easting)
                minN = min(minN, g.northing); maxN = max(maxN, g.northing)
            }
        }
        guard let squares = Lidar.box(minE, minN, maxE, maxN, LidarSource.maxVisible), !squares.isEmpty else { return }
        let fetch = zoom >= LidarReveal.fetchZoom && RouteNetwork.shared.networkAllowed
        let lidar = LidarService.shared

        context.saveGState()
        defer { context.restoreGState() }
        context.addLines(between: clip.map { point(for: $0) })
        context.closePath()
        context.clip()
        // Neighbours share their corners exactly, so without antialiased edges they meet with no gap.
        context.setShouldAntialias(false)
        context.interpolationQuality = .medium
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        for square in squares {
            let corner = { (e: Int, n: Int) -> MKMapPoint in
                let p = OsGrid.toWgs84(Double(e), Double(n))
                return MKMapPoint(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
            }
            let tl = corner(square.east, square.north + Lidar.size)
            let tr = corner(square.east + Lidar.size, square.north + Lidar.size)
            let bl = corner(square.east, square.north)
            let br = corner(square.east + Lidar.size, square.north)
            let xs = [tl.x, tr.x, bl.x, br.x], ys = [tl.y, tr.y, bl.y, br.y]
            let extent = MKMapRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            // Squares off this piece of the map, or wholly on the map's side of the line, aren't wanted or downloaded.
            guard extent.intersects(mapRect), extent.intersects(bounds) else { continue }

            let picture = lidar.revealPicture(square, style)
            if !picture.built || picture.stale {
                lidar.requestReveal(square, style, allowNetwork: fetch) { [weak self] in self?.setNeedsDisplay(extent) }
            }
            guard let image = picture.image else { continue }
            let a = point(for: tl), b = point(for: tr), c = point(for: bl)
            let w = CGFloat(image.width), h = CGFloat(image.height)
            context.saveGState()
            context.concatenate(CGAffineTransform(a: (b.x - a.x) / w, b: (b.y - a.y) / w, c: (c.x - a.x) / h, d: (c.y - a.y) / h,
                                                  tx: a.x, ty: a.y))
            UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            context.restoreGState()
        }
    }
}
