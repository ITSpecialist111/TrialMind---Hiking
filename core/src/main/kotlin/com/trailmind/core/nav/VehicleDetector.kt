package com.trailmind.core.nav

import com.trailmind.core.geo.Geo

/**
 * Notices that someone recording a hike has got into a vehicle, usually because they forgot to pause or stop at
 * the car park. Feed it every GPS fix, including the ones the breadcrumb filter rejects.
 *
 * A fix is "fast" when its speed is above [fastMps], which is beyond a sustained run, let alone a walk. Speed is
 * the receiver's own Doppler speed where it has one, else worked out from the previous fix. The verdict is
 * [Verdict.MAYBE] while a fast run is under way and [Verdict.VEHICLE] once it has lasted [sustainMs] and covered at
 * least [minDistanceM]: a few seconds of downhill running, a bike lent for a minute or a GPS glitch never gets
 * that far. Short dips below the threshold (a junction, a queue) don't end a run; a stop of more than [dipMs] does.
 *
 * While the verdict is [Verdict.MAYBE] the caller should hold back the fixes it would record, then write them if the
 * run ends ([Verdict.ON_FOOT]) or drop them on [Verdict.VEHICLE], so the drive never reaches the saved track.
 */
class VehicleDetector(
    private val fastMps: Double = 6.0,
    private val sustainMs: Long = 30_000,
    private val minDistanceM: Double = 120.0,
    private val dipMs: Long = 10_000,
    private val maxAccuracyM: Float = 40f,
    private val maxGapMs: Long = 30_000,
) {
    enum class Verdict { ON_FOOT, MAYBE, VEHICLE }

    private class Sample(val timeMs: Long, val lat: Double, val lon: Double)

    private var prev: Sample? = null
    private var runStart: Sample? = null
    private var lastFastMs = 0L
    private var confirmed = false

    /** When the current fast run began, on the clock of the fixes fed in, or null when there isn't one. */
    val runStartedMs: Long? get() = runStart?.timeMs

    fun reset() {
        prev = null
        runStart = null
        confirmed = false
    }

    /**
     * Takes one fix: [timeMs] on any steady clock (elapsed real time is ideal), its position, its [accuracyM] and
     * [speedMps] if the receiver gave them.
     */
    fun onFix(timeMs: Long, lat: Double, lon: Double, accuracyM: Float?, speedMps: Double?): Verdict {
        if (confirmed) return Verdict.VEHICLE
        if (accuracyM != null && accuracyM > maxAccuracyM) return current()
        val before = prev
        prev = Sample(timeMs, lat, lon)
        // With no fix for a while (a tunnel, GPS off) there is no telling what happened, so a run can't carry across.
        if (before != null && timeMs - before.timeMs > maxGapMs) runStart = null
        val speed = speedMps?.takeIf { it.isFinite() && it >= 0.0 } ?: derivedSpeed(before, timeMs, lat, lon) ?: return current()

        if (speed >= fastMps) {
            lastFastMs = timeMs
            val start = runStart ?: Sample(timeMs, lat, lon).also { runStart = it }
            if (timeMs - start.timeMs >= sustainMs && Geo.distanceM(start.lat, start.lon, lat, lon) >= minDistanceM) {
                confirmed = true
                return Verdict.VEHICLE
            }
            return Verdict.MAYBE
        }
        if (runStart != null && timeMs - lastFastMs > dipMs) runStart = null
        return current()
    }

    private fun current() = if (runStart != null) Verdict.MAYBE else Verdict.ON_FOOT

    private fun derivedSpeed(before: Sample?, timeMs: Long, lat: Double, lon: Double): Double? {
        before ?: return null
        val dt = timeMs - before.timeMs
        if (dt < MIN_DERIVE_MS || dt > maxGapMs) return null
        return Geo.distanceM(before.lat, before.lon, lat, lon) / (dt / 1000.0)
    }

    private companion object {
        const val MIN_DERIVE_MS = 500L
    }
}
