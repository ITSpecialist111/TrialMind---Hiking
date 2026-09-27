package com.trailmind.app.data

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Default names for downloaded areas, from real OS Names nearest-place answers. */
class OsNamesTest {
    @Test
    fun namesAreasAfterTheNearestPlaceAndItsDistrict() {
        assertEquals("Parkend, Forest of Dean", OsNames.areaName("Parkend", "Village", "", "Forest of Dean", 12.0))
        assertEquals("Grasmere, Westmorland and Furness", OsNames.areaName("Grasmere", "Village", "", "Westmorland and Furness", 8.0))
        assertEquals("Yr Wyddfa, Gwynedd", OsNames.areaName("Yr Wyddfa", "Hill Or Mountain", "", "Gwynedd - Gwynedd", 5.0))
        assertEquals("Forest of Dean", OsNames.areaName("Forest of Dean", "Other Settlement", "", "Forest of Dean", 3.0))
        assertEquals("Ben Macdui", OsNames.areaName("Ben Macdui", "Hill Or Mountain", "", "", 4.0))
    }

    @Test
    fun bigAreasUseTheDistrictAndRoadsUseTheirPlace() {
        assertEquals("Forest of Dean", OsNames.areaName("Upper Whitelea Green", "Woodland Or Forest", "", "Forest of Dean", 29.0))
        assertEquals("Parkend, Forest of Dean", OsNames.areaName("B4234", "Numbered Road", "Parkend", "Forest of Dean", 3.0))
        assertEquals("Westmorland and Furness", OsNames.areaName("A591", "Numbered Road", "", "Westmorland and Furness", 3.0))
        assertEquals("Coleford", OsNames.areaName("GL16 8", "Postcode", "Coleford", "", 3.0))
        assertNull(OsNames.areaName("A4136", "Numbered Road", "", "", 3.0))
        assertNull(OsNames.areaName("", "", "", "", 3.0))
    }
}
