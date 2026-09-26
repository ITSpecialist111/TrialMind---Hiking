package com.trailmind.core.nav

import com.trailmind.core.geo.LatLon

/** Whole-kilometre or whole-mile marks along a route, thinned so their labels stay readable at any scale. */
object DistanceMarks {
    private val NICE = intArrayOf(1, 2, 5, 10, 20, 50, 100, 200, 500)

    fun stepM(imperial: Boolean) = if (imperial) 1609.344 else 1000.0

    /** Positions [stepM] apart along [guide]; element i is (i + 1) steps from the start. */
    fun along(guide: RouteGuide, stepM: Double): List<LatLon> =
        (1..(guide.totalM / stepM).toInt()).map { guide.pointAt(it * stepM) }

    /** Draw every n-th mark, the smallest nice n that puts marks [stepPx] apart at least [minPx] apart. */
    fun every(stepPx: Double, minPx: Double): Int = NICE.firstOrNull { it * stepPx >= minPx } ?: NICE.last()
}
