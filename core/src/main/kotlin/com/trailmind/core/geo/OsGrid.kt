package com.trailmind.core.geo

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

data class OsGridRef(val easting: Double, val northing: Double) {
    /** e.g. "NN 16667 71283" (10-figure, 1 m) or fewer digits for [digits] = 6 or 8. */
    fun format(digits: Int = 10): String? {
        val letters = OsGrid.letters(easting, northing) ?: return null
        val per = (digits / 2).coerceIn(1, 5)
        val div = 10.0.pow(5 - per)
        val e = floor((easting % 100_000) / div).toInt()
        val n = floor((northing % 100_000) / div).toInt()
        return "$letters ${e.toString().padStart(per, '0')} ${n.toString().padStart(per, '0')}"
    }
}

/**
 * WGS84 ↔ OSGB36 British National Grid. Uses the OS 7-parameter Helmert transform, which is
 * accurate to roughly ±5 m: good enough to read a grid reference to Mountain Rescue, not survey.
 */
object OsGrid {
    private const val WGS84_A = 6_378_137.0
    private const val WGS84_B = 6_356_752.314245
    private const val AIRY_A = 6_377_563.396
    private const val AIRY_B = 6_356_256.909
    private const val F0 = 0.9996012717
    private val LAT0 = Math.toRadians(49.0)
    private val LON0 = Math.toRadians(-2.0)
    private const val N0 = -100_000.0
    private const val E0 = 400_000.0

    fun fromWgs84(p: LatLon): OsGridRef? {
        if (p.lat < 49.0 || p.lat > 61.5 || p.lon < -9.5 || p.lon > 2.5) return null
        val osgb = wgs84ToOsgb36(p)
        val ref = projectOsgb36(osgb)
        return if (ref.easting in 0.0..700_000.0 && ref.northing in 0.0..1_300_000.0) ref else null
    }

    /** Like [fromWgs84] but without the Great Britain range check, for map geometry near the edges. */
    fun project(p: LatLon): OsGridRef = projectOsgb36(wgs84ToOsgb36(p))

    /** A grid position back to WGS84: the inverse of [project], with the same Helmert accuracy. */
    fun toWgs84(easting: Double, northing: Double): LatLon = osgb36ToWgs84(unprojectOsgb36(easting, northing))

    fun wgs84ToOsgb36(p: LatLon): LatLon {
        val (x1, y1, z1) = toCartesian(p, WGS84_A, WGS84_B)
        val tx = -446.448
        val ty = 125.157
        val tz = -542.060
        val s = 20.4894e-6
        val rx = Math.toRadians(-0.1502 / 3600.0)
        val ry = Math.toRadians(-0.2470 / 3600.0)
        val rz = Math.toRadians(-0.8421 / 3600.0)
        val s1 = s + 1.0
        val x2 = tx + x1 * s1 - y1 * rz + z1 * ry
        val y2 = ty + x1 * rz + y1 * s1 - z1 * rx
        val z2 = tz - x1 * ry + y1 * rx + z1 * s1
        return fromCartesian(x2, y2, z2, AIRY_A, AIRY_B)
    }

    fun osgb36ToWgs84(p: LatLon): LatLon {
        val (x1, y1, z1) = toCartesian(p, AIRY_A, AIRY_B)
        // The forward parameters negated: the inverse to far better than the transform's own accuracy.
        val tx = 446.448
        val ty = -125.157
        val tz = 542.060
        val s = -20.4894e-6
        val rx = Math.toRadians(0.1502 / 3600.0)
        val ry = Math.toRadians(0.2470 / 3600.0)
        val rz = Math.toRadians(0.8421 / 3600.0)
        val s1 = s + 1.0
        val x2 = tx + x1 * s1 - y1 * rz + z1 * ry
        val y2 = ty + x1 * rz + y1 * s1 - z1 * rx
        val z2 = tz - x1 * ry + y1 * rx + z1 * s1
        return fromCartesian(x2, y2, z2, WGS84_A, WGS84_B)
    }

    /** Meridional arc from the true origin to [phi] (radians), scaled by F0. */
    private fun meridionalArc(phi: Double): Double {
        val n = (AIRY_A - AIRY_B) / (AIRY_A + AIRY_B)
        val n2 = n * n
        val n3 = n2 * n
        val dPhi = phi - LAT0
        val sPhi = phi + LAT0
        val ma = (1 + n + 1.25 * n2 + 1.25 * n3) * dPhi
        val mb = (3 * n + 3 * n2 + 21.0 / 8 * n3) * sin(dPhi) * cos(sPhi)
        val mc = (15.0 / 8 * n2 + 15.0 / 8 * n3) * sin(2 * dPhi) * cos(2 * sPhi)
        val md = 35.0 / 24 * n3 * sin(3 * dPhi) * cos(3 * sPhi)
        return AIRY_B * F0 * (ma - mb + mc - md)
    }

    /** Transverse Mercator projection of an OSGB36 (Airy 1830) latitude/longitude. */
    fun projectOsgb36(p: LatLon): OsGridRef {
        val a = AIRY_A
        val b = AIRY_B
        val phi = Math.toRadians(p.lat)
        val lambda = Math.toRadians(p.lon)
        val e2 = 1 - (b * b) / (a * a)
        val sinPhi = sin(phi)
        val cosPhi = cos(phi)
        val nu = a * F0 / sqrt(1 - e2 * sinPhi * sinPhi)
        val rho = a * F0 * (1 - e2) / (1 - e2 * sinPhi * sinPhi).pow(1.5)
        val eta2 = nu / rho - 1
        val m = meridionalArc(phi)
        val cos3 = cosPhi * cosPhi * cosPhi
        val cos5 = cos3 * cosPhi * cosPhi
        val tan2 = tan(phi) * tan(phi)
        val tan4 = tan2 * tan2
        val i = m + N0
        val ii = nu / 2 * sinPhi * cosPhi
        val iii = nu / 24 * sinPhi * cos3 * (5 - tan2 + 9 * eta2)
        val iiia = nu / 720 * sinPhi * cos5 * (61 - 58 * tan2 + tan4)
        val iv = nu * cosPhi
        val v = nu / 6 * cos3 * (nu / rho - tan2)
        val vi = nu / 120 * cos5 * (5 - 18 * tan2 + tan4 + 14 * eta2 - 58 * tan2 * eta2)
        val dl = lambda - LON0
        val dl2 = dl * dl
        val northing = i + ii * dl2 + iii * dl2 * dl2 + iiia * dl2 * dl2 * dl2
        val easting = E0 + iv * dl + v * dl2 * dl + vi * dl2 * dl2 * dl
        return OsGridRef(easting, northing)
    }

    /** Inverse Transverse Mercator: the OSGB36 (Airy 1830) latitude/longitude of a grid position. */
    fun unprojectOsgb36(easting: Double, northing: Double): LatLon {
        val a = AIRY_A
        val b = AIRY_B
        val e2 = 1 - (b * b) / (a * a)
        var phi = LAT0
        var m = 0.0
        do {
            phi += (northing - N0 - m) / (a * F0)
            m = meridionalArc(phi)
        } while (abs(northing - N0 - m) >= 0.00001)
        val sinPhi = sin(phi)
        val nu = a * F0 / sqrt(1 - e2 * sinPhi * sinPhi)
        val rho = a * F0 * (1 - e2) / (1 - e2 * sinPhi * sinPhi).pow(1.5)
        val eta2 = nu / rho - 1
        val tanPhi = tan(phi)
        val tan2 = tanPhi * tanPhi
        val tan4 = tan2 * tan2
        val tan6 = tan4 * tan2
        val sec = 1 / cos(phi)
        val nu3 = nu * nu * nu
        val nu5 = nu3 * nu * nu
        val nu7 = nu5 * nu * nu
        val vii = tanPhi / (2 * rho * nu)
        val viii = tanPhi / (24 * rho * nu3) * (5 + 3 * tan2 + eta2 - 9 * tan2 * eta2)
        val ix = tanPhi / (720 * rho * nu5) * (61 + 90 * tan2 + 45 * tan4)
        val x = sec / nu
        val xi = sec / (6 * nu3) * (nu / rho + 2 * tan2)
        val xii = sec / (120 * nu5) * (5 + 28 * tan2 + 24 * tan4)
        val xiia = sec / (5040 * nu7) * (61 + 662 * tan2 + 1320 * tan4 + 720 * tan6)
        val de = easting - E0
        val de2 = de * de
        val lat = phi - vii * de2 + viii * de2 * de2 - ix * de2 * de2 * de2
        val lon = LON0 + x * de - xi * de2 * de + xii * de2 * de2 * de - xiia * de2 * de2 * de2 * de
        return LatLon(Math.toDegrees(lat), Math.toDegrees(lon))
    }

    /** Two-letter 100 km square for an easting/northing, or null outside the grid. */
    fun letters(easting: Double, northing: Double): String? {
        val e100k = floor(easting / 100_000).toInt()
        val n100k = floor(northing / 100_000).toInt()
        if (e100k < 0 || e100k > 6 || n100k < 0 || n100k > 12) return null
        var l1 = (19 - n100k) - (19 - n100k) % 5 + (e100k + 10) / 5
        var l2 = (19 - n100k) * 5 % 25 + e100k % 5
        if (l1 > 7) l1++
        if (l2 > 7) l2++
        return "${'A' + l1}${'A' + l2}"
    }

    private fun toCartesian(p: LatLon, a: Double, b: Double): Triple<Double, Double, Double> {
        val phi = Math.toRadians(p.lat)
        val lambda = Math.toRadians(p.lon)
        val e2 = 1 - (b * b) / (a * a)
        val nu = a / sqrt(1 - e2 * sin(phi) * sin(phi))
        val x = nu * cos(phi) * cos(lambda)
        val y = nu * cos(phi) * sin(lambda)
        val z = (1 - e2) * nu * sin(phi)
        return Triple(x, y, z)
    }

    private fun fromCartesian(x: Double, y: Double, z: Double, a: Double, b: Double): LatLon {
        val e2 = 1 - (b * b) / (a * a)
        val pp = sqrt(x * x + y * y)
        var phi = atan2(z, pp * (1 - e2))
        repeat(10) {
            val nu = a / sqrt(1 - e2 * sin(phi) * sin(phi))
            val next = atan2(z + e2 * nu * sin(phi), pp)
            if (abs(next - phi) < 1e-12) {
                phi = next
                return LatLon(Math.toDegrees(phi), Math.toDegrees(atan2(y, x)))
            }
            phi = next
        }
        return LatLon(Math.toDegrees(phi), Math.toDegrees(atan2(y, x)))
    }
}
