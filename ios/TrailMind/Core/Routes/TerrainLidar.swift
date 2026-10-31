import Foundation

/// The Mapzen Terrarium terrain tiles behind route heights and the steep-ground overlay (TerrainProvider.kt's
/// constants and pure parts).
enum TerrainSource {
    static let credit = "Terrain: Mapzen Terrain Tiles on AWS · Environment Agency · Copernicus · USGS · NOAA"
    static let requiredAttribution = """
        * ArcticDEM terrain data DEM(s) were created from DigitalGlobe, Inc., imagery and
            funded under National Science Foundation awards 1043681, 1559691, and 1542736;
        * Australia terrain data © Commonwealth of Australia (Geoscience Australia) 2017;
        * Austria terrain data © offene Daten Österreichs – Digitales Geländemodell (DGM)
            Österreich;
        * Canada terrain data contains information licensed under the Open Government
            Licence – Canada;
        * Europe terrain data produced using Copernicus data and information funded by the
            European Union - EU-DEM layers;
        * Global ETOPO1 terrain data U.S. National Oceanic and Atmospheric Administration
        * Mexico terrain data source: INEGI, Continental relief, 2016;
        * New Zealand terrain data Copyright 2011 Crown copyright (c) Land Information New
            Zealand and the New Zealand Government (All rights reserved);
        * Norway terrain data © Kartverket;
        * United Kingdom terrain data © Environment Agency copyright and/or database right
            2015. All rights reserved;
        * United States 3DEP (formerly NED) and global GMTED2010 and SRTM terrain data
            courtesy of the U.S. Geological Survey.
        """
    static let maxDiskBytes: Int64 = 200 * 1024 * 1024
    static let maxTileBytes = 2 * 1024 * 1024
    static let slopeRetryMs: Int64 = 30_000
    /// Below this the whole screen needs too many terrain tiles to shade steep ground.
    static let steepMinZoom = 13.0

    private static func argb(_ a: UInt32, _ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 { a << 24 | r << 16 | g << 8 | b }

    /// By `Terrain.SlopeClass` ordinal: 25° yellow, 30° orange, 35° red, 40° purple.
    static let slopeColours: [UInt32] = [0, argb(88, 255, 213, 0), argb(96, 255, 128, 0), argb(104, 220, 35, 35), argb(112, 120, 45, 170)]

    static func url(_ key: TileKey) -> String {
        "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(key.z)/\(key.x)/\(key.y).png"
    }

    /// Whether `key` is a terrain tile this app uses (the terrain zoom, inside the world).
    static func isTerrainTile(_ key: TileKey) -> Bool {
        key.z == Terrain.zoom && (0..<(1 << key.z)).contains(key.x) && (0..<(1 << key.z)).contains(key.y)
    }

    /// ARGB colours of a tile's slope classes.
    static func slopeArgb(_ classes: [UInt8]) -> [UInt32] { classes.map { slopeColours[Int($0)] } }

    /// The terrain tiles an offline pack saves: a corridor round its route, or its area.
    static func packTiles(_ routePoints: [LatLon]?, _ bounds: BoundingBox?, _ bufferM: Double) -> AnySequence<TileKey> {
        let points = routePoints ?? []
        if !points.isEmpty {
            return AnySequence(TileCoverage.corridor(points, max(bufferM, 100.0), Terrain.zoom))
        }
        guard let area = bounds else { return AnySequence([]) }
        return TileCoverage.box(area.expandedByMetres(100.0), Terrain.zoom, Terrain.zoom)
    }
}

/// The Environment Agency's 1 m LiDAR composite for England (LidarProvider.kt's constants and pure parts).
enum LidarSource {
    /// The Environment Agency's attribution statement, word for word, as the Open Government Licence asks.
    static let credit = "LiDAR: © Environment Agency copyright and/or database right 2022. All rights reserved."
    static let datasetURL = "https://environment.data.gov.uk/dataset/13787b9a-26a4-4775-8523-806d13af58fc"
    static let licenceURL = "https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/"
    /// Typical size of one square, for download estimates: about 100 KB in the lowlands and 180 KB on the fells.
    static let squareBytesEstimate: Int64 = 150 * 1024
    /// The corridor saved with a route's offline map: wide enough to see the ground either side of the path.
    static let packCorridorM = 150.0
    /// Beyond this many squares on the screen the map is zoomed too far out to show 1 m detail.
    static let maxVisible = 144
    /// LiDAR squares already on the phone show from here, when few enough fill the screen...
    static let minZoom = 14.5
    /// ...and missing ones are downloaded only this close, where a screen needs a few megabytes, not tens.
    static let fetchZoom = 16.5
    static let maxDiskBytes: Int64 = 300 * 1024 * 1024
    static let maxSquareBytes = 2 * 1024 * 1024
    static let retryMs: Int64 = 30_000
    private static let coverageId = "13787b9a-26a4-4775-8523-806d13af58fc__Lidar_Composite_Elevation_DTM_1m"

    static func url(_ square: Lidar.Square) -> String {
        "https://environment.data.gov.uk/spatialdata/lidar-composite-digital-terrain-model-dtm-1m/wcs?service=WCS&version=2.0.1" +
            "&request=GetCoverage&coverageId=\(coverageId)&format=image/tiff&geotiff:compression=Deflate" +
            "&subset=E(\(square.east),\(square.east + Lidar.size))&subset=N(\(square.north),\(square.north + Lidar.size))"
    }

    static func fileName(_ square: Lidar.Square) -> String { "\(square.col)_\(square.row).tif" }

    static func squareOf(_ name: String) -> Lidar.Square? {
        guard name.hasSuffix(".tif") else { return nil }
        let parts = name.dropLast(4).split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, let col = Int(parts[0]), let row = Int(parts[1]) else { return nil }
        return Lidar.Square(col, row)
    }

    /// "1.5 MB" for a number of squares, with the phone's decimal separator.
    static func megabytes(_ squares: Int, decimalSeparator: String = ".") -> String {
        let text = javaFixed(Double(Int64(squares) * squareBytesEstimate) / 1_048_576.0, 1)
        return text.replacingOccurrences(of: ".", with: decimalSeparator) + " MB"
    }
}

/// A route checked against LiDAR, as saved on the phone.
struct SavedLidarCheck: Hashable {
    var checkedMs: Int64
    var report: LidarRouteReport

    /// The saved file, in the Android app's format.
    func json() -> String {
        func sections(_ list: [LidarSection]) -> RoutesJSON.Value {
            .array(list.map { s in
                .object(RoutesJSON.Object([("s", .double(s.startM)), ("e", .double(s.endM)), ("v", .double(s.value)),
                                           ("lat", .double(s.at.lat)), ("lon", .double(s.at.lon))]))
            })
        }
        return RoutesJSON.Value.object(RoutesJSON.Object([
            ("checkedMs", .long(checkedMs)), ("lengthM", .double(report.lengthM)), ("coveredM", .double(report.coveredM)),
            ("steep", sections(report.steep)), ("crags", sections(report.crags)),
        ])).serialized()
    }

    static func from(_ text: String) -> SavedLidarCheck? {
        guard let json = try? RoutesJSON.parse(text) else { return nil }
        func sections(_ name: String) throws -> [LidarSection] {
            let array = try json.getJSONArray(name)
            return try array.indices.map { i in
                let o = try RoutesJSON.getJSONObject(array, i)
                return LidarSection(try o.getDouble("s"), try o.getDouble("e"), try o.getDouble("v"),
                                    LatLon(try o.getDouble("lat"), try o.getDouble("lon")))
            }
        }
        do {
            let report = LidarRouteReport(lengthM: try json.getDouble("lengthM"), coveredM: try json.getDouble("coveredM"),
                                          steep: try sections("steep"), crags: try sections("crags"))
            return SavedLidarCheck(checkedMs: try json.getLong("checkedMs"), report: report)
        } catch {
            return nil
        }
    }
}

/// What a LiDAR route check needs and how its result reads (LidarChecks.kt and the route page's terrain card).
enum LidarCheckPlan {
    /// Squares within this of the line are enough for the check: crags are looked for 10 m either side.
    static let corridorM = 20.0

    static func squares(_ points: [LatLon]) -> [Lidar.Square] { Lidar.corridor(points.map { OsGrid.project($0) }, corridorM) }

    /// Whether LiDAR covers the whole route, and how much of it as a percentage; a gap is never rounded up to 100%.
    static func coverage(_ report: LidarRouteReport) -> (full: Bool, percent: Int) {
        let full = report.lengthM > 0 && report.coveredM >= report.lengthM - 0.5
        if full { return (true, 100) }
        if report.lengthM > 0 { return (false, min(kTruncate(report.coveredM / report.lengthM * 100), 99)) }
        return (false, 0)
    }

    /// The line shown when the check found nothing; nil when it found something.
    static func clearText(_ report: LidarRouteReport) -> String? {
        guard report.steep.isEmpty && report.crags.isEmpty else { return nil }
        if coverage(report).full {
            return "No stretch of the line is 35° or steeper over 10 m, and no crag is within 10 m of it."
        }
        if report.coveredM > 0 {
            return "Where LiDAR covers the route, no stretch of the line is 35° or steeper over 10 m, and no crag " +
                "is within 10 m of it. The rest of the route wasn't checked."
        }
        if report.lengthM < 1 { return "The route is too short to check." }
        return "LiDAR has no heights along this route, so it couldn't be checked. The Environment Agency's survey covers " +
            "most of England, but not Wales or Scotland."
    }

    /// The part of `points` from `startM` to `endM` along it, to draw a stretch the check found.
    static func stretch(_ points: [LatLon], _ startM: Double, _ endM: Double) -> [LatLon] {
        guard points.count >= 2 else { return points }
        var cumulative = [0.0]
        for i in 1..<points.count { cumulative.append(cumulative[i - 1] + Geo.distanceM(points[i - 1], points[i])) }
        func at(_ m: Double) -> LatLon {
            let d = m.clamped(0, cumulative[cumulative.count - 1])
            var i = 0
            while i < points.count - 2 && cumulative[i + 1] < d { i += 1 }
            let span = cumulative[i + 1] - cumulative[i]
            let f = span > 0 ? (d - cumulative[i]) / span : 0
            return LatLon(points[i].lat + (points[i + 1].lat - points[i].lat) * f, points[i].lon + (points[i + 1].lon - points[i].lon) * f)
        }
        var out = [at(startM)]
        for i in points.indices where cumulative[i] > startM && cumulative[i] < endM { out.append(points[i]) }
        out.append(at(max(endM, startM + 1)))
        return out
    }
}
