package com.trailmind.core

import com.trailmind.core.frontier.EmergencyStatus
import com.trailmind.core.frontier.group.GroupAdvert
import com.trailmind.core.frontier.group.GroupCode
import com.trailmind.core.frontier.group.GroupFrames
import com.trailmind.core.frontier.group.GroupKeys
import com.trailmind.core.frontier.group.PeerTable
import com.trailmind.core.frontier.group.PositionFrame
import com.trailmind.core.frontier.group.RangeFrame
import com.trailmind.core.frontier.group.UwbSession
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.security.SecureRandom
import kotlin.random.Random

class GroupFindingTest {
    private val code = GroupCode.generate(SecureRandom())

    @Test fun rangeFramesSurviveTheAirAndAreNeverPassedOn() {
        val request = RangeFrame(0x11223344, -5, RangeFrame.REQUEST, Long.MIN_VALUE + 7, 0xFFFF_FFF0L,
            configId = UwbSession.CONFIG_PROVISIONED, channel = 9, preambleIndex = 11, updateRate = 1)
        val bytes = GroupFrames.encode(request)
        assertEquals(GroupFrames.SIZE, bytes.size)
        assertEquals(request, GroupFrames.decode(bytes))
        assertNull(request.relayed())
        assertEquals(0, request.hops)
        val declined = request.copy(kind = RangeFrame.DECLINE, reason = RangeFrame.REASON_BUSY)
        assertEquals(declined, GroupFrames.decode(GroupFrames.encode(declined)))
        // Kinds this version doesn't know are dropped, not guessed at.
        for (kind in listOf(0, 5, 15)) {
            val unknown = bytes.copyOf().also { it[0] = ((GroupFrames.TYPE_RANGE shl 4) or kind).toByte() }
            assertNull(GroupFrames.decode(unknown))
        }

        val keys = GroupKeys(code)
        val position = PositionFrame.of(0x11223344, 3, 1_700_000_000, 54.5, -3.0, 900.0, 5f, 80, EmergencyStatus.OK)
        val advert = GroupAdvert.build(keys, 1_700_000_000, listOf(position, request), SecureRandom())
        assertEquals(listOf(position, request), GroupAdvert.open(listOf(keys), advert, 1_700_000_000)!!.frames)
    }

    @Test fun aRangeFrameCountsAsHearingTheMemberDirectly() {
        val table = PeerTable(ownMemberId = 1)
        val frame = RangeFrame(2, 1, RangeFrame.ACCEPT, 42, 1_700_000_000)
        assertEquals(PeerTable.Result.SAME, table.accept(frame, 5_000, 1_700_000_000, -61, coded = true))
        val peer = table.peer(2)!!
        assertEquals(5_000, peer.lastDirectMs)
        assertEquals(-61, peer.rssi)
        assertTrue(peer.coded)
        assertNull(peer.position)
        assertEquals(PeerTable.Result.REJECTED, table.accept(frame.copy(memberId = 1), 6_000, 1_700_000_000, -50, coded = false))
    }

    @Test fun bothPhonesWorkOutTheSameSession() {
        val finder = UwbSession.derive(GroupKeys(code), 7, 9, 1234)
        val found = UwbSession.derive(GroupKeys(GroupCode.parse(code.text)!!), 7, 9, 1234)
        assertEquals(finder.sessionId, found.sessionId)
        assertArrayEquals(finder.localAddress(initiator = true), found.peerAddress(initiator = false))
        assertArrayEquals(finder.peerAddress(initiator = true), found.localAddress(initiator = false))
        assertArrayEquals(finder.keyFor(UwbSession.CONFIG_PROVISIONED), found.keyFor(UwbSession.CONFIG_PROVISIONED))
        assertArrayEquals(finder.keyFor(UwbSession.CONFIG_STATIC), found.keyFor(UwbSession.CONFIG_STATIC))
        assertNull(finder.keyFor(2))

        val again = UwbSession.derive(GroupKeys(code), 7, 9, 1235)
        assertNotEquals(finder.sessionId, again.sessionId)
        assertFalse(finder.keyFor(UwbSession.CONFIG_PROVISIONED)!!.contentEquals(again.keyFor(UwbSession.CONFIG_PROVISIONED)))
        val otherGroup = UwbSession.derive(GroupKeys(GroupCode.generate(SecureRandom())), 7, 9, 1234)
        assertFalse(finder.keyFor(UwbSession.CONFIG_PROVISIONED)!!.contentEquals(otherGroup.keyFor(UwbSession.CONFIG_PROVISIONED)))
        val reversed = UwbSession.derive(GroupKeys(code), 9, 7, 1234)
        assertNotEquals(finder.sessionId, reversed.sessionId)
    }

    @Test fun sessionsAreAlwaysUsable() {
        val keys = GroupKeys(code)
        val random = Random(5)
        repeat(3_000) {
            val s = UwbSession.derive(keys, random.nextInt(), random.nextInt(), random.nextLong())
            assertTrue(s.sessionId > 0)
            val a = s.localAddress(true)
            val b = s.localAddress(false)
            assertEquals(2, a.size)
            assertFalse(a.contentEquals(b))
            for (address in listOf(a, b)) {
                val v = ((address[0].toInt() and 0xFF) shl 8) or (address[1].toInt() and 0xFF)
                assertTrue(v != 0x0000 && v != 0xFFFF, "address $v")
            }
            assertEquals(16, s.keyFor(UwbSession.CONFIG_PROVISIONED)!!.size)
            val static = s.keyFor(UwbSession.CONFIG_STATIC)!!
            assertEquals(8, static.size)
            assertTrue(static[0].toInt() != 0 || static[1].toInt() != 0)
        }
    }
}
