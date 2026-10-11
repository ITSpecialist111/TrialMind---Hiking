package com.trailmind.core

import com.trailmind.core.frontier.EmergencyStatus
import com.trailmind.core.frontier.group.GroupFrames
import com.trailmind.core.frontier.group.GroupHikeWatch
import com.trailmind.core.frontier.group.PeerTable
import com.trailmind.core.frontier.group.PositionFrame
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class GroupHikeTest {
    private val watch = GroupHikeWatch()
    private val nowS = 1_790_000_000L
    private val nowMs = nowS * 1_000

    private val recordingForGroup = GroupFrames.FLAG_RECORDING or GroupFrames.FLAG_GROUP_HIKE

    private fun peer(id: Int, flags: Int, ageS: Long = 10, sequence: Long = 1, atS: Long = nowS) = PeerTable.Peer(
        memberId = id,
        position = PositionFrame.of(id, sequence, atS - ageS, 51.8, -2.5, 120.0, 5f, 80, EmergencyStatus.OK, flags = flags),
    )

    @Test fun theGroupHikeFlagSurvivesTheAir() {
        val f = PositionFrame.of(7, 1, nowS, 51.8, -2.5, null, 5f, 90, EmergencyStatus.OK, flags = recordingForGroup)
        val back = GroupFrames.decode(GroupFrames.encode(f)) as PositionFrame
        assertEquals(recordingForGroup, back.flags)
        assertTrue(GroupHikeWatch.isGroupHike(back))
        // A solo recording is not an invitation.
        assertFalse(GroupHikeWatch.isGroupHike(back.copy(flags = GroupFrames.FLAG_RECORDING)))
        // Nor is a paused group hike.
        assertFalse(GroupHikeWatch.isGroupHike(back.copy(flags = GroupFrames.FLAG_PAUSED or GroupFrames.FLAG_GROUP_HIKE)))
    }

    @Test fun aMemberRecordingForTheGroupIsOfferedOnce() {
        val peers = listOf(peer(1, recordingForGroup))
        assertEquals(1, watch.next(peers, nowS, nowMs)?.memberId)
        assertNull(watch.next(peers, nowS + 5, nowMs + 5_000))
    }

    @Test fun nothingIsOfferedForSoloIdleOrStaleMembers() {
        val peers = listOf(
            peer(1, GroupFrames.FLAG_RECORDING),
            peer(2, 0),
            peer(3, recordingForGroup, ageS = PeerTable.FRESH_S + 1),
            PeerTable.Peer(4),
        )
        assertNull(watch.next(peers, nowS, nowMs))
    }

    @Test fun theFreshestHikeWinsWhenSeveralAreGoingOn() {
        val peers = listOf(peer(1, recordingForGroup, ageS = 60), peer(2, recordingForGroup, ageS = 5))
        assertEquals(2, watch.next(peers, nowS, nowMs)?.memberId)
        assertEquals(1, watch.next(peers, nowS, nowMs)?.memberId)
        assertNull(watch.next(peers, nowS, nowMs))
    }

    @Test fun aPausedHikeIsNotOfferedAgainOnceTheMemberResumes() {
        assertEquals(1, watch.next(listOf(peer(1, recordingForGroup)), nowS, nowMs)?.memberId)
        // They stop for lunch (or the car park): still the same hike.
        assertNull(watch.next(listOf(peer(1, GroupFrames.FLAG_PAUSED or GroupFrames.FLAG_GROUP_HIKE)), nowS + 600, nowMs + 600_000))
        assertNull(watch.next(listOf(peer(1, recordingForGroup)), nowS + 1_200, nowMs + 1_200_000))
    }

    @Test fun aNewHikeAfterTheOldOneEndedIsOffered() {
        assertEquals(1, watch.next(listOf(peer(1, recordingForGroup)), nowS, nowMs)?.memberId)
        assertNull(watch.next(listOf(peer(1, 0)), nowS + 3_600, nowMs + 3_600_000))
        val later = peer(1, recordingForGroup, ageS = 5, sequence = 9, atS = nowS + 7_200)
        assertEquals(1, watch.next(listOf(later), nowS + 7_200, nowMs + 7_200_000)?.memberId)
    }

    @Test fun finishingYourOwnHikeDoesNotPullYouBackIn() {
        val peers = listOf(peer(1, recordingForGroup), peer(2, 0))
        watch.handleAll(peers, nowMs)
        assertNull(watch.next(peers, nowS + 30, nowMs + 30_000))
        // Someone else starting afterwards is still offered.
        assertEquals(2, watch.next(listOf(peer(1, recordingForGroup), peer(2, recordingForGroup)), nowS + 60, nowMs + 60_000)?.memberId)
    }

    @Test fun aDayLaterAHikeStillGoingOnIsOfferedAgain() {
        assertEquals(1, watch.next(listOf(peer(1, recordingForGroup)), nowS, nowMs)?.memberId)
        val day = 25 * 3_600L
        assertEquals(1, watch.next(listOf(peer(1, recordingForGroup, ageS = 5, atS = nowS + day)), nowS + day, nowMs + day * 1_000)?.memberId)
    }

    @Test fun clearForgetsEverything() {
        val peers = listOf(peer(1, recordingForGroup))
        watch.next(peers, nowS, nowMs)
        watch.clear()
        assertEquals(1, watch.next(peers, nowS, nowMs + 1)?.memberId)
    }

    @Test fun anOfferThatCouldNotBeShownCanBeMadeAgain() {
        val peers = listOf(peer(1, recordingForGroup))
        assertEquals(1, watch.next(peers, nowS, nowMs)?.memberId)
        watch.forget(1)
        assertEquals(1, watch.next(peers, nowS + 5, nowMs + 5_000)?.memberId)
    }
}
