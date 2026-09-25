package com.trailmind.core.gpx

import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Waypoint

data class GpxTrack(val name: String?, val segments: List<List<TrackPoint>>)

data class GpxRoute(val name: String?, val points: List<TrackPoint>)

data class GpxDocument(
    val name: String?,
    val tracks: List<GpxTrack>,
    val routes: List<GpxRoute>,
    val waypoints: List<Waypoint>,
) {
    val isEmpty: Boolean
        get() = tracks.all { t -> t.segments.all { it.isEmpty() } } && routes.all { it.points.isEmpty() } && waypoints.isEmpty()

    /** Best display name: metadata, then first track/route name. */
    fun bestName(): String? =
        name?.takeIf { it.isNotBlank() }
            ?: tracks.firstOrNull { !it.name.isNullOrBlank() }?.name
            ?: routes.firstOrNull { !it.name.isNullOrBlank() }?.name

    /**
     * The line to follow: planned routes (`rte`) win over tracks (`trk`) because they are the
     * intended path; tracks are concatenated in order.
     */
    fun primaryLine(): List<TrackPoint> {
        val route = routes.maxByOrNull { it.points.size }
        if (route != null && route.points.size >= 2) return route.points
        return tracks.flatMap { t -> t.segments.flatten() }
    }
}

class GpxParseException(message: String, cause: Throwable? = null) : Exception(message, cause)
