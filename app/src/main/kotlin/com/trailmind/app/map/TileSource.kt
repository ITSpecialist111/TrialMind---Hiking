package com.trailmind.app.map

import com.trailmind.app.data.PackMeta
import com.trailmind.app.data.Prefs
import com.trailmind.core.map.TilePolicy
import java.util.Calendar

/**
 * A raster tile source in Web Mercator (EPSG:3857). Either online (URL template) or an imported
 * MBTiles pack ([packId]).
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
) {
    val isOnline: Boolean get() = template != null

    fun isPremium(z: Int) = premiumFromZoom != null && z >= premiumFromZoom
}

object TileSources {
    const val OSM = "osm"
    const val OS_OUTDOOR = "os_outdoor"
    const val OS_ROAD = "os_road"
    const val OS_LIGHT = "os_light"
    const val CUSTOM = "custom"

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
        note = "Needs your own free OS Data Hub API key. Zoom 7–16 is OS OpenData; zoom 17–20 is " +
            "Premium, counts against your plan's free allowance and is kept for 24 hours at most. " +
            "Offline packs only include OpenData zooms. The 1:25k Explorer-style 'Leisure' layer is only " +
            "offered in British National Grid (EPSG:27700), which TrailMind does not render yet.",
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
