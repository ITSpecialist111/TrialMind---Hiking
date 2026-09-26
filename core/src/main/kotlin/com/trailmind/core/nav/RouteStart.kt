package com.trailmind.core.nav

class RouteStart {
    private var initialAlong: Double? = null
    var started: Boolean = false
        private set

    fun update(fix: RouteFix, recording: Boolean): Boolean {
        if (started || fix.offRouteM > 40.0) return started
        if (recording) started = true
        val initial = initialAlong
        if (initial == null) initialAlong = fix.alongM
        else if (fix.alongM >= 40.0 && fix.alongM - initial >= 40.0) started = true
        return started
    }
}