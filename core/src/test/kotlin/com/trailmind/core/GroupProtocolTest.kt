package com.trailmind.core

import com.trailmind.core.frontier.EmergencyStatus
import com.trailmind.core.frontier.group.GroupAdvert
import com.trailmind.core.frontier.group.GroupCode
import com.trailmind.core.frontier.group.GroupFrames
import com.trailmind.core.frontier.group.GroupKeys
import com.trailmind.core.frontier.group.Hkdf
import com.trailmind.core.frontier.group.PeerTable
import com.trailmind.core.frontier.group.PeerTable.Freshness
import com.trailmind.core.frontier.group.PeerTable.Result
import com.trailmind.core.frontier.group.PositionFrame
import com.trailmind.core.frontier.group.ProfileFrame
import com.trailmind.core.frontier.group.RadioMode
import com.trailmind.core.frontier.group.RadioProfile
import com.trailmind.core.frontier.group.RelayPolicy
import com.trailmind.core.frontier.group.ScanDuty
import java.security.SecureRandom
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class GroupProtocolTest {
    private val random = SecureRandom()

    @Test
    fun hkdfMatchesRfc5869() {
        val ikm = ByteArray(22) { 0x0b }
        val prk = Hkdf.extract(ByteArray(13) { it.toByte() }, ikm)
        assertEquals("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5", prk.hex())
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            Hkdf.expand(prk, ByteArray(10) { (0xf0 + it).toByte() }, 42).hex(),
        )
        val prk3 = Hkdf.extract(ByteArray(0), ikm)
        assertEquals("19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04", prk3.hex())
        assertEquals(
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
            Hkdf.expand(prk3, ByteArray(0), 42).hex(),
        )
    }

    @Test
    fun codesRoundTripAndCatchMostTypos() {
        repeat(50) {
            val code = GroupCode.generate(random)
            assertEquals(16, code.text.length)
            assertEquals(code, GroupCode.parse(code.formatted))
            assertEquals(code, GroupCode.parse(code.text.lowercase().chunked(4).joinToString(" ")))
            assertEquals(code, GroupCode.parse(code.text.replace('0', 'O').replace('1', 'l')))
        }
        val code = GroupCode.generate(random)
        val alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        var caught = 0
        var total = 0
        for (i in 0 until GroupCode.LENGTH) for (c in alphabet) {
            if (c == code.text[i]) continue
            total++
            if (GroupCode.parse(code.text.substring(0, i) + c + code.text.substring(i + 1)) == null) caught++
        }
        assertTrue(caught >= total * 0.9, "caught $caught of $total single-character typos")
        assertNull(GroupCode.parse("TOO-SHORT"))
        assertNull(GroupCode.parse(code.text + "0"))
        assertNull(GroupCode.parse(code.text.dropLast(1) + "U"))
        assertEquals("GroupCode(****)", code.toString())
    }

    @Test
    fun keysDependOnlyOnTheCode() {
        val code = GroupCode.generate(random)
        val a = GroupKeys(code)
        val b = GroupKeys(GroupCode.parse(code.text)!!)
        assertEquals(a.groupId, b.groupId)
        assertEquals(16, a.groupId.length)
        assertContentEquals(a.tag(1_000), b.tag(1_000))
        assertFalse(a.tag(1_000).contentEquals(a.tag(1_001)))
        assertNotEquals(GroupKeys(GroupCode.generate(random)).groupId, a.groupId)
    }

    @Test
    fun tagsMatchTheirOwnAndNeighbouringEpochsOnly() {
        val keys = GroupKeys(GroupCode.generate(random))
        val payload = GroupAdvert.build(keys, T, listOf(position(1)), random)
        assertTrue(keys.matches(payload, 1, T))
        assertTrue(keys.matches(payload, 1, T + 900))
        assertTrue(keys.matches(payload, 1, T - 900))
        assertFalse(keys.matches(payload, 1, T + 1_800))
        assertFalse(keys.matches(payload, 1, T - 1_800))
    }

    @Test
    fun advertsRoundTripAndFitOnePacket() {
        val keys = GroupKeys(GroupCode.generate(random))
        val frames = listOf(position(7, sos = true), ProfileFrame(8, 3, "Sam ☃"), position(9).relayed()!!)
        val payload = GroupAdvert.build(keys, T, frames, random)
        assertEquals(185, payload.size + GroupAdvert.AD_OVERHEAD)
        assertEquals(77, GroupAdvert.build(keys, T, frames.take(1), random).size + GroupAdvert.AD_OVERHEAD)
        val opened = assertNotNull(GroupAdvert.open(listOf(GroupKeys(GroupCode.generate(random)), keys), payload, T))
        assertSame(keys, opened.keys)
        assertEquals(frames, opened.frames)
        assertEquals(3, GroupAdvert.maxFrames(251))
        assertEquals(3, GroupAdvert.maxFrames(1_650))
        assertEquals(1, GroupAdvert.maxFrames(80))
        assertEquals(0, GroupAdvert.maxFrames(31))
    }

    @Test
    fun tamperedFramesAndOtherGroupsAreRejected() {
        val keys = GroupKeys(GroupCode.generate(random))
        val payload = GroupAdvert.build(keys, T, listOf(position(1), position(2)), random)
        assertNull(GroupAdvert.open(listOf(GroupKeys(GroupCode.generate(random))), payload, T))
        assertNull(GroupAdvert.open(listOf(keys), payload, T + 1_800))
        // A changed byte in one frame drops that frame only.
        val oneBad = payload.copyOf().also { it[GroupAdvert.HEADER_BYTES + 15] = (it[GroupAdvert.HEADER_BYTES + 15].toInt() xor 1).toByte() }
        assertEquals(listOf(2), GroupAdvert.open(listOf(keys), oneBad, T)!!.frames.map { it.memberId })
        // Frames are bound to their header: moved under the next epoch's tag, none of them opens.
        val next = GroupAdvert.build(keys, T + 900, listOf(position(1), position(2)), random)
        val spliced = next.copyOf(GroupAdvert.HEADER_BYTES) + payload.copyOfRange(GroupAdvert.HEADER_BYTES, payload.size)
        assertNull(GroupAdvert.open(listOf(keys), spliced, T + 900))
        assertNull(GroupAdvert.open(listOf(keys), payload.copyOf().also { it[0] = 2 }, T))
        assertNull(GroupAdvert.open(listOf(keys), payload.copyOf(payload.size - 1), T))
        assertNull(GroupAdvert.open(listOf(keys), ByteArray(0), T))
    }

    @Test
    fun positionFramesKeepPrecisionAndBounds() {
        val f = PositionFrame.of(0x80000001.toInt(), 4_000_000_000L, 1_790_000_000L, 54.5271234, -3.0164567, 949.4, 4.6f, 73,
            EmergencyStatus.OK, capabilities = 5, flags = GroupFrames.FLAG_RECORDING)
        val back = GroupFrames.decode(GroupFrames.encode(f)) as PositionFrame
        assertEquals(f, back)
        assertEquals(54.5271234, back.lat, 1e-7)
        assertEquals(-3.0164567, back.lon, 1e-7)
        assertEquals(949, back.altitudeM)
        assertEquals(GroupFrames.TTL, back.ttl)
        val sos = GroupFrames.decode(GroupFrames.encode(PositionFrame.of(1, 1, 1, 0.0, 0.0, null, 999f, 150, EmergencyStatus.CRITICAL_SOS))) as PositionFrame
        assertNull(sos.altitudeM)
        assertEquals(255, sos.accuracyM)
        assertEquals(100, sos.batteryPercent)
        assertEquals(GroupFrames.SOS_TTL, sos.ttl)
        assertTrue(sos.needsHelp)
        assertNull(GroupFrames.decode(ByteArray(GroupFrames.SIZE)))
        assertNull(GroupFrames.decode(ByteArray(GroupFrames.SIZE - 1)))
        assertNull(GroupFrames.decode(GroupFrames.encode(f).also { it[24] = 200.toByte() }))
    }

    @Test
    fun profileNamesAreCutAtCharacterBoundaries() {
        val name = "Élodie the very long-named hiker 🏔"
        val back = GroupFrames.decode(GroupFrames.encode(ProfileFrame(-5, 7, name))) as ProfileFrame
        assertEquals("Élodie the very long-n", back.name)
        assertEquals(ProfileFrame(-5, 7, back.name), back)
        assertEquals("🏔🏔🏔🏔🏔", (GroupFrames.decode(GroupFrames.encode(ProfileFrame(1, 0, "🏔".repeat(9)))) as ProfileFrame).name)
    }

    @Test
    fun peerTableKeepsTheNewestAndIgnoresItsOwnFrames() {
        val table = PeerTable(ownMemberId = 1)
        assertEquals(Result.REJECTED, table.accept(position(1), 0, T, -60, false))
        val news = position(2, seq = 5)
        assertEquals(Result.NEW, table.accept(news.relayed()!!, 1_000, T, -80, false))
        assertEquals(1, table.peer(2)!!.position!!.hops)
        assertEquals(Result.SAME, table.accept(news, 2_000, T, -70, true))
        val peer = table.peer(2)!!
        assertEquals(0, peer.position!!.hops)
        assertEquals(-70, peer.rssi)
        assertTrue(peer.coded)
        assertEquals(1_000, peer.positionReceivedMs)
        assertEquals(Result.OLDER, table.accept(position(2, time = T - 10, seq = 4), 3_000, T, -60, false))
        assertEquals(5, table.peer(2)!!.position!!.sequence)
        assertEquals(Result.NEWER, table.accept(position(2, time = T + 10, seq = 6), 4_000, T + 10, -60, false))
        assertEquals(Result.REJECTED, table.accept(position(3, time = T + 1_000), 5_000, T, -60, false))
        assertEquals(Result.NEW, table.accept(ProfileFrame(2, 4, "Sam"), 6_000, T, -60, false))
        assertEquals("Sam", table.peer(2)!!.name)
        assertEquals(Result.SAME, table.accept(ProfileFrame(2, 4, "Sam"), 7_000, T, -60, false))
        assertEquals(listOf(2), table.peers().map { it.memberId })
    }

    @Test
    fun freshnessBands() {
        assertEquals(Freshness.FRESH, PeerTable.freshness(position(2, time = T - 120), T))
        assertEquals(Freshness.STALE, PeerTable.freshness(position(2, time = T - 121), T))
        assertEquals(Freshness.STALE, PeerTable.freshness(position(2, time = T - 900), T))
        assertEquals(Freshness.LAST_SEEN, PeerTable.freshness(position(2, time = T - 901), T))
    }

    @Test
    fun relayPassesOnCallsForHelpFirstAndRetiresFrames() {
        val relay = RelayPolicy()
        relay.offer(position(2), 0)
        relay.offer(position(3, sos = true), 0)
        relay.offer(position(4), 0)
        relay.offer(position(5).copy(ttl = 0), 0)
        assertEquals(3, relay.size())
        val first = relay.pick(1_000, T, 2, helpOnly = false)
        assertEquals(listOf(3, 2), first.map { it.memberId })
        assertTrue(first.all { it.hops == 1 })
        assertEquals(listOf(GroupFrames.SOS_TTL - 1, GroupFrames.TTL - 1), first.map { it.ttl })
        assertEquals(listOf(3, 4), relay.pick(2_000, T, 2, helpOnly = false).map { it.memberId })
        assertEquals(listOf(3), relay.pick(3_000, T, 3, helpOnly = true).map { it.memberId })
        // The same news arriving again through another phone doesn't replace the copy with more hops left.
        relay.offer(position(3, sos = true).relayed()!!, 4_000)
        assertEquals(GroupFrames.SOS_TTL - 1, relay.pick(4_000, T, 1, helpOnly = false).single().ttl)
        assertEquals(listOf(3), relay.pick(61_000, T + 61, 3, helpOnly = false).map { it.memberId })
        assertTrue(relay.pick(301_000, T + 301, 3, helpOnly = false).isEmpty())
    }

    @Test
    fun radioProfilesFollowWhatThePhoneIsDoing() {
        assertNull(RadioProfile.plan(uiVisible = false, recording = false, boost = true, batteryPercent = 80, powerSave = false, relay = true))
        val onScreen = RadioProfile.plan(true, false, false, 80, false, true)!!
        assertEquals(RadioMode.ON_SCREEN, onScreen.mode)
        assertEquals(ScanDuty.LOW_LATENCY, onScreen.scan)
        val recording = RadioProfile.plan(false, true, false, 80, false, true)!!
        assertEquals(ScanDuty.BALANCED, recording.scan)
        assertNull(recording.scanRefreshMs)
        val saver = RadioProfile.plan(true, true, false, 20, false, true)!!
        assertEquals(RadioMode.SAVER, saver.mode)
        assertTrue(saver.relayHelpOnly)
        assertEquals(RadioMode.SAVER, RadioProfile.plan(false, true, false, null, true, true)!!.mode)
        val boost = RadioProfile.plan(false, true, true, 10, true, false)!!
        assertEquals(RadioMode.BOOST, boost.mode)
        assertEquals(ScanDuty.LOW_LATENCY, boost.scan)
        assertNotNull(boost.scanRefreshMs)
        assertFalse(boost.relay)
    }

    private fun position(member: Int, time: Long = T, seq: Long = 1, sos: Boolean = false) =
        PositionFrame.of(member, seq, time, 54.5, -3.0, 900.0, 5f, 80, if (sos) EmergencyStatus.CRITICAL_SOS else EmergencyStatus.OK)

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    private companion object {
        /** The middle of a 15-minute epoch, so one epoch either side is exactly ±900 s. */
        const val T = 1_790_000_550L
    }
}
