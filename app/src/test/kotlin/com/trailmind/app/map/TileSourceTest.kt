package com.trailmind.app.map

import com.trailmind.core.geo.TileKey
import com.trailmind.core.map.TilePolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Guards the OS Data Hub licence rules: offline packs hold OpenData only, Premium is cache-limited. */
class TileSourceTest {
    private val os = TileSources.builtIns().filter { it.requiresKey }

    @Test
    fun watchRequestsNeverLoadPremiumEvenWhenItIsCachedOnThePhone() {
        os.forEach { source ->
            for (zoom in source.minZoom..source.maxZoom) {
                val request = TileKey(zoom, 12345, 23456)
                val loaded = TilePolicy.openDataTile(request, source.premiumFromZoom)
                assertFalse(source.isPremium(loaded.z), "${source.id}: $request became $loaded")
                if (source.isPremium(zoom)) {
                    assertEquals(source.premiumFromZoom!! - 1, loaded.z)
                    val scale = 1 shl (zoom - loaded.z)
                    assertEquals(request.x / scale, loaded.x)
                    assertEquals(request.y / scale, loaded.y)
                } else assertEquals(request, loaded)
            }
        }
        val osm = TileKey(19, 12345, 23456)
        assertEquals(osm, TilePolicy.openDataTile(osm, null))
    }

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
    fun explorerAndLandrangerStoresOnlyOpenDataInPacks() {
        val leisure = TileSources.builtIns().single { it.id == TileSources.OS_LEISURE }
        assertTrue(leisure.offlineDownloadAllowed)
        assertEquals(5, leisure.downloadMaxZoom)
        assertEquals(6, leisure.premiumFromZoom)
        (0..5).forEach { assertTrue(leisure.canStoreInPack(it)) }
        (6..9).forEach { assertFalse(leisure.canStoreInPack(it), "Leisure zoom $it must not enter MBTiles") }
    }

    @Test
    fun offlinePacksNeverReachPremiumZooms() {
        TileSources.builtIns().filter { it.offlineDownloadAllowed }.forEach { s ->
            val premium = s.premiumFromZoom ?: return@forEach
            assertTrue(s.downloadMaxZoom < premium, "${s.id} downloads up to ${s.downloadMaxZoom}, Premium starts at $premium")
        }
    }

    @Test
    fun builtInPremiumNeverReadsPacksButImportsCan() {
        os.forEach { source ->
            assertTrue(source.canReadFromPack(source.premiumFromZoom!! - 1))
            assertFalse(source.canReadFromPack(source.premiumFromZoom))
        }
        assertTrue(os.first().copy(packId = 42).canReadFromPack(os.first().premiumFromZoom!!))
    }

    @Test
    fun openStreetMapIsNeverDownloadable() {
        val osm = TileSources.builtIns().single { it.id == TileSources.OSM }
        assertFalse(osm.offlineDownloadAllowed)
        assertFalse(osm.isPremium(19))
    }
}
