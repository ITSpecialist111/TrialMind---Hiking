package com.trailmind.core

import com.trailmind.core.stats.LibrarySelection
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class LibrarySelectionTest {
    @Test fun selectsSomeAllAndCancels() {
        val selection = LibrarySelection()
        selection.toggle(1)
        assertEquals(emptySet(), selection.ids)
        selection.begin()
        selection.toggle(1); selection.toggle(2); selection.toggle(1)
        assertEquals(setOf(2L), selection.ids)
        selection.selectAll(listOf(1, 2, 3))
        assertEquals(setOf(1L, 2L, 3L), selection.ids)
        selection.reconcile(listOf(2, 3))
        assertEquals(setOf(2L, 3L), selection.ids)
        selection.cancel()
        assertFalse(selection.enabled)
        assertEquals(emptySet(), selection.ids)
    }
}
