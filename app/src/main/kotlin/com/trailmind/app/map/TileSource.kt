package com.trailmind.app.map

import com.trailmind.app.data.PackMeta
import com.trailmind.app.data.Prefs
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.map.TilePolicy
import java.util.Calendar

/** How a source's z/x/y tiles are laid out. */
enum class TileGrid { WEB_MERCATOR, BRITISH_NATIONAL_GRID }

/** Whose key a source's `{key}` is: the user brings their own for each, and neither is ever bundled. */
enum class KeyKind(val label: String) {
    OS("OS Data Hub API key"),
    MAPTILER("MapTiler key"),
}

/**
 * A raster tile source, in Web Mercator (EPSG:3857) unless [grid] says otherwise. Either online (URL
 * template) or an imported MBTiles pack ([packId]).
 */
data class TileSource(
    val id: String,
    val name: String,
    val template: String?,
    val attribution: String,
    val minZoom: Int,
    val maxZoom: Int,
    val requiresKey: Boolean = false,
    /** Whether this provider's terms allow storing tiles for offline use (user must still check their plan). */
    val offlineDownloadAllowed: Boolean = false,
    val downloadMaxZoom: Int = maxZoom,
    val note: String = "",
    val packId: Long? = null,
    /** First zoom of charged Premium data; the provider's terms allow caching those tiles for 24 hours only. */
    val premiumFromZoom: Int? = null,
    val grid: TileGrid = TileGrid.WEB_MERCATOR,
    /** Ordnance Survey maps, which OS's API branding rules require to show the OS logo on the map. */
    val showsOsLogo: Boolean = false,
    /** Drawn over the base map (from the Overlays menu), never picked as the base map itself. */
    val overlay: Boolean = false,
    /** Which key [requiresKey] means. */
    val keyKind: KeyKind = KeyKind.OS,
    /** A scanned historic map, drawn over the base map with an adjustable fade. */
    val historic: Boolean = false,
) {
    val isOnline: Boolean get() = template != null

    fun isPremium(z: Int) = premiumFromZoom != null && z >= premiumFromZoom

    fun canStoreInPack(z: Int) = offlineDownloadAllowed && z in minZoom..downloadMaxZoom && !isPremium(z)

    fun canReadFromPack(z: Int) = packId != null || !isPremium(z)
}

object TileSources {
    const val OSM = "osm"
    const val OS_OUTDOOR = "os_outdoor"
    const val OS_ROAD = "os_road"
    const val OS_LIGHT = "os_light"
    const val OS_LEISURE = "os_leisure"
    const val GSI_STD = "gsi_std"
    const val GSI_PHOTO = "gsi_photo"
    const val GSI_HILLSHADE = "gsi_hillshade"
    const val CUSTOM = "custom"
    const val GSI_ATTRIBUTION = "出典：国土地理院 (Geospatial Information Authority of Japan)"

    const val NLS_1900S = "nls_1900s"
    const val NLS_SIX_INCH = "nls_six_inch"
    const val NLS_1920S = "nls_1920s"
    const val NLS_25K = "nls_25k"
    const val NLS_ONE_INCH_7TH = "nls_one_inch_7th"
    const val NLS_ONE_INCH_HILLS = "nls_one_inch_hills"
    const val NLS_ATTRIBUTION = "Old map: Ordnance Survey via National Library of Scotland (CC BY 3.0), MapTiler"
    const val OLD_MAP_PREFIX = "Old map – "

    /** Where the old maps open: the middle of the Forest of Dean and the lower Wye, around Coleford and Parkend. */
    const val FOREST_OF_DEAN_LAT = 51.78
    const val FOREST_OF_DEAN_LON = -2.55
    const val FOREST_OF_DEAN_ZOOM = 14.0

    // Where the map credits lead: OSM's licence and error reporting, OS's terms and its Errors and Omissions Tool.
    const val OSM_COPYRIGHT_URL = "https://www.openstreetmap.org/copyright"
    const val OSM_FIX_THE_MAP_URL = "https://www.openstreetmap.org/fixthemap"
    const val OS_TERMS_URL = "https://www.ordnancesurvey.co.uk/legal"
    const val OS_ERRORS_URL = "https://osdatahub.os.uk/apps/errors-and-omissions"
    const val GSI_TILES_URL = "https://maps.gsi.go.jp/development/ichiran.html"
    const val NLS_MAPS_URL = "https://maps.nls.uk/projects/api/"
    const val MAPTILER_CLOUD_URL = "https://cloud.maptiler.com/account/keys/"
    const val MAPTILER_COPYRIGHT_URL = "https://www.maptiler.com/copyright/"

    private fun year() = Calendar.getInstance().get(Calendar.YEAR)

    private fun osSource(id: String, layer: String, label: String) = TileSource(
        id = id,
        name = "OS Maps – $label",
        template = "https://api.os.uk/maps/raster/v1/zxy/${layer}_3857/{z}/{x}/{y}.png?key={key}",
        attribution = "Contains OS data © Crown copyright and database rights ${year()}",
        minZoom = 7,
        maxZoom = 20,
        requiresKey = true,
        offlineDownloadAllowed = true,
        downloadMaxZoom = 16,
        premiumFromZoom = 17,
        showsOsLogo = true,
        note = "Needs your OS Data Hub API key. Overview maps (zooms 7–16) stay in your pack. " +
            "Closer detail uses your plan's allowance and is kept for 24 hours. " +
            "For public rights of way, use OS Maps – Explorer® & Landranger®.",
    )

    private fun osLeisure() = TileSource(
        id = OS_LEISURE,
        // OS's API terms ask for its trade marks to carry ® (OS Explorer and OS Landranger are registered).
        name = "OS Maps – Explorer® & Landranger®",
        template = "https://api.os.uk/maps/raster/v1/zxy/Leisure_27700/{z}/{x}/{y}.png?key={key}",
        attribution = "Contains OS data © Crown copyright and database rights ${year()}",
        minZoom = 0,
        maxZoom = 9,
        requiresKey = true,
        offlineDownloadAllowed = true,
        downloadMaxZoom = 5,
        premiumFromZoom = 6,
        grid = TileGrid.BRITISH_NATIONAL_GRID,
        showsOsLogo = true,
        note = "OS's paper-map style, with public rights of way (footpaths, bridleways and byways) and open access " +
            "land: 1:50,000 Landranger zoomed out, 1:25,000 Explorer zoomed in. Great Britain only. Needs your OS Data " +
            "Hub key. Overview maps (zooms 0–5) stay in your pack. Landranger and Explorer detail at zooms 6–9 " +
            "uses your plan's allowance; OS lets you keep it for 24 hours.",
    )

    fun builtIns(): List<TileSource> = listOf(
        TileSource(
            id = OSM,
            name = "OpenStreetMap (online)",
            template = "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
            attribution = "© OpenStreetMap contributors",
            minZoom = 0,
            maxZoom = 19,
            note = "Browsing only. The OSM Foundation tile usage policy forbids bulk/offline " +
                "downloading, so TrailMind never pre-fetches these tiles; viewed tiles are cached briefly.",
        ),
        osSource(OS_OUTDOOR, "Outdoor", "Outdoor"),
        osLeisure(),
        osSource(OS_ROAD, "Road", "Road"),
        osSource(OS_LIGHT, "Light", "Light"),
        TileSource(
            id = GSI_STD,
            name = "Japan – GSI Standard Map (online)",
            template = "https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png",
            attribution = GSI_ATTRIBUTION,
            minZoom = 5,
            maxZoom = 18,
            // A basic survey result (基本測量成果): real-time use needs only the credit, but stored copies can need
            // approval under Japan's Survey Act (測量法), so this stays browse-only.
            note = "Japan's national 1:25,000-based topographic map, with contours, footpaths, summits and huts. " +
                "Labels are in Japanese. Browsing only: saving it offline can need approval under Japan's Survey Act. " +
                "For offline use in Japan, download GSI Aerial Photo and GSI Hill shading.",
        ),
        // Not basic survey results: GSI lets these be used, including stored offline, with the credit only.
        TileSource(
            id = GSI_PHOTO,
            name = "Japan – GSI Aerial Photo",
            template = "https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg",
            attribution = GSI_ATTRIBUTION,
            minZoom = 2,
            maxZoom = 18,
            offlineDownloadAllowed = true,
            downloadMaxZoom = 17,
            note = "GSI's seamless aerial photos of Japan, sharp enough to pick out paths and clearings. " +
                "Can be downloaded for offline use (credit only, no application needed).",
        ),
        TileSource(
            id = GSI_HILLSHADE,
            name = "Japan – GSI Hill shading (overlay)",
            template = "https://cyberjapandata.gsi.go.jp/xyz/hillshademap/{z}/{x}/{y}.png",
            attribution = GSI_ATTRIBUTION,
            minZoom = 2,
            maxZoom = 16,
            offlineDownloadAllowed = true,
            overlay = true,
            note = "Hill shading of Japan from GSI's 5–10 m elevation model, drawn over any map from Overlays. " +
                "Download it for offline use as its own pack (credit only, no application needed).",
        ),
    )

    /** GSI's Japan-only overlay tiles exist only around Japan; elsewhere they are not requested. */
    fun overlapsJapan(b: BoundingBox) = b.maxLat >= 20.0 && b.minLat <= 46.0 && b.maxLon >= 122.0 && b.minLon <= 154.0

    /** The old Ordnance Survey series cover Great Britain only; elsewhere their tiles are not requested. */
    fun overlapsBritain(b: BoundingBox) = b.maxLat >= 49.8 && b.minLat <= 61.0 && b.maxLon >= -8.7 && b.minLon <= 2.0

    /** The old maps' tile service. Only tests change this, to point at a server of their own. */
    @Volatile var historicBaseUrl = "https://api.maptiler.com/tiles"

    private fun nls(id: String, tileset: String, label: String, minZoom: Int, maxZoom: Int, note: String) = TileSource(
        id = id,
        name = "$OLD_MAP_PREFIX$label",
        template = "$historicBaseUrl/$tileset/{z}/{x}/{y}.jpg?key={key}",
        attribution = NLS_ATTRIBUTION,
        minZoom = minZoom,
        maxZoom = maxZoom,
        requiresKey = true,
        keyKind = KeyKind.MAPTILER,
        overlay = true,
        historic = true,
        // MapTiler's terms forbid bulk downloads, so these are browsed live and only cached briefly, like OpenStreetMap.
        note = "$note Covers the Forest of Dean and the rest of Great Britain. Needs your own free MapTiler key (Settings). " +
            "Online only: MapTiler's terms don't allow saving these maps for offline use. Zoomed in past the original scale, " +
            "the last tiles are enlarged.",
    )

    /**
     * Scanned Ordnance Survey maps of Great Britain, from 1885 to 1961, served by MapTiler Cloud with the user's own
     * key. They are the National Library of Scotland's scans, but cover England and Wales as fully as Scotland: every
     * sheet around the Forest of Dean is in them. Drawn over the current map with a fade, so what has gone shows
     * through what is there now. Kept apart from [builtIns] because these need a different key and are never downloaded.
     * Best first: the six-inch is the one for the Forest's mines, scowles, tramroads and quarries.
     */
    fun historic(): List<TileSource> = listOf(
        nls(NLS_SIX_INCH, "uk-osgb10k1888", "OS six-inch 1888–1913", 10, 17,
            "The most detailed old map, and the one for the Forest of Dean: its coal and iron workings, levels and scowles, " +
                "tramroads and railways, quarries, kilns, forges and mills as they were around 1900, many of them gone from today's maps."),
        nls(NLS_25K, "uk-osgb25k1937", "OS 1:25,000 1937–61", 10, 16,
            "The first 1:25,000 maps, between the wars and just after, with old routeways, earthworks, cairns and standing stones marked."),
        nls(NLS_1900S, "uk-osgb1888", "OS around 1900, all scales", 5, 17,
            "The Ordnance Survey of the 1880s–1910s at every scale, so it reads from the whole country down to individual farms."),
        nls(NLS_ONE_INCH_7TH, "uk-osgb63k1955", "OS one-inch 1955–61", 7, 15,
            "The last one-inch series, forerunner of Landranger: paths, woods, old railways and land use after the war."),
        nls(NLS_ONE_INCH_HILLS, "uk-osgb63k1885", "OS one-inch 1885–1903", 7, 16,
            "Victorian one-inch with hill hachures: settlement, roads, parkland and woodland at the end of the 1800s."),
        nls(NLS_1920S, "uk-osgb1919", "OS 1920s–40s, all scales", 5, 14,
            "Between the wars: railways at their peak and the tracks used before the motor car took over, at several scales."),
    )

    /** The user's key for [s], empty when they haven't entered it. */
    fun keyFor(s: TileSource, prefs: Prefs): String = when (s.keyKind) {
        KeyKind.OS -> prefs.osApiKey
        KeyKind.MAPTILER -> prefs.mapTilerKey
    }

    fun missingKey(s: TileSource, prefs: Prefs): Boolean = s.requiresKey && keyFor(s, prefs).isBlank()

    fun custom(prefs: Prefs): TileSource? {
        val t = prefs.customTemplate
        if (t.isBlank() || TilePolicy.validateTemplate(t) != null) return null
        val forbidden = TilePolicy.isBulkDownloadForbidden(t)
        return TileSource(
            id = CUSTOM,
            name = prefs.customName.ifBlank { "Custom source" },
            template = t,
            attribution = prefs.customAttribution.ifBlank { "Custom tile source" },
            minZoom = 0,
            maxZoom = prefs.customMaxZoom.coerceIn(1, TilePolicy.MAX_ZOOM),
            offlineDownloadAllowed = prefs.customOfflineAllowed && !forbidden,
            note = if (forbidden) "This host's usage policy forbids bulk downloads; browsing only." else
                "You are responsible for complying with this provider's licence.",
        )
    }

    fun fromPack(p: PackMeta) = TileSource(
        id = "pack:${p.id}",
        name = "${p.name} (offline file)",
        template = null,
        attribution = p.attribution.ifBlank { "Imported map file" },
        minZoom = p.minZoom,
        maxZoom = p.maxZoom,
        packId = p.id,
        note = "Imported MBTiles, fully offline.",
    )

    fun all(prefs: Prefs, packs: List<PackMeta>): List<TileSource> =
        builtIns() + historic() + listOfNotNull(custom(prefs)) +
            packs.filter { it.kind == com.trailmind.app.data.PackKind.IMPORT }.map { fromPack(it) }

    fun baseLayers(prefs: Prefs, packs: List<PackMeta>): List<TileSource> = all(prefs, packs).filterNot { it.overlay }

    fun hillshade(): TileSource = builtIns().single { it.id == GSI_HILLSHADE }

    /** The old map the user chose to draw over the base map, or null for none. */
    fun historicOverlay(prefs: Prefs): TileSource? = historic().firstOrNull { it.id == prefs.historicOverlayId }

    fun byId(id: String, prefs: Prefs, packs: List<PackMeta>): TileSource =
        all(prefs, packs).firstOrNull { it.id == id } ?: builtIns().first()
}
