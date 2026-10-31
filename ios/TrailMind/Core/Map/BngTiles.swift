import Foundation

/// The OS Maps API tile grid in British National Grid (EPSG:27700): 256 px tiles from a fixed top-left
/// corner, with the resolution halving at each zoom from 896 m per pixel. Values from OS's WMTS capabilities.
enum BngTiles {
    static let originE = -238_375.0
    static let originN = 1_376_256.0
    static let tileSize = 256

    /// The National Grid's extent over Great Britain.
    static let gbMaxE = 700_000.0
    static let gbMaxN = 1_300_000.0

    static func resolution(_ z: Int) -> Double { 896.0 / Double(1 << z) }

    private static func span(_ z: Int) -> Double { Double(tileSize) * resolution(z) }

    static func column(_ easting: Double, _ z: Int) -> Int { toInt(floor((easting - originE) / span(z))) }

    static func row(_ northing: Double, _ z: Int) -> Int { toInt(floor((originN - northing) / span(z))) }

    /// The west edge of `column`.
    static func easting(_ column: Int, _ z: Int) -> Double { originE + Double(column) * span(z) }

    /// The north edge of `row`.
    static func northing(_ row: Int, _ z: Int) -> Double { originN - Double(row) * span(z) }

    /// The most detailed zoom whose pixels are no smaller than `metresPerPixel`, as Web Mercator zooms are chosen.
    static func zoomFor(_ metresPerPixel: Double, _ minZoom: Int, _ maxZoom: Int) -> Int {
        toInt(floor(log(896.0 / metresPerPixel) / log(2.0) + 1e-9)).clamped(minZoom, maxZoom)
    }

    /// Kotlin's `Double.toInt()`: NaN is 0 and anything beyond a 32-bit Int is clamped (Swift's `Int(_:)` would trap).
    private static func toInt(_ x: Double) -> Int {
        x.isNaN ? 0 : Int(x.clamped(Double(Int32.min), Double(Int32.max)))
    }
}
