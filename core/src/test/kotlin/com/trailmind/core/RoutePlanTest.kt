package com.trailmind.core

import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.RoutePlan
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.stats.PaceSettings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RoutePlanTest {
    private val start = LatLon(51.7834, -2.53921)
    private val middle = LatLon(51.784, -2.54)
    private val end = LatLon(51.785, -2.541)

    @Test fun joinsSnappedLegsAndKeepsHeights() {
        val plan = RoutePlan()
        assertTrue(plan.add(start))
        assertTrue(plan.add(middle))
        assertTrue(plan.replaceLeg(0, listOf(TrackPoint(start.lat, start.lon, 200.0), TrackPoint(51.7837, -2.5401, 210.0), TrackPoint(middle.lat, middle.lon, 220.0))))
        assertTrue(plan.add(end))
        assertTrue(plan.replaceLeg(1, listOf(TrackPoint(middle.lat, middle.lon, 220.0), TrackPoint(end.lat, end.lon, 230.0))))
        assertEquals(4, plan.line.size)
        assertEquals(220.0, plan.line[2].ele)
        assertTrue(plan.legs.all { it.snapped })
        assertTrue(plan.legs.all { it.parts.single().points == it.points })
        assertTrue(plan.estimate(PaceSettings(4.5)).ascentM > 0)
        assertTrue(plan.estimate(PaceSettings(4.5)).planningMinutes > 0)
    }

    @Test fun undoClearAndLoop() {
        val plan = RoutePlan()
        assertTrue(plan.add(start))
        assertFalse(plan.backToStart())
        assertTrue(plan.add(middle))
        assertTrue(plan.backToStart())
        assertTrue(plan.isLoop)
        assertEquals(3, plan.line.size)
        assertFalse(plan.add(end))
        assertTrue(plan.undo())
        assertFalse(plan.isLoop)
        assertEquals(2, plan.controlPoints.size)
        plan.clear()
        assertTrue(plan.line.isEmpty())
        assertTrue(plan.legs.isEmpty())
    }

    @Test fun rejectsInvalidSnaps() {
        val plan = RoutePlan()
        plan.add(start)
        plan.add(middle)
        assertFalse(plan.replaceLeg(0, listOf(TrackPoint(52.0, end.lon), TrackPoint(middle.lat, middle.lon))))
        assertFalse(plan.replaceLeg(0, listOf(TrackPoint(start.lat, start.lon))))
        assertFalse(plan.replaceLeg(0, listOf(TrackPoint(start.lat, start.lon), TrackPoint(start.lat, start.lon))))
        assertFalse(plan.legs[0].snapped)
    }

    @Test fun preservesTappedEndpointsWhenRouterSnapsNearby() {
        val plan = RoutePlan()
        plan.add(start)
        plan.add(middle)
        assertTrue(plan.replaceLeg(0, listOf(
            TrackPoint(start.lat + 0.0002, start.lon, 180.0),
            TrackPoint(middle.lat - 0.0004, middle.lon, 190.0),
        )))
        assertEquals(start, plan.line.first().latLon())
        assertEquals(middle, plan.line.last().latLon())
        assertEquals(4, plan.line.size)
        assertEquals(180.0, plan.line.first().ele)
        assertEquals(listOf(false, true, false), plan.legs[0].parts.map { it.snapped })
        assertEquals(start, plan.legs[0].parts.first().points.first().latLon())
        assertEquals(middle, plan.legs[0].parts.last().points.last().latLon())
        assertTrue(Geo.distanceM(plan.line.first().latLon(), plan.line[1].latLon()) > 5)
        assertTrue(plan.estimate(PaceSettings(4.5)).distanceM >
            Geo.distanceM(plan.line[1].latLon(), plan.line[2].latLon()))
    }

    @Test fun shortEndpointOffsetsRemainConnectedAndSolid() {
        val plan = RoutePlan()
        plan.add(start)
        plan.add(middle)
        assertTrue(plan.replaceLeg(0, listOf(
            TrackPoint(start.lat + 0.00001, start.lon),
            TrackPoint(middle.lat - 0.00001, middle.lon),
        )))
        assertEquals(1, plan.legs[0].parts.size)
        assertEquals(plan.line, plan.legs[0].parts.single().points)
        assertTrue(plan.legs[0].parts.single().snapped)
    }

    @Test fun staleReplyCannotReplaceReusedLegIndex() {
        val plan = RoutePlan()
        plan.add(start)
        plan.add(middle)
        val staleLeg = plan.legs[0]
        plan.undo()
        plan.add(middle)
        val snapped = listOf(TrackPoint(start.lat, start.lon, 200.0), TrackPoint(middle.lat, middle.lon, 210.0))
        assertFalse(plan.replaceLeg(0, snapped, staleLeg))
        assertFalse(plan.legs[0].snapped)
        assertTrue(plan.replaceLeg(0, snapped, plan.legs[0]))
    }
}