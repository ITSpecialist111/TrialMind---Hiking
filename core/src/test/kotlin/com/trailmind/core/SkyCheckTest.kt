package com.trailmind.core

import com.trailmind.core.frontier.SkyCheck
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SkyCheckTest {
    private fun rgb(r: Int, g: Int, b: Int) = (0xFF shl 24) or (r shl 16) or (g shl 8) or b

    @Test
    fun skyColoursAreSkyAndGroundColoursAreNot() {
        assertTrue(SkyCheck.isSky(rgb(120, 170, 235)), "blue sky")
        assertTrue(SkyCheck.isSky(rgb(205, 210, 215)), "overcast")
        assertTrue(SkyCheck.isSky(rgb(250, 250, 240)), "bright cloud")
        assertFalse(SkyCheck.isSky(rgb(60, 110, 50)), "leaves")
        assertFalse(SkyCheck.isSky(rgb(150, 190, 90)), "sunlit grass")
        assertFalse(SkyCheck.isSky(rgb(30, 30, 35)), "dark trunk")
        assertFalse(SkyCheck.isSky(rgb(140, 105, 80)), "rock")
    }

    @Test
    fun percentageOnlyCountsPixelsAboveTheMinimumElevation() {
        val w = 4; val h = 8
        // Top half sky, bottom half trees. Camera points 40 degrees up, 60 degree field of view:
        // row 0 is at ~67 degrees, the last row at ~13 degrees, so rows above ~25 degrees are the first 6.
        val px = IntArray(w * h) { if (it / w < 4) rgb(120, 170, 235) else rgb(40, 90, 40) }
        val r = SkyCheck.analyse(px, w, h, pitchDeg = 40.0, vFovDeg = 60.0)
        assertEquals(67, r.openAbove25Pct) // 4 sky rows of the 6 that count
        assertNotNull(r.line25Frac)
        assertEquals(0.5f + 0.25f, r.line25Frac!!, 0.001f)
    }

    @Test
    fun lookingLevelShowsNothingAboveTheLineOrThe25DegreeLineOffScreen() {
        val px = IntArray(16) { rgb(120, 170, 235) }
        val level = SkyCheck.analyse(px, 4, 4, pitchDeg = -20.0, vFovDeg = 40.0)
        assertNull(level.openAbove25Pct)
        assertNull(level.line25Frac)
    }
}
