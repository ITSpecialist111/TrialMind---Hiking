import Combine
import MapKit
import UIKit

/// Steep ground and 1 m LiDAR shading over the map while Map layers or Settings turn them on (TileMapView's
/// showSteepGround and showLidar), drawn as MapKit tile overlays above the base map: LiDAR first, steep ground on top.
final class TerrainOverlays {
    static let shared = TerrainOverlays()
    static let steepId = "steep-ground"
    static let lidarId = "lidar"

    private var steep: SteepGroundOverlay?
    private var lidar: LidarOverlay?
    private var started = false
    private var staleWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        guard !started else { return }
        started = true
        LidarService.shared.onStale = { [weak self] in self?.lidarStale() }
        Prefs.shared.$showSteepGround.combineLatest(Prefs.shared.$showLidar)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    /// Adds or removes the overlays to match the settings.
    func refresh() {
        let prefs = Prefs.shared
        let map = MapController.shared
        if prefs.showLidar {
            if lidar == nil {
                let overlay = LidarOverlay(lidar: LidarService.shared)
                lidar = overlay
                map.setTileOverlay(Self.lidarId, overlay, alpha: 1, order: 1)
            }
        } else if lidar != nil {
            lidar = nil
            map.setTileOverlay(Self.lidarId, nil)
        }
        if prefs.showSteepGround {
            if steep == nil {
                let overlay = SteepGroundOverlay(terrain: TerrainService.shared)
                steep = overlay
                map.setTileOverlay(Self.steepId, overlay, alpha: 1, order: 2)
            }
        } else if steep != nil {
            steep = nil
            map.setTileOverlay(Self.steepId, nil)
        }
    }

    /// Squares that arrived change the edges of shading already drawn beside them: draw the layer again once the
    /// downloads settle (a new overlay makes MapKit ask for its tiles afresh; the shading itself is cached).
    private func lidarStale() {
        staleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, Prefs.shared.showLidar, self.lidar != nil else { return }
            let overlay = LidarOverlay(lidar: LidarService.shared)
            self.lidar = overlay
            MapController.shared.setTileOverlay(Self.lidarId, overlay, alpha: 1, order: 1)
        }
        staleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

extension RouteMap {
    /// Turns on LiDAR shading, for places a route check points to (MapScreen.showLidarLayer).
    static func showLidarLayer() {
        if !Prefs.shared.showLidar { Prefs.shared.showLidar = true }
        TerrainOverlays.shared.refresh()
    }

    /// Ground height at a point with its credit: LiDAR already on the phone first, then the terrain model
    /// (MapScreen.groundHeight). Calls back on the main queue.
    static func groundHeight(_ at: LatLon, _ done: @escaping (Double?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: (Double, String)?
            if let h = LidarService.shared.sample(at) {
                result = (h, LidarSource.credit)
            } else if let h = TerrainService.shared.sample(at) {
                result = (h, TerrainSource.credit)
            } else {
                result = nil
            }
            DispatchQueue.main.async { done(result?.0, result?.1) }
        }
    }

    /// Fades an old map over the current one and moves the map there: the Forest of Dean by default, or `box` (a route).
    /// Uses the old map already chosen, else the six-inch, which is the one for the Forest's mines, scowles and
    /// tramroads (MapScreen.showOldMap).
    static func showOldMap(box: BoundingBox?, at: LatLon?) {
        let prefs = Prefs.shared
        let historic = TileSources.historic()
        guard let s = historic.first(where: { $0.id == prefs.historicOverlayId }) ?? historic.first(where: { $0.id == TileSources.nlsSixInch })
        else { return }
        if s.requiresKey && TileLoader.shared.apiKey(for: s) == nil {
            AppModel.shared.choose("MapTiler key needed",
                                   "\(s.note)\n\nThe old maps are served by MapTiler Cloud. Create a free account, copy a key from " +
                                    "your account page, and paste it in Settings.",
                                   options: [("Add key", { Navigator.shared.open(.settings) })])
            return
        }
        prefs.historicOverlayId = s.id
        TileLoader.shared.clearErrors()
        if let box {
            fit(box)
        } else if let at {
            centerOn(at, zoom: TileSources.forestOfDeanZoom)
        } else {
            Navigator.shared.showMap()
        }
        AppModel.shared.toast("\(s.name.replacingOccurrences(of: TileSources.oldMapPrefix, with: "")) over today's map. " +
                              "Drag the slider under Map layers → Old maps to fade it.")
    }

    /// The part of the map in view, uncovered by panes and controls; a box round the map's centre when the map has no
    /// size yet (RouteFinderPage.mapBox).
    static func visibleBox() -> BoundingBox {
        let controller = MapController.shared
        if let map = controller.mapView, map.bounds.width > 0, map.bounds.height > 0 {
            let area = controller.visibleArea.width > 0 && controller.visibleArea.height > 0 ? controller.visibleArea : map.bounds
            let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                           CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY)]
                .map { map.convert($0, toCoordinateFrom: map) }
                .map { LatLon($0.latitude, $0.longitude) }
            if let box = BoundingBox.of(corners) {
                let span = Geo.distanceM(LatLon(box.minLat, box.minLon), LatLon(box.maxLat, box.maxLon))
                return span < 500 ? box.expandedByMetres(RouteText.nearM) : box
            }
        }
        let c = controller.center
        return BoundingBox(c.lat, c.lon, c.lat, c.lon).expandedByMetres(RouteText.nearM)
    }
}
