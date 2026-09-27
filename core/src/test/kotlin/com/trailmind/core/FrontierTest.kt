package com.trailmind.core

import com.trailmind.core.frontier.Bleeding
import com.trailmind.core.frontier.EmergencyStatus
import com.trailmind.core.frontier.FallDetector
import com.trailmind.core.frontier.FallVector
import com.trailmind.core.frontier.FrontierTelemetryCodec
import com.trailmind.core.frontier.GatewayCandidate
import com.trailmind.core.frontier.GatewayElection
import com.trailmind.core.frontier.GroupMeshPayload
import com.trailmind.core.frontier.HikerTelemetry
import com.trailmind.core.frontier.ImuSample
import com.trailmind.core.frontier.InjuryType
import com.trailmind.core.frontier.MeshPacket
import com.trailmind.core.frontier.MeshRelayDeduplicator
import com.trailmind.core.frontier.Mobility
import com.trailmind.core.frontier.TriageCode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FrontierTest {
    @Test
    fun protobufPayloadRoundTripsWithinSatelliteLimit() {
        val source = GroupMeshPayload(
            gatewayDeviceId = "gate0001",
            messageSequence = 42,
            hikers = listOf(telemetry("hiker001"), telemetry("hiker002", EmergencyStatus.INJURED_STATIONARY)),
            fallTelemetry = FallVector(5.2f, 0.8f, -3.5f),
        )
        val bytes = FrontierTelemetryCodec.encode(source)
        assertTrue(bytes.size <= 256)
        assertEquals(source, FrontierTelemetryCodec.decode(bytes))
    }

    @Test
    fun packPrioritizesEmergencyRecordsAndReportsOverflow() {
        val hikers = (1..8).map {
            telemetry("hiker%03d".format(it), if (it == 8) EmergencyStatus.CRITICAL_SOS else EmergencyStatus.OK)
        }
        val packed = FrontierTelemetryCodec.pack(GroupMeshPayload("gate0001", 1, hikers))
        assertTrue(packed.bytes.size <= 256)
        assertTrue("hiker008" in packed.includedHikerIds)
        assertTrue(packed.omittedHikerIds.isNotEmpty())
    }

    @Test
    fun gatewayElectionUsesOrderedCriteria() {
        val elected = GatewayElection.elect(
            listOf(
                GatewayCandidate("fold", false, 100, 100, true),
                GatewayCandidate("ntn-low", true, 20, 1),
                GatewayCandidate("ntn-high", true, 80, 1),
            ),
        )
        assertEquals("ntn-high", elected?.deviceId)
    }

    @Test
    fun relayDeduplicatesAndStopsAfterThreeHops() {
        val dedupe = MeshRelayDeduplicator()
        var packet = MeshPacket(7, "hiker001", 1, payload = byteArrayOf(1))
        packet = assertNotNull(dedupe.accept(packet, 1_000))
        assertEquals(2, packet.ttl)
        assertNull(dedupe.accept(packet, 1_001))

        packet = MeshPacket(8, "hiker001", 2, ttl = 0, payload = byteArrayOf(1))
        assertNull(dedupe.accept(packet, 2_000))
        assertTrue(dedupe.hasSeen(8, 2_000))
    }

    @Test
    fun fallRequiresFreefallImpactAndNinetySecondsImmobility() {
        val detector = FallDetector()
        detector.add(sample(0, 9.80665f, altitude = 100f))
        detector.add(sample(1_000, 0.5f, altitude = 99f))
        detector.add(sample(1_600, 9f, altitude = 97f))
        detector.add(sample(1_700, 18f, altitude = 96.5f))
        detector.add(sample(1_800, 50f, altitude = 96f))
        assertNull(detector.add(sample(90_000, 9.80665f, altitude = 96f)))
        val fall = detector.add(sample(91_800, 9.80665f, altitude = 96f))
        assertNotNull(fall)
        assertTrue(fall.fallVector.impactGForce > 4.5f)
        assertEquals(0.6f, fall.fallVector.freefallDurationSeconds)
        assertEquals(-4f, fall.fallVector.deltaAltitudeMeters)

        detector.add(sample(100_000, 0.5f, altitude = 96f))
        detector.add(sample(100_700, 50f, altitude = 95f))
        assertNotNull(detector.add(sample(190_700, 9.80665f, altitude = 95f)))
    }

    @Test
    fun triageCodeIsOneByteAndReversible() {
        for (injury in InjuryType.entries) for (mobility in Mobility.entries) for (bleeding in Bleeding.entries) {
            val code = TriageCode.encode(injury, mobility, bleeding)
            assertTrue(code in 0..255)
            assertEquals(Triple(injury, mobility, bleeding), TriageCode.decode(code))
        }
        for (code in 0..255) TriageCode.decode(code)
    }

    private fun telemetry(id: String, status: EmergencyStatus = EmergencyStatus.OK) = HikerTelemetry(
        hikerId = id,
        latitude = 54.5271,
        longitude = -3.0164,
        altitudeMeters = 949,
        batteryPercent = 73,
        timestampEpochSeconds = 1_790_000_000,
        status = status,
        triageCode = if (status == EmergencyStatus.OK) 0 else 42,
    )

    private fun sample(timeMs: Long, accelerationZ: Float, altitude: Float) = ImuSample(
        timestampMs = timeMs,
        accelerationX = 0f,
        accelerationY = 0f,
        accelerationZ = accelerationZ,
        gyroscopeX = 0f,
        gyroscopeY = 0f,
        gyroscopeZ = 0f,
        altitudeMeters = altitude,
    )
}
