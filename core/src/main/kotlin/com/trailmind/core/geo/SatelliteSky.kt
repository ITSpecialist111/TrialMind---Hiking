package com.trailmind.core.geo

import kotlin.math.cos
import kotlin.math.sin

object SatelliteSky {
    data class Point(val x: Double, val y: Double)
    /** North-up sky plot, horizon radius 1, zenith at the origin. */
    fun project(azimuth: Double, elevation: Double): Point? {
        if (!azimuth.isFinite() || !elevation.isFinite() || elevation !in 0.0..90.0) return null
        val radius = 1.0 - elevation / 90.0
        val angle = Math.toRadians(azimuth)
        return Point(radius * sin(angle), -radius * cos(angle))
    }
}
