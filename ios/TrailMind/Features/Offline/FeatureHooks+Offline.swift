import Foundation

/// Cross-feature hooks the offline-maps feature adds to the shared ones in App/FeatureHooks.swift.
extension FeatureHooks {
    /// Offline maps: open the Offline page with a route's corridor chosen (a route's "Offline map" button).
    static var offlineForRoute: ((Int64) -> Void)?
    /// Offline maps: how much of a route the base map has on the phone, as the route readiness check shows it
    /// (RouteDetailPage.updateReadiness): the share of points along it covered by offline packs, nil when the base map
    /// can't be saved for offline use (OpenStreetMap), and when the 24-hour Explorer detail along it expires. Calls back
    /// on the main queue.
    static var routeMapCoverage: (([LatLon], @escaping (_ percent: Int?, _ detailUntilMs: Int64?) -> Void) -> Void)?

    // Set by the routes feature, which owns terrain heights and 1 m LiDAR. Offline packs save both when they are set.
    // Both are called on the download thread and may block until done.
    /// Terrain: saves these terrain-height tiles for an offline pack, stopping early when asked; returns how many were
    /// saved and how many were unavailable (TerrainProvider.download).
    static var saveTerrainTiles: ((_ tiles: [TileKey], _ isCancelled: @escaping () -> Bool) -> (saved: Int, unavailable: Int))?
    /// LiDAR: how many of these 1 m squares are not on the phone yet (LidarProvider.missing). Called off the main thread.
    static var lidarMissing: ((_ squares: [Lidar.Square]) -> Int)?
    /// LiDAR: saves these squares along a route's offline map, reporting the running count saved; returns how many were
    /// saved and how many failed (LidarProvider.download).
    static var saveLidarSquares: ((_ squares: [Lidar.Square], _ isCancelled: @escaping () -> Bool,
                                   _ progress: @escaping (Int) -> Void) -> (saved: Int, failed: Int))?
}
