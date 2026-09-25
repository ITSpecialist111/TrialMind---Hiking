package com.trailmind.core.nav

import com.trailmind.core.geo.TrackPoint
import kotlin.math.ceil

/** "Retrace my steps": the recorded breadcrumb reversed, so route guidance leads back to where the hike began. */
object TracBack {
    const val ROUTE_NAME = "Retrace steps"
    const val START_NAME = "Start of hike"

    /** The recorded points reversed and thinned to at most [maxPoints], or null if there is nothing to retrace. */
    fun line(recorded: List<TrackPoint>, maxPoints: Int = 3000): List<TrackPoint>? {
        if (recorded.size < 2) return null
        val step = ceil(recorded.size / maxPoints.toDouble()).toInt().coerceAtLeast(1)
        val kept = recorded.filterIndexed { i, _ -> i % step == 0 || i == recorded.lastIndex }
        return kept.asReversed().map { TrackPoint(it.lat, it.lon, it.ele) }
    }
}
