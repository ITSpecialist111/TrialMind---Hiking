package com.trailmind.core.geo

import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.acos
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin

data class SunTimes(val sunriseMs: Long?, val sunsetMs: Long?, val polarDay: Boolean, val polarNight: Boolean)

/** NOAA-style sunrise/sunset (±2 min), used to warn when a hike may finish after dark. */
object Sun {
    fun times(date: LocalDate, at: LatLon): SunTimes {
        val jd = date.toEpochDay() + 2440587.5 + 0.5 // Julian day at noon UTC
        val n = jd - 2451545.0 + 0.0008
        val jStar = n - at.lon / 360.0
        val m = Geo.normalizeDeg(357.5291 + 0.98560028 * jStar)
        val mr = Math.toRadians(m)
        val c = 1.9148 * sin(mr) + 0.0200 * sin(2 * mr) + 0.0003 * sin(3 * mr)
        val lambda = Math.toRadians(Geo.normalizeDeg(m + c + 180 + 102.9372))
        val jTransit = 2451545.0 + jStar + 0.0053 * sin(mr) - 0.0069 * sin(2 * lambda)
        val decl = asin(sin(lambda) * sin(Math.toRadians(23.4397)))
        val phi = Math.toRadians(at.lat)
        val cosH = (sin(Math.toRadians(-0.833)) - sin(phi) * sin(decl)) / (cos(phi) * cos(decl))
        if (cosH > 1) return SunTimes(null, null, polarDay = false, polarNight = true)
        if (cosH < -1) return SunTimes(null, null, polarDay = true, polarNight = false)
        val h = Math.toDegrees(acos(cosH))
        val rise = jTransit - h / 360.0
        val set = jTransit + h / 360.0
        return SunTimes(julianToMs(rise), julianToMs(set), polarDay = false, polarNight = false)
    }

    private fun julianToMs(jd: Double): Long = ((jd - 2440587.5) * 86_400_000.0).toLong()

    fun today(at: LatLon): SunTimes = times(LocalDate.now(ZoneOffset.UTC), at)
}
