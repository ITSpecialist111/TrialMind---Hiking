package com.trailmind.core.geo

import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Spherical-earth helpers. Accurate to well under 0.5% for hiking distances. */
object Geo {
    const val EARTH_RADIUS_M = 6_371_008.8

    fun distanceM(a: LatLon, b: LatLon): Double = distanceM(a.lat, a.lon, b.lat, b.lon)

    fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val p1 = Math.toRadians(lat1)
        val p2 = Math.toRadians(lat2)
        val dp = p2 - p1
        val dl = Math.toRadians(lon2 - lon1)
        val h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * EARTH_RADIUS_M * asin(sqrt(h.coerceIn(0.0, 1.0)))
    }

    /** Initial great-circle bearing from [a] to [b], degrees clockwise from true north in [0, 360). */
    fun bearingDeg(a: LatLon, b: LatLon): Double {
        val p1 = Math.toRadians(a.lat)
        val p2 = Math.toRadians(b.lat)
        val dl = Math.toRadians(b.lon - a.lon)
        val y = sin(dl) * cos(p2)
        val x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return normalizeDeg(Math.toDegrees(atan2(y, x)))
    }

    fun destination(from: LatLon, bearingDeg: Double, distanceM: Double): LatLon {
        val d = distanceM / EARTH_RADIUS_M
        val br = Math.toRadians(bearingDeg)
        val p1 = Math.toRadians(from.lat)
        val l1 = Math.toRadians(from.lon)
        val p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(br))
        val l2 = l1 + atan2(sin(br) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        return LatLon(Math.toDegrees(p2), normalizeLon(Math.toDegrees(l2)))
    }

    fun normalizeDeg(deg: Double): Double {
        val r = deg % 360.0
        return if (r < 0) r + 360.0 else r
    }

    fun normalizeLon(lon: Double): Double {
        var l = (lon + 180.0) % 360.0
        if (l < 0) l += 360.0
        return l - 180.0
    }

    /** Signed smallest difference target - current in (-180, 180]. */
    fun angleDiffDeg(current: Double, target: Double): Double {
        var d = normalizeDeg(target - current)
        if (d > 180.0) d -= 360.0
        return d
    }

    private val CARDINALS = arrayOf(
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
    )

    fun cardinal(bearingDeg: Double): String =
        CARDINALS[((normalizeDeg(bearingDeg) + 11.25) / 22.5).toInt() % 16]

    /**
     * Projects [p] onto segment [a]-[b] using a local equirectangular approximation (fine for
     * segments shorter than a few km). Returns the clamped fraction along the segment and the
     * distance in metres from [p] to the closest point.
     */
    fun projectOntoSegment(p: LatLon, a: LatLon, b: LatLon): SegmentProjection {
        val cosLat = cos(Math.toRadians((a.lat + b.lat) / 2.0))
        val ax = 0.0
        val ay = 0.0
        val bx = Math.toRadians(b.lon - a.lon) * cosLat * EARTH_RADIUS_M
        val by = Math.toRadians(b.lat - a.lat) * EARTH_RADIUS_M
        val px = Math.toRadians(p.lon - a.lon) * cosLat * EARTH_RADIUS_M
        val py = Math.toRadians(p.lat - a.lat) * EARTH_RADIUS_M
        val dx = bx - ax
        val dy = by - ay
        val len2 = dx * dx + dy * dy
        val t = if (len2 <= 1e-9) 0.0 else (((px - ax) * dx + (py - ay) * dy) / len2).coerceIn(0.0, 1.0)
        val cx = ax + t * dx
        val cy = ay + t * dy
        val dist = sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
        val closest = LatLon(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t)
        return SegmentProjection(t, dist, closest)
    }

    /** Cumulative distance along [points]; element i is the distance from point 0 to point i. */
    fun cumulativeDistances(points: List<TrackPoint>): DoubleArray {
        val out = DoubleArray(points.size)
        for (i in 1 until points.size) {
            val a = points[i - 1]
            val b = points[i]
            out[i] = out[i - 1] + distanceM(a.lat, a.lon, b.lat, b.lon)
        }
        return out
    }
}

data class SegmentProjection(val fraction: Double, val distanceM: Double, val closest: LatLon)
