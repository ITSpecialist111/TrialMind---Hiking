package com.trailmind.core

import com.trailmind.core.ai.Briefing
import com.trailmind.core.ai.BriefingInput
import com.trailmind.core.geo.Facility
import com.trailmind.core.geo.FacilityCategory
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.RouteFacilities
import com.trailmind.core.stats.HikeEstimate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RouteFacilitiesTest {
    @Test fun narrowsLongRoutesWithoutDroppingBelowHundredMetres() {
        val short = listOf(LatLon(51.0, -2.0), LatLon(51.1, -2.0))
        val long = (0..20).map { LatLon(51.0 + it * 0.05, -2.0) }
        assertEquals(250, RouteFacilities.corridorM(short))
        assertTrue(RouteFacilities.corridorM(long) in 100..249)
        assertEquals(100, RouteFacilities.corridorM((0..80).map { LatLon(51.0 + it * 0.05, -2.0) }))
        val near = Facility(FacilityCategory.WATER, LatLon(51.0018, -1.997))
        assertTrue(RouteFacilities.locate(short, listOf(near), 100).isEmpty())
    }

    @Test fun simplifiesWithEndpointsAndPointLimit() {
        val route = (0..1000).map { LatLon(51.78 + it * 0.00001, -2.54 + kotlin.math.sin(it / 12.0) * 0.0003) }
        val reduced = RouteFacilities.simplify(route)
        assertTrue(reduced.size <= 150)
        assertEquals(route.first(), reduced.first())
        assertEquals(route.last(), reduced.last())
        val longRoute = (0..1000).map { LatLon(51.0 + it * 0.003, -2.54 + kotlin.math.sin(it / 2.0) * 0.5) }
        assertTrue(RouteFacilities.simplify(longRoute).size <= 150)
        val folded = (0..1000).map { index ->
            LatLon(51.0, if (index % 3 == 0) -2.54 else if (index % 3 == 1) -2.538 else -2.542)
        }
        assertTrue(RouteFacilities.simplify(folded).size <= 150)
    }

    @Test fun projectsFiltersAndDeduplicatesLoop() {
        val route = listOf(LatLon(51.78, -2.54), LatLon(51.78, -2.53), LatLon(51.781, -2.53), LatLon(51.781, -2.54), LatLon(51.78, -2.54))
        val items = listOf(
            Facility(FacilityCategory.PARKING, route.first(), "New Fancy"),
            Facility(FacilityCategory.PARKING, LatLon(51.78001, -2.54), "New Fancy"),
            Facility(FacilityCategory.CAFE, LatLon(51.78, -2.535), "Café"),
            Facility(FacilityCategory.WATER, LatLon(51.79, -2.535)),
        )
        val found = RouteFacilities.locate(route, items)
        assertEquals(2, found.size)
        assertEquals(FacilityCategory.PARKING, found[0].category)
        assertEquals(0.0, found[0].alongM, 1.0)
        assertTrue(found[1].alongM > 300)
        assertTrue(found[1].offM < 2)
    }

    @Test fun assignsFacilityNearBothLegsToFirstPassing() {
        val route = listOf(LatLon(51.0, -2.0), LatLon(51.0, -1.99), LatLon(51.0005, -1.99), LatLon(51.0005, -2.0))
        val item = Facility(FacilityCategory.WATER, LatLon(51.00048, -1.995))
        val found = RouteFacilities.locate(route, listOf(item)).single()
        assertTrue(found.alongM < 700, "Expected first leg, got ${found.alongM} m")
    }

    @Test fun favoursClosePassOverEarlierCorridorEdge() {
        val route = listOf(LatLon(51.0, -2.0), LatLon(51.0, -1.99), LatLon(51.002, -1.99), LatLon(51.002, -2.0))
        val found = RouteFacilities.locate(route,
            listOf(Facility(FacilityCategory.CAFE, LatLon(51.0019, -1.995)))).single()
        assertTrue(found.alongM > 900, "Expected close return leg, got ${found.alongM} m")
        assertTrue(found.offM < 20)
    }

    @Test fun rejectsPrivateAndUnnamedPeaks() {
        assertEquals(null, FacilityCategory.fromTags(mapOf("amenity" to "parking", "access" to "private")))
        assertEquals(null, FacilityCategory.fromTags(mapOf("natural" to "peak")))
        assertEquals(FacilityCategory.PEAK, FacilityCategory.fromTags(mapOf("natural" to "peak", "name" to "May Hill")))
    }

    @Test fun briefingOnlyIncludesSavedFacilities() {
        val base = BriefingInput("Loop", HikeEstimate(60.0, 70.0, 4000.0, 0.0, 0.0),
            LatLon(51.78, -2.54), LatLon(51.78, -2.54), null, emptyList(), null, 0L)
        assertTrue(Briefing.ruleBased(base).none { it.startsWith("Facilities:") })
        val withWater = base.copy(facilities = listOf(Facility(FacilityCategory.WATER, base.start, alongM = 1200.0)))
        assertTrue(Briefing.ruleBased(withWater).any { it == "Facilities: Drinking water at 1.20 km." })
        assertTrue(Briefing.ruleBased(withWater.copy(facilitiesPartial = true))
            .any { it == "Facilities (limited results): Drinking water at 1.20 km." })
    }
}