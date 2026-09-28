package com.trailmind.app.map

import com.trailmind.app.data.PackMeta
import com.trailmind.app.data.Prefs
import com.trailmind.core.map.TilePolicy
import java.util.Calendar

/** How a source's z/x/y tiles are laid out. */
enum class TileGrid { WEB_MERCATOR, BRITISH_NATIONAL_GRID }

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
    const val CUSTOM = "custom"

    // Where the map credits lead: OSM's licence and error reporting, OS's terms and its Errors and Omissions Tool.
    const val OSM_COPYRIGHT_URL = "https://www.openstreetmap.org/copyright"
    const val OSM_FIX_THE_MAP_URL = "https://www.openstreetmap.org/fixthemap"
    const val OS_TERMS_URL = "https://www.ordnancesurvey.co.uk/legal"
    const val OS_ERRORS_URL = "https://osdatahub.os.uk/apps/errors-and-omissions"

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
    )

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
        builtIns() + listOfNotNull(custom(prefs)) +
            packs.filter { it.kind == com.trailmind.app.data.PackKind.IMPORT }.map { fromPack(it) }

    fun byId(id: String, prefs: Prefs, packs: List<PackMeta>): TileSource =
        all(prefs, packs).firstOrNull { it.id == id } ?: builtIns().first()
}
