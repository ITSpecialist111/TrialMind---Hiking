package com.trailmind.app.map

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/** The OSMF tile policy blocks unidentifiable apps, and User-Agents that mention "offline". */
class UserAgentTest {
    @Test
    fun namesTheAppItsVersionAndItsPublicListing() {
        assertEquals(
            "TrailMind/1.2.3 (Android; +https://play.google.com/store/apps/details?id=com.trailmind.app)",
            TileProvider.userAgent("1.2.3", "com.trailmind.app"),
        )
    }

    @Test
    fun neverMentionsOffline() {
        assertFalse("offline" in TileProvider.userAgent("1.0.0", "com.trailmind.app").lowercase())
    }
}
