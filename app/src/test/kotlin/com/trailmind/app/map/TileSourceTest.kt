package com.trailmind.app.map

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Guards the OS Data Hub licence rules: offline packs hold OpenData only, Premium is cache-limited. */
class TileSourceTest {
    private val os = TileSources.builtIns().filter { it.requiresKey }

    @Test
    fun osSourcesMarkPremiumFromZoom17() {
        assertTrue(os.isNotEmpty())
        os.forEach { s ->
            assertEquals(17, s.premiumFromZoom, s.id)
            assertFalse(s.isPremium(16), s.id)
            assertTrue(s.isPremium(17), s.id)
        }
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
