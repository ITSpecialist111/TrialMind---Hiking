package com.trailmind.core.geo

import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.acos
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan

data class SunTimes(val sunriseMs: Long?, val sunsetMs: Long?, val polarDay: Boolean, val polarNight: Boolean, val civilDuskMs: Long? = null)

/** Solar transit and -0.833 degree apparent sunrise/sunset, with -6 degree civil dusk. */
object Sun {
    fun times(date: LocalDate, at: LatLon): SunTimes {
        val midnight = date.toEpochDay() * 86_400_000L
        val julian = date.toEpochDay() + 2440587.5
        val phi = Math.toRadians(at.lat)
        fun solar(jd: Double): Pair<Double, Double> {
            val t = (jd - 2451545.0) / 36525.0
            val meanLong = Math.toRadians(Geo.normalizeDeg(280.46646 + t * (36000.76983 + 0.0003032 * t)))
            val anomaly = Math.toRadians(Geo.normalizeDeg(357.52911 + t * (35999.05029 - 0.0001537 * t)))
            val eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
            val center = sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
                sin(2 * anomaly) * (0.019993 - 0.000101 * t) + sin(3 * anomaly) * 0.000289
            val omega = Math.toRadians(125.04 - 1934.136 * t)
            val longitude = meanLong + Math.toRadians(center - 0.00569 - 0.00478 * sin(omega))
            val obliquity = Math.toRadians(23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60 + 0.00256 * cos(omega))
            val declination = asin(sin(obliquity) * sin(longitude))
            val y = tan(obliquity / 2).let { it * it }
            val equation = 4 * Math.toDegrees(y * sin(2 * meanLong) - 2 * eccentricity * sin(anomaly) +
                4 * eccentricity * y * sin(anomaly) * cos(2 * meanLong) - y * y * sin(4 * meanLong) / 2 -
                1.25 * eccentricity * eccentricity * sin(2 * anomaly))
            return equation to declination
        }
        fun crossing(altitude: Double, setting: Boolean): Long? {
            var minutes = 720.0 - 4 * at.lon
            repeat(3) {
                val (equation, declination) = solar(julian + minutes / 1440.0)
                val cosH = (sin(Math.toRadians(altitude)) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination))
                if (cosH !in -1.0..1.0) return null
                val hourAngle = Math.toDegrees(acos(cosH))
                minutes = 720 - 4 * at.lon - equation + (if (setting) 4 * hourAngle else -4 * hourAngle)
            }
            return midnight + (minutes * 60_000).toLong()
        }
        val rise = crossing(-0.833, false)
        val set = crossing(-0.833, true)
        if (rise == null || set == null) {
            val declination = solar(julian + 0.5).second
            val below = (sin(Math.toRadians(-0.833)) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination)) > 1
            return SunTimes(null, null, polarDay = !below, polarNight = below)
        }
        return SunTimes(rise, set, polarDay = false, polarNight = false, civilDuskMs = crossing(-6.0, true))
    }

    fun today(at: LatLon): SunTimes = times(LocalDate.now(ZoneId.systemDefault()), at)
}
