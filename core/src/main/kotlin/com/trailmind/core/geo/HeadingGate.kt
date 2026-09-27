package com.trailmind.core.geo

import kotlin.math.abs

class HeadingGate {
    private var headingDeg: Double? = null
    private var acceptedAtMs = 0L
    private var pendingDeg: Double? = null

    fun accept(degrees: Double, elapsedMs: Long): Boolean {
        if (!degrees.isFinite()) return false
        val previous = headingDeg
        if (previous != null && abs(Geo.angleDiffDeg(previous, degrees)) < 1.0) {
            pendingDeg = null
            return false
        }
        if (previous != null && elapsedMs - acceptedAtMs < 67L) {
            pendingDeg = degrees
            return false
        }
        headingDeg = Geo.normalizeDeg(degrees)
        acceptedAtMs = elapsedMs
        pendingDeg = null
        return true
    }

    fun pendingDelayMs(elapsedMs: Long): Long? = pendingDeg?.let { (67L - (elapsedMs - acceptedAtMs)).coerceAtLeast(0L) }

    fun flush(elapsedMs: Long): Double? {
        val pending = pendingDeg ?: return null
        return if (accept(pending, elapsedMs)) headingDeg else null
    }

    fun reset() {
        headingDeg = null
        pendingDeg = null
        acceptedAtMs = 0L
    }
}