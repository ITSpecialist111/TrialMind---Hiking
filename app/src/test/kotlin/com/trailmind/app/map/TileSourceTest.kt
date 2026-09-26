package com.trailmind.app.map

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Guards the OS Data Hub licence rules: offline packs hold OpenData only, Premium is cache-limited. */
class TileSourceTest {
    private val os = TileSources.builtIns().filter { it.requiresKey }

    @Test
    fun osSourcesMarkPremiumWhereOsDoes() {
        assertTrue(os.isNotEmpty())
        os.forEach { s ->
            // OS: zoom 17+ in Web Mercator, and Leisure zoom 6+ in British National Grid.
            val from = if (s.grid == TileGrid.BRITISH_NATIONAL_GRID) 6 else 17
            assertEquals(from, s.premiumFromZoom, s.id)
            assertFalse(s.isPremium(from - 1), s.id)
            assertTrue(s.isPremium(from), s.id)
        }
    }

    @Test
    fun explorerAndLandrangerIsNeverDownloadable() {
        assertFalse(TileSources.builtIns().single { it.id == TileSources.OS_LEISURE }.offlineDownloadAllowed)
    }

    @Test
    fun offlinePacksNeverReachPremiumZooms() {
        TileSources.builtIns().filter { it.offlineDownloadAllowed }.forEach { s ->
            val premium = s.premiumFromZoom ?: return@forEach
            assertTrue(s.downloadMaxZoom < premium, "${s.id} downloads up to ${s.downloadMaxZoom}, Premium starts at $premium")
        }
    }

    @Test
    fun openStreetMapIsNeverDownloadable() {
        val osm = TileSources.builtIns().single { it.id == TileSources.OSM }
        assertFalse(osm.offlineDownloadAllowed)
        assertFalse(osm.isPremium(19))
    }
}
