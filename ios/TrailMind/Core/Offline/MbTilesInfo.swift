import Foundation

/// MBTiles 1.3 metadata as TrailMind reads and writes it (the parts of the Android app's map/MbTiles.kt that need no
/// database): the metadata of a new pack, and what an imported file says about itself.
enum MbTilesInfo {
    static let rasterFormats: Set<String> = ["png", "jpg", "jpeg", "webp"]

    static let bngRefused = "This British National Grid map cannot be imported because TrailMind places imported maps using Web Mercator."
    static let noTiles = "This file contains no tiles."

    static func unsupportedFormat(_ format: String) -> String {
        "This is a '\(format)' MBTiles file. TrailMind renders raster (PNG/JPEG/WebP) tiles only; vector (pbf) packs are not supported yet."
    }

    struct Info: Equatable {
        var name: String?
        var format: String
        var bounds: BoundingBox?
        var minZoom: Int
        var maxZoom: Int
        var attribution: String
        var tileCount: Int64
    }

    /// The metadata rows of a pack TrailMind downloads, in the order they are written.
    static func metadata(name: String, bounds: BoundingBox?, minZoom: Int, maxZoom: Int, attribution: String,
                         grid: TileGrid) -> [(String, String)] {
        var rows: [(String, String)] = [("name", name), ("format", "png"), ("scheme", "tms")]
        if grid == .britishNationalGrid { rows.append(("crs", "EPSG:27700")) }
        rows += [("type", "baselayer"), ("version", "1"), ("minzoom", String(minZoom)), ("maxzoom", String(maxZoom)),
                 ("attribution", attribution)]
        // Swift prints whole doubles with ".0", as Java's Double.toString does.
        if let b = bounds { rows.append(("bounds", "\(b.minLon),\(b.minLat),\(b.maxLon),\(b.maxLat)")) }
        return rows
    }

    /// What the file says about itself, filled in from its tiles where the metadata is silent.
    static func info(metadata md: [String: String], zoomRange: ClosedRange<Int>?, sample: [UInt8]?, tileCount: Int64) -> Info {
        Info(name: md["name"],
             format: (md["format"] ?? sniffFormat(sample)).lowercased(),
             bounds: bounds(md["bounds"]),
             minZoom: md["minzoom"].flatMap { Int($0) } ?? zoomRange?.lowerBound ?? 0,
             maxZoom: md["maxzoom"].flatMap { Int($0) } ?? zoomRange?.upperBound ?? 18,
             attribution: stripHtml(md["attribution"] ?? ""),
             tileCount: tileCount)
    }

    /// "minLon,minLat,maxLon,maxLat", or nil unless exactly four numbers are given.
    static func bounds(_ text: String?) -> BoundingBox? {
        guard let text else { return nil }
        let values = text.split(separator: ",", omittingEmptySubsequences: false).compactMap { Double(KotlinText.trim(String($0))) }
        return values.count == 4 ? BoundingBox(values[1], values[0], values[3], values[2]) : nil
    }

    /// Whether the file declares the British National Grid, which imports cannot place.
    static func isBritishNationalGrid(_ crs: String?) -> Bool { crs?.caseInsensitiveCompare("EPSG:27700") == .orderedSame }

    static func stripHtml(_ s: String) -> String {
        KotlinText.trim(s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&copy;", with: "©"))
    }

    /// The image format of a tile from its first bytes; "png" when there is no tile to look at.
    static func sniffFormat(_ sample: [UInt8]?) -> String {
        guard let s = sample else { return "png" }
        if s.count > 4 && s[0] == 0x89 && s[1] == 0x50 { return "png" }
        if s.count > 3 && s[0] == 0xFF && s[1] == 0xD8 { return "jpg" }
        if s.count > 12 && Array(s[8..<12]) == Array("WEBP".utf8) { return "webp" }
        if s.count > 2 && s[0] == 0x1F && s[1] == 0x8B { return "pbf" }
        return "unknown"
    }
}
