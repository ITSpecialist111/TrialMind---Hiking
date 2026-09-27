package com.trailmind.core.frontier

import java.util.ArrayDeque
import kotlin.math.sqrt

data class ImuSample(
    val timestampMs: Long,
    val accelerationX: Float,
    val accelerationY: Float,
    val accelerationZ: Float,
    val gyroscopeX: Float,
    val gyroscopeY: Float,
    val gyroscopeZ: Float,
    val altitudeMeters: Float? = null,
)

data class DetectedFall(
    val impactTimestampMs: Long,
    val fallVector: FallVector,
    val preImpactSamples: List<ImuSample>,
)

/**
 * Deterministic fall state machine: freefall below 0.2 g, impact above 4.5 g, then 90 seconds
 * without material acceleration or rotation. The retained evidence is bounded to 60 seconds.
 */
class FallDetector(
    private val bufferDurationMs: Long = 60_000L,
    private val immobilityDurationMs: Long = 90_000L,
) {
    private val samples = ArrayDeque<ImuSample>()
    private var freefallStartedMs: Long? = null
    private var freefallEndedMs: Long? = null
    private var impact: ImuSample? = null
    private var freefallDurationMs = 0L
    private var stationaryStartedMs: Long? = null
    private var preImpactEvidence = emptyList<ImuSample>()

    fun add(sample: ImuSample): DetectedFall? {
        samples.addLast(sample)
        while (samples.isNotEmpty() && sample.timestampMs - samples.first().timestampMs > bufferDurationMs) {
            samples.removeFirst()
        }

        val accelerationG = magnitude(sample.accelerationX, sample.accelerationY, sample.accelerationZ) / STANDARD_GRAVITY
        val rotation = magnitude(sample.gyroscopeX, sample.gyroscopeY, sample.gyroscopeZ)
        val currentImpact = impact
        if (currentImpact == null) {
            if (accelerationG < FREEFALL_G) {
                if (freefallStartedMs == null) freefallStartedMs = sample.timestampMs
                freefallEndedMs = null
            } else {
                val freefallStart = freefallStartedMs
                if (freefallStart != null) {
                    val freefallEnd = freefallEndedMs ?: sample.timestampMs.also { freefallEndedMs = it }
                    if (accelerationG > IMPACT_G && sample.timestampMs - freefallEnd <= IMPACT_WINDOW_MS) {
                        impact = sample
                        freefallDurationMs = freefallEnd - freefallStart
                        stationaryStartedMs = sample.timestampMs
                        preImpactEvidence = samples.toList()
                    } else if (sample.timestampMs - freefallEnd > IMPACT_WINDOW_MS) {
                        clearIncident()
                    }
                }
            }
            return null
        }

        val stationary = kotlin.math.abs(accelerationG - 1f) <= STATIONARY_ACCELERATION_DELTA_G &&
            rotation <= STATIONARY_ROTATION_RAD_S
        if (!stationary) stationaryStartedMs = sample.timestampMs
        val stationarySince = stationaryStartedMs ?: sample.timestampMs.also { stationaryStartedMs = it }
        if (sample.timestampMs - stationarySince < immobilityDurationMs) {
            return null
        }

        val evidence = preImpactEvidence
        val startAltitude = evidence.firstNotNullOfOrNull { it.altitudeMeters }
        val impactAltitude = evidence.asReversed().firstNotNullOfOrNull { it.altitudeMeters }
        val detected = DetectedFall(
            impactTimestampMs = currentImpact.timestampMs,
            fallVector = FallVector(
                impactGForce = magnitude(
                    currentImpact.accelerationX,
                    currentImpact.accelerationY,
                    currentImpact.accelerationZ,
                ) / STANDARD_GRAVITY,
                freefallDurationSeconds = freefallDurationMs / 1_000f,
                deltaAltitudeMeters = if (startAltitude != null && impactAltitude != null) {
                    impactAltitude - startAltitude
                } else {
                    0f
                },
            ),
            preImpactSamples = evidence,
        )
        clearIncident()
        return detected
    }

    fun reset() {
        samples.clear()
        clearIncident()
    }

    private fun clearIncident() {
        freefallStartedMs = null
        freefallEndedMs = null
        impact = null
        freefallDurationMs = 0
        stationaryStartedMs = null
        preImpactEvidence = emptyList()
    }

    private fun magnitude(x: Float, y: Float, z: Float) = sqrt(x * x + y * y + z * z)

    companion object {
        private const val STANDARD_GRAVITY = 9.80665f
        private const val FREEFALL_G = 0.2f
        private const val IMPACT_G = 4.5f
        private const val IMPACT_WINDOW_MS = 500L
        private const val STATIONARY_ACCELERATION_DELTA_G = 0.15f
        private const val STATIONARY_ROTATION_RAD_S = 0.15f
    }
}

enum class InjuryType(val code: Int) { NONE(0), LEG(1), ARM(2), HEAD(3), TORSO(4), MULTIPLE(5), OTHER(6) }
enum class Mobility(val code: Int) { MOBILE(0), LIMITED(1), STATIONARY(2), UNCONSCIOUS(3) }
enum class Bleeding(val code: Int) { NONE(0), CONTROLLED(1), UNCONTROLLED(2), UNKNOWN(3) }

object TriageCode {
    fun encode(injury: InjuryType, mobility: Mobility, bleeding: Bleeding): Int =
        (injury.code and 0x7) or ((mobility.code and 0x3) shl 3) or ((bleeding.code and 0x3) shl 5)

    fun decode(code: Int): Triple<InjuryType, Mobility, Bleeding> {
        require(code in 0..255) { "triage code must fit in one byte" }
        return Triple(
            InjuryType.entries.firstOrNull { it.code == code and 0x7 } ?: InjuryType.OTHER,
            Mobility.entries.firstOrNull { it.code == (code ushr 3) and 0x3 } ?: Mobility.UNCONSCIOUS,
            Bleeding.entries.firstOrNull { it.code == (code ushr 5) and 0x3 } ?: Bleeding.UNKNOWN,
        )
    }
}
