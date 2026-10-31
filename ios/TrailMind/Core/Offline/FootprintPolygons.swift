import Foundation

/// A pack's footprint as map polygons (TileMapView.drawOfflineAreas): its cells merged into rectangles to tint, and its
/// outline, holes included, to stroke. Web Mercator tile corners become latitude and longitude directly; National Grid
/// tiles are turned slightly against north, so their outlines bend through every tile corner (drawBngOfflineArea).
enum FootprintPolygons {
    static func of(_ f: TileFootprint, nationalGrid: Bool) -> (fills: [[LatLon]], edges: [[LatLon]]) {
        let fills = FootprintShape.rects(f).map { FootprintShape.ring($0, everyCorner: nationalGrid).map { corner($0, f.zoom, nationalGrid) } }
        let edges = FootprintShape.loops(f, everyCorner: nationalGrid).map { $0.map { corner($0, f.zoom, nationalGrid) } }
        return (fills, edges)
    }

    /// Where a tile corner is: the National Grid corner's easting and northing, or the Web Mercator pixel's position.
    static func corner(_ c: FootprintShape.Corner, _ zoom: Int, _ nationalGrid: Bool) -> LatLon {
        if nationalGrid { return OsGrid.toWgs84(BngTiles.easting(c.x, zoom), BngTiles.northing(c.y, zoom)) }
        let size = Double(WebMercator.tileSize)
        return LatLon(WebMercator.yToLat(Double(c.y) * size, Double(zoom)), WebMercator.xToLon(Double(c.x) * size, Double(zoom)))
    }
}

extension TileFootprint {
    /// Whether the cell at column `x`, row `y` (at the footprint's zoom) is part of it.
    func contains(_ x: Int, _ y: Int) -> Bool {
        stride(from: 0, to: spans.count - 2, by: 3).contains { i in spans[i] == y && x >= spans[i + 1] && x < spans[i + 2] }
    }
}
