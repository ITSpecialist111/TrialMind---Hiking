package com.trailmind.core.geo

/** WGS84 coordinate in decimal degrees. */
data class LatLon(val lat: Double, val lon: Double) {
    val isValid: Boolean
        get() = lat in -90.0..90.0 && lon in -180.0..180.0 && !lat.isNaN() && !lon.isNaN()
}

/** A recorded or imported point. Elevation in metres above sea level, time in epoch millis. */
data class TrackPoint(
    val lat: Double,
    val lon: Double,
    val ele: Double? = null,
    val timeMs: Long? = null,
    val accuracyM: Float? = null,
) {
    fun latLon(): LatLon = LatLon(lat, lon)
}

data class Waypoint(
    val lat: Double,
    val lon: Double,
    val name: String,
    val ele: Double? = null,
    val description: String? = null,
) {
    fun latLon(): LatLon = LatLon(lat, lon)
}

data class BoundingBox(val minLat: Double, val minLon: Double, val maxLat: Double, val maxLon: Double) {
    val center: LatLon get() = LatLon((minLat + maxLat) / 2.0, (minLon + maxLon) / 2.0)

    operator fun contains(p: LatLon): Boolean = p.lat in minLat..maxLat && p.lon in minLon..maxLon

    fun expandedByMetres(metres: Double): BoundingBox {
        val dLat = Math.toDegrees(metres / Geo.EARTH_RADIUS_M)
        val cosLat = kotlin.math.cos(Math.toRadians(center.lat)).coerceAtLeast(0.01)
        val dLon = dLat / cosLat
        return BoundingBox(
            (minLat - dLat).coerceAtLeast(-85.0), (minLon - dLon).coerceAtLeast(-180.0),
            (maxLat + dLat).coerceAtMost(85.0), (maxLon + dLon).coerceAtMost(180.0),
        )
    }

    companion object {
        fun of(points: Iterable<LatLon>): BoundingBox? {
            var minLat = Double.POSITIVE_INFINITY
            var minLon = Double.POSITIVE_INFINITY
            var maxLat = Double.NEGATIVE_INFINITY
            var maxLon = Double.NEGATIVE_INFINITY
            var any = false
            for (p in points) {
                any = true
                if (p.lat < minLat) minLat = p.lat
                if (p.lat > maxLat) maxLat = p.lat
                if (p.lon < minLon) minLon = p.lon
                if (p.lon > maxLon) maxLon = p.lon
            }
            return if (any) BoundingBox(minLat, minLon, maxLat, maxLon) else null
        }
    }
}
