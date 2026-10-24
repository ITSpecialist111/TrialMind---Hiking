package com.trailmind.core.geo

import kotlin.math.abs

object MenuMotion {
    fun shouldDrag(dx: Float, dy: Float, slop: Float, fraction: Float): Boolean =
        abs(dx) > slop && abs(dx) > abs(dy) * 1.5f &&
            (fraction > 0f || dx > 0f) && (fraction < 1f || dx < 0f)

    fun fraction(start: Float, distance: Float, width: Float): Float {
        require(width > 0f)
        return (start + distance / width).coerceIn(0f, 1f)
    }

    fun settleOpen(fraction: Float, velocity: Float, flingThreshold: Float): Boolean =
        if (abs(velocity) >= flingThreshold) velocity > 0f else fraction >= 0.5f
}
