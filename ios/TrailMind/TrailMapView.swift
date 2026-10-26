import MapKit
import SwiftUI
import UIKit

enum MapTracking: Equatable { case none, follow, followHeading }

/// Downloads raster tiles with an identifying User-Agent (OSM tile policy) and keeps OS Premium tiles out of
/// the persistent cache (OS allows Premium tiles to be kept for 24 hours only).
final class TrailTileOverlay: MKTileOverlay {
    let layer: MapLayer
    private let apiKey: String?
    private let onFailure: (Int?) -> Void

    private static let cachedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    private static let premiumSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 0)
        return URLSession(configuration: config)
    }()

    init(layer: MapLayer, apiKey: String?, onFailure: @escaping (Int?) -> Void) {
        self.layer = layer
        self.apiKey = apiKey
        self.onFailure = onFailure
        super.init(urlTemplate: nil)
        minimumZ = layer.minZoom
        maximumZ = layer.maxZoom
        tileSize = CGSize(width: 256, height: 256)
        // Apple Maps stays underneath, so areas or zooms the layer doesn't cover are not blank.
        canReplaceMapContent = false
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        layer.tileURL(z: path.z, x: path.x, y: path.y, apiKey: apiKey) ?? URL(string: "about:blank")!
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard let url = layer.tileURL(z: path.z, x: path.x, y: path.y, apiKey: apiKey) else {
            result(nil, nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue(MapLayer.userAgent, forHTTPHeaderField: "User-Agent")
        let premium = layer.premiumFromZoom.map { path.z >= $0 } ?? false
        let session = premium ? Self.premiumSession : Self.cachedSession
        session.dataTask(with: request) { [onFailure] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            if let error {
                if (error as? URLError)?.code != .cancelled { onFailure(nil) }
                result(nil, error)
            } else if let status, !(200..<300).contains(status) {
                // 404 is normal outside a layer's coverage; anything else is worth telling the user.
                if status != 404 { onFailure(status) }
                result(nil, nil)
            } else {
                result(data, nil)
            }
        }.resume()
    }
}

struct TrailMapView: UIViewRepresentable {
    let layer: MapLayer
    let apiKey: String?
    @Binding var tracking: MapTracking
    /// Changes whenever the user asks to centre on their position again.
    let recentre: Int
    let onTileFailure: (Int?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        // Start over Great Britain, where the OS layers apply.
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 54.5, longitude: -3.0),
                                         span: MKCoordinateSpan(latitudeDelta: 9, longitudeDelta: 9)), animated: false)
        context.coordinator.apply(to: map, force: true)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(to: map, force: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TrailMapView
        private var shownLayer: MapLayer?
        private var shownKey: String?
        private var shownRecentre = 0
        private var shownTracking: MapTracking = .none

        init(_ parent: TrailMapView) { self.parent = parent }

        func apply(to map: MKMapView, force: Bool) {
            if force || shownLayer != parent.layer || shownKey != parent.apiKey {
                map.removeOverlays(map.overlays.filter { $0 is TrailTileOverlay })
                if parent.layer != .apple {
                    let onFailure = parent.onTileFailure
                    let overlay = TrailTileOverlay(layer: parent.layer, apiKey: parent.apiKey) { status in
                        DispatchQueue.main.async { onFailure(status) }
                    }
                    map.addOverlay(overlay, level: .aboveLabels)
                }
                map.mapType = .standard
                shownLayer = parent.layer
                shownKey = parent.apiKey
            }
            if force || shownTracking != parent.tracking || shownRecentre != parent.recentre {
                let mode: MKUserTrackingMode
                switch parent.tracking {
                case .none: mode = .none
                case .follow: mode = .follow
                case .followHeading: mode = .followWithHeading
                }
                map.setUserTrackingMode(mode, animated: !force)
                shownTracking = parent.tracking
                shownRecentre = parent.recentre
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // Panning the map ends following; reflect that in the SwiftUI buttons.
            let tracking: MapTracking = mode == .followWithHeading ? .followHeading : mode == .follow ? .follow : .none
            guard tracking != parent.tracking else { return }
            shownTracking = tracking
            DispatchQueue.main.async { self.parent.tracking = tracking }
        }
    }
}

enum OSLogo {
    static let image: UIImage? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return UIImage(named: "os_logo_maps", in: bundle, compatibleWith: nil)
    }()
}
