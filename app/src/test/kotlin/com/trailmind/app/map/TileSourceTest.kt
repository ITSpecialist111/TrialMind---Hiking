package com.trailmind.app.map

import com.trailmind.core.geo.BoundingBox
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

    @Test
    fun gsiJapanMapIsBrowseOnlyWebMercatorWithCredit() {
        val gsi = TileSources.builtIns().single { it.id == TileSources.GSI_STD }
        assertEquals("https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png", gsi.template)
        assertEquals(null, TilePolicy.validateTemplate(gsi.template!!))
        assertEquals(TileGrid.WEB_MERCATOR, gsi.grid)
        assertEquals(18, gsi.maxZoom)
        assertFalse(gsi.requiresKey)
        assertFalse(gsi.offlineDownloadAllowed)
        (0..20).forEach { assertFalse(gsi.canStoreInPack(it), "GSI zoom $it must not enter MBTiles") }
        assertTrue(gsi.attribution.startsWith("出典：国土地理院"))
    }

    @Test
    fun gsiPhotoAndHillshadeCanBeSavedOffline() {
        val photo = TileSources.builtIns().single { it.id == TileSources.GSI_PHOTO }
        val shade = TileSources.hillshade()
        listOf(photo, shade).forEach { s ->
            assertEquals(null, TilePolicy.validateTemplate(s.template!!), s.id)
            assertFalse(TilePolicy.isBulkDownloadForbidden(s.template!!), s.id)
            assertTrue(s.offlineDownloadAllowed, s.id)
            assertFalse(s.requiresKey, s.id)
            assertEquals(null, s.premiumFromZoom, s.id)
            assertEquals(TileSources.GSI_ATTRIBUTION, s.attribution, s.id)
            assertTrue(s.canStoreInPack(s.downloadMaxZoom), s.id)
        }
        assertEquals(17, photo.downloadMaxZoom)
        assertEquals(16, shade.maxZoom)
        assertFalse(photo.overlay)
        assertTrue(shade.overlay)
        assertEquals(listOf(TileSources.GSI_HILLSHADE), TileSources.builtIns().filter { it.overlay }.map { it.id })
    }

    @Test
    fun hillshadeIsOnlyRequestedAroundJapan() {
        assertTrue(TileSources.overlapsJapan(BoundingBox(35.3, 138.6, 35.5, 138.9)))
        assertFalse(TileSources.overlapsJapan(BoundingBox(51.7, -2.6, 51.8, -2.5)))
    }

    @Test
    fun oldMapsAreMapTilerOverlaysThatAreNeverSavedOffline() {
        val old = TileSources.historic()
        assertEquals(6, old.size)
        assertEquals(old.size, old.map { it.id }.toSet().size)
        old.forEach { s ->
            assertTrue(s.historic && s.overlay && s.requiresKey, s.id)
            assertEquals(KeyKind.MAPTILER, s.keyKind, s.id)
            assertEquals(null, TilePolicy.validateTemplate(s.template!!), s.id)
            assertTrue(s.template!!.startsWith("https://api.maptiler.com/tiles/") && s.template!!.contains("{key}"), s.id)
            // MapTiler's terms forbid bulk downloads, so even a pasted copy of the template can't be downloaded.
            assertTrue(TilePolicy.isBulkDownloadForbidden(s.template!!), s.id)
            assertFalse(s.offlineDownloadAllowed, s.id)
            (0..TilePolicy.MAX_ZOOM).forEach { assertFalse(s.canStoreInPack(it), "${s.id} zoom $it must not enter MBTiles") }
            assertEquals(null, s.premiumFromZoom, s.id)
            assertTrue(s.attribution.contains("National Library of Scotland"), s.id)
            assertTrue(s.minZoom in 5..10 && s.maxZoom in 14..17, s.id)
        }
    }

    @Test
    fun eachOldMapStopsAtTheZoomMapTilerServesIt() {
        // Read from MapTiler's tiles.json and confirmed with real tiles: one level further is HTTP 400.
        val served = mapOf(
            TileSources.NLS_SIX_INCH to 17, TileSources.NLS_25K to 16, TileSources.NLS_1900S to 17,
            TileSources.NLS_ONE_INCH_7TH to 15, TileSources.NLS_ONE_INCH_HILLS to 16, TileSources.NLS_1920S to 14,
        )
        served.forEach { (id, zoom) -> assertEquals(zoom, TileSources.historic().first { it.id == id }.maxZoom, id) }
    }

    @Test
    fun oldMapsStayOutOfTheBuiltInsTheOsLicenceTestsLookAt() {
        assertTrue(TileSources.builtIns().none { it.historic || it.keyKind != KeyKind.OS })
        assertEquals(listOf(TileSources.GSI_HILLSHADE), TileSources.builtIns().filter { it.overlay }.map { it.id })
    }

    @Test
    fun oldMapsOpenOnTheForestOfDeanWithTheSixInchFirst() {
        assertEquals(TileSources.NLS_SIX_INCH, TileSources.historic().first().id)
        val d = 0.05
        assertTrue(TileSources.overlapsBritain(BoundingBox(
            TileSources.FOREST_OF_DEAN_LAT - d, TileSources.FOREST_OF_DEAN_LON - d,
            TileSources.FOREST_OF_DEAN_LAT + d, TileSources.FOREST_OF_DEAN_LON + d)))
        TileSources.historic().forEach { s ->
            assertTrue(TileSources.FOREST_OF_DEAN_ZOOM >= s.minZoom && TileSources.FOREST_OF_DEAN_ZOOM <= s.maxZoom + 4, s.id)
        }
    }

    @Test
    fun oldMapsAreOnlyRequestedOverBritain() {
        assertTrue(TileSources.overlapsBritain(BoundingBox(51.7, -2.6, 51.8, -2.5)))
        assertTrue(TileSources.overlapsBritain(BoundingBox(57.0, -6.5, 58.0, -5.0)))
        assertFalse(TileSources.overlapsBritain(BoundingBox(35.3, 138.6, 35.5, 138.9)))
        assertFalse(TileSources.overlapsBritain(BoundingBox(48.0, 2.0, 48.9, 2.6)))
    }
}
