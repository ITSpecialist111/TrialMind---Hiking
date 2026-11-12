import Foundation

/// How a source's z/x/y tiles are laid out.
enum TileGrid: String { case webMercator, britishNationalGrid }

/// Whose key a source's `{key}` is: the user brings their own for each, and neither is ever bundled.
enum KeyKind: String {
    case os, mapTiler

    var label: String { self == .os ? "OS Data Hub API key" : "MapTiler key" }
}

/// A raster tile source, in Web Mercator (EPSG:3857) unless `grid` says otherwise. Either online (URL template) or an
/// imported MBTiles pack (`packId`). Ported from the Android app's map/TileSource.kt.
struct TileSource: Hashable, Identifiable {
    var id: String
    var name: String
    var template: String?
    var attribution: String
    var minZoom: Int
    var maxZoom: Int
    var requiresKey = false
    /// Whether this provider's terms allow storing tiles for offline use (the user must still check their plan).
    var offlineDownloadAllowed = false
    var downloadMaxZoom: Int? = nil
    var note = ""
    var packId: Int64? = nil
    /// First zoom of charged Premium data; the provider's terms allow caching those tiles for 24 hours only.
    var premiumFromZoom: Int? = nil
    var grid: TileGrid = .webMercator
    /// Ordnance Survey maps, which OS's API branding rules require to show the OS logo on the map.
    var showsOsLogo = false
    /// Drawn over the base map (from the overlays menu), never picked as the base map itself.
    var overlay = false
    /// Which key `requiresKey` means.
    var keyKind: KeyKind = .os
    /// A scanned historic map, drawn over the base map with an adjustable fade.
    var historic = false
    /// Apple's own map, drawn by MapKit (iPhone only).
    var appleMap = false

    var isOnline: Bool { template != nil }
    var effectiveDownloadMaxZoom: Int { downloadMaxZoom ?? maxZoom }

    func isPremium(_ z: Int) -> Bool { premiumFromZoom.map { z >= $0 } ?? false }
    func canStoreInPack(_ z: Int) -> Bool { offlineDownloadAllowed && (minZoom...effectiveDownloadMaxZoom).contains(z) && !isPremium(z) }
    func canReadFromPack(_ z: Int) -> Bool { packId != nil || !isPremium(z) }

    /// The tile URL for `key`, or nil when the source is offline-only or a needed key is missing.
    func url(_ key: TileKey, apiKey: String?) -> URL? {
        guard var t = template else { return nil }
        if t.contains("{key}") {
            guard let k = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty,
                  let escaped = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            t = t.replacingOccurrences(of: "{key}", with: escaped)
        }
        t = t.replacingOccurrences(of: "{z}", with: String(key.z))
            .replacingOccurrences(of: "{x}", with: String(key.x))
            .replacingOccurrences(of: "{y}", with: String(key.y))
        return URL(string: t)
    }
}

enum TileSources {
    static func isRetired(_ id: String) -> Bool { ["gsi_std", "gsi_photo", "gsi_hillshade"].contains(id) }
    static let osm = "osm"
    static let osOutdoor = "os_outdoor"
    static let osRoad = "os_road"
    static let osLight = "os_light"
    static let osLeisure = "os_leisure"
    static let apple = "apple"
    static let custom = "custom"

    static let nls1900s = "nls_1900s"
    static let nlsSixInch = "nls_six_inch"
    static let nls1920s = "nls_1920s"
    static let nls25k = "nls_25k"
    static let nlsOneInch7th = "nls_one_inch_7th"
    static let nlsOneInchHills = "nls_one_inch_hills"
    static let nlsAttribution = "Old map: Ordnance Survey via National Library of Scotland (CC BY 3.0), MapTiler"
    static let oldMapPrefix = "Old map – "

    /// Where the old maps open: the middle of the Forest of Dean and the lower Wye, around Coleford and Parkend.
    static let forestOfDeanLat = 51.78
    static let forestOfDeanLon = -2.55
    static let forestOfDeanZoom = 14.0

    // Where the map credits lead: OSM's licence and error reporting, OS's terms and its Errors and Omissions Tool.
    static let osmCopyrightURL = "https://www.openstreetmap.org/copyright"
    static let osmFixTheMapURL = "https://www.openstreetmap.org/fixthemap"
    static let osTermsURL = "https://www.ordnancesurvey.co.uk/legal"
    static let osErrorsURL = "https://osdatahub.os.uk/apps/errors-and-omissions"
    static let nlsMapsURL = "https://maps.nls.uk/projects/api/"
    static let mapTilerCloudURL = "https://cloud.maptiler.com/account/keys/"
    static let mapTilerCopyrightURL = "https://www.maptiler.com/copyright/"

    private static func year() -> Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }

    private static func osSource(_ id: String, _ layer: String, _ label: String) -> TileSource {
        TileSource(
            id: id,
            name: "OS Maps – \(label)",
            template: "https://api.os.uk/maps/raster/v1/zxy/\(layer)_3857/{z}/{x}/{y}.png?key={key}",
            attribution: "Contains OS data © Crown copyright and database rights \(year())",
            minZoom: 7, maxZoom: 20, requiresKey: true, offlineDownloadAllowed: true, downloadMaxZoom: 16,
            note: "Needs your OS Data Hub API key. Overview maps (zooms 7–16) stay in your pack. " +
                "Closer detail uses your plan's allowance and is kept for 24 hours. " +
                "For public rights of way, use OS Maps – Explorer® & Landranger®.",
            premiumFromZoom: 17, showsOsLogo: true
        )
    }

    private static func osLeisureSource() -> TileSource {
        TileSource(
            // OS's API terms ask for its trade marks to carry ® (OS Explorer and OS Landranger are registered).
            id: osLeisure,
            name: "OS Maps – Explorer® & Landranger®",
            template: "https://api.os.uk/maps/raster/v1/zxy/Leisure_27700/{z}/{x}/{y}.png?key={key}",
            attribution: "Contains OS data © Crown copyright and database rights \(year())",
            minZoom: 0, maxZoom: 9, requiresKey: true, offlineDownloadAllowed: true, downloadMaxZoom: 5,
            note: "OS's paper-map style, with public rights of way (footpaths, bridleways and byways) and open access " +
                "land: 1:50,000 Landranger zoomed out, 1:25,000 Explorer zoomed in. Great Britain only. Needs your OS Data " +
                "Hub key. Overview maps (zooms 0–5) stay in your pack. Landranger and Explorer detail at zooms 6–9 " +
                "uses your plan's allowance; OS lets you keep it for 24 hours.",
            premiumFromZoom: 6, grid: .britishNationalGrid, showsOsLogo: true
        )
    }

    static func builtIns() -> [TileSource] {
        [
            TileSource(
                id: osm, name: "OpenStreetMap (online)", template: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                attribution: "© OpenStreetMap contributors", minZoom: 0, maxZoom: 19,
                note: "Browsing only. The OSM Foundation tile usage policy forbids bulk/offline " +
                    "downloading, so TrailMind never pre-fetches these tiles; viewed tiles are cached briefly."
            ),
            osSource(osOutdoor, "Outdoor", "Outdoor"),
            osLeisureSource(),
            osSource(osRoad, "Road", "Road"),
            osSource(osLight, "Light", "Light"),
            TileSource(
                id: apple, name: "Apple Maps", template: nil, attribution: "Apple Maps", minZoom: 0, maxZoom: 20,
                note: "Apple's own map, drawn by the iPhone. No key; not for offline use.", appleMap: true
            ),
        ]
    }

    /// The old Ordnance Survey series cover Great Britain only; elsewhere their tiles are not requested.
    static func overlapsBritain(_ b: BoundingBox) -> Bool { b.maxLat >= 49.8 && b.minLat <= 61.0 && b.maxLon >= -8.7 && b.minLon <= 2.0 }

    /// The old maps' tile service. Only tests change this, to point at a server of their own.
    static var historicBaseUrl = "https://api.maptiler.com/tiles"

    private static func nls(_ id: String, _ tileset: String, _ label: String, _ minZoom: Int, _ maxZoom: Int, _ note: String) -> TileSource {
        TileSource(
            id: id, name: oldMapPrefix + label, template: "\(historicBaseUrl)/\(tileset)/{z}/{x}/{y}.jpg?key={key}",
            attribution: nlsAttribution, minZoom: minZoom, maxZoom: maxZoom, requiresKey: true,
            // MapTiler's terms forbid bulk downloads, so these are browsed live and only cached briefly, like OpenStreetMap.
            note: note + " Covers the Forest of Dean and the rest of Great Britain. Needs your own free MapTiler key (Settings). " +
                "Online only: MapTiler's terms don't allow saving these maps for offline use. Zoomed in past the original scale, " +
                "the last tiles are enlarged.",
            overlay: true, keyKind: .mapTiler, historic: true
        )
    }

    /// Scanned Ordnance Survey maps of Great Britain, 1885–1961, served by MapTiler Cloud with the user's own key.
    /// Best first: the six-inch is the one for the Forest of Dean's mines, scowles, tramroads and quarries.
    static func historic() -> [TileSource] {
        [
            nls(nlsSixInch, "uk-osgb10k1888", "OS six-inch 1888–1913", 10, 17,
                "The most detailed old map, and the one for the Forest of Dean: its coal and iron workings, levels and scowles, " +
                    "tramroads and railways, quarries, kilns, forges and mills as they were around 1900, many of them gone from today's maps."),
            nls(nls25k, "uk-osgb25k1937", "OS 1:25,000 1937–61", 10, 16,
                "The first 1:25,000 maps, between the wars and just after, with old routeways, earthworks, cairns and standing stones marked."),
            nls(nls1900s, "uk-osgb1888", "OS around 1900, all scales", 5, 17,
                "The Ordnance Survey of the 1880s–1910s at every scale, so it reads from the whole country down to individual farms."),
            nls(nlsOneInch7th, "uk-osgb63k1955", "OS one-inch 1955–61", 7, 15,
                "The last one-inch series, forerunner of Landranger: paths, woods, old railways and land use after the war."),
            nls(nlsOneInchHills, "uk-osgb63k1885", "OS one-inch 1885–1903", 7, 16,
                "Victorian one-inch with hill hachures: settlement, roads, parkland and woodland at the end of the 1800s."),
            nls(nls1920s, "uk-osgb1919", "OS 1920s–40s, all scales", 5, 14,
                "Between the wars: railways at their peak and the tracks used before the motor car took over, at several scales."),
        ]
    }

    static func custom(name: String, template: String, attribution: String, maxZoom: Int, offlineAllowed: Bool,
                       bulkForbidden: Bool) -> TileSource {
        TileSource(
            id: custom, name: name.isBlank ? "Custom source" : name, template: template,
            attribution: attribution.isBlank ? "Custom tile source" : attribution, minZoom: 0, maxZoom: maxZoom.clamped(1, 22),
            offlineDownloadAllowed: offlineAllowed && !bulkForbidden,
            note: bulkForbidden ? "This host's usage policy forbids bulk downloads; browsing only."
                : "You are responsible for complying with this provider's licence."
        )
    }

    static func fromPack(id: Int64, name: String, attribution: String, minZoom: Int, maxZoom: Int) -> TileSource {
        TileSource(id: "pack:\(id)", name: "\(name) (offline file)", template: nil,
                   attribution: attribution.isBlank ? "Imported map file" : attribution, minZoom: minZoom, maxZoom: maxZoom,
                   note: "Imported MBTiles, fully offline.", packId: id)
    }
}
