package com.trailmind.core

import com.trailmind.core.geo.MenuMotion
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class MenuMotionTest {
    @Test fun tapsAndVerticalScrollsDoNotStartDragging() {
        assertFalse(MenuMotion.shouldDrag(-7f, 0f, 8f, 1f))
        assertFalse(MenuMotion.shouldDrag(-30f, 80f, 8f, 1f))
        assertFalse(MenuMotion.shouldDrag(-60f, 40f, 8f, 1f))
        assertTrue(MenuMotion.shouldDrag(-61f, 40f, 8f, 1f))
    }

    @Test fun closedOpensRightAndOpenClosesLeft() {
        assertTrue(MenuMotion.shouldDrag(50f, 0f, 8f, 0f))
        assertFalse(MenuMotion.shouldDrag(-50f, 0f, 8f, 0f))
        assertTrue(MenuMotion.shouldDrag(-50f, 0f, 8f, 1f))
        assertFalse(MenuMotion.shouldDrag(50f, 0f, 8f, 1f))
        assertTrue(MenuMotion.shouldDrag(50f, 0f, 8f, 0.5f))
        assertTrue(MenuMotion.shouldDrag(-50f, 0f, 8f, 0.5f))
    }

    @Test fun dragFollowsFingerAndClampsAtEdges() {
        assertEquals(0.75f, MenuMotion.fraction(1f, -100f, 400f))
        assertEquals(0.25f, MenuMotion.fraction(0f, 100f, 400f))
        assertEquals(0f, MenuMotion.fraction(1f, -800f, 400f))
        assertEquals(1f, MenuMotion.fraction(0f, 800f, 400f))
        assertFailsWith<IllegalArgumentException> { MenuMotion.fraction(0f, 100f, 0f) }
    }

    @Test fun slowDragSettlesAtHalfwayAndFlickFollowsDirection() {
        assertFalse(MenuMotion.settleOpen(0.49f, 0f, 600f))
        assertTrue(MenuMotion.settleOpen(0.5f, 0f, 600f))
        assertTrue(MenuMotion.settleOpen(0.1f, 600f, 600f))
        assertFalse(MenuMotion.settleOpen(0.9f, -600f, 600f))
        assertFalse(MenuMotion.settleOpen(0.1f, 599f, 600f))
    }
}
