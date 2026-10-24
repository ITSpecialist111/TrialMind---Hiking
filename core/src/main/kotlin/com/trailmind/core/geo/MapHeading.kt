package com.trailmind.core.geo

/** True-north heading selection; timestamps must all use the same monotonic clock. */
object MapHeading {
    enum class Source { COURSE, COMPASS, UNAVAILABLE }
    data class Reading(val degrees: Double, val atMs: Long)
    data class Course(val reading: Reading, val speedMps: Double, val accuracyM: Double,
                      val bearingAccuracyDeg: Double?, val speedAccuracyMps: Double?)
    data class Result(val degrees: Double?, val source: Source)

    fun choose(nowMs: Long, compass: Reading?, compassReliable: Boolean, course: Course?): Result {
        val moving = course?.takeIf {
            fresh(it.reading, nowMs, 5_000) &&
                it.accuracyM.isFinite() && it.accuracyM in 0.0..25.0 &&
                it.speedMps.isFinite() && it.speedMps >= if (it.bearingAccuracyDeg == null) 1.2 else 0.8
        }?.takeIf {
            (it.bearingAccuracyDeg == null || it.bearingAccuracyDeg.isFinite() && it.bearingAccuracyDeg in 0.0..25.0) &&
                (it.speedAccuracyMps == null || it.speedAccuracyMps.isFinite() && it.speedAccuracyMps >= 0 &&
                    it.speedMps - it.speedAccuracyMps >= 0.5)
        }
        if (moving != null) return Result(Geo.normalizeDeg(moving.reading.degrees), Source.COURSE)
        if (compassReliable && compass != null && fresh(compass, nowMs, 2_000)) {
            return Result(Geo.normalizeDeg(compass.degrees), Source.COMPASS)
        }
        return Result(null, Source.UNAVAILABLE)
    }

    private fun fresh(reading: Reading, now: Long, age: Long) =
        reading.degrees.isFinite() && now - reading.atMs in 0..age
}
