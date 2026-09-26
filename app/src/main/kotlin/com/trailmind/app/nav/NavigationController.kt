package com.trailmind.app.nav

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.data.RouteData
import com.trailmind.app.data.RouteMeta
import com.trailmind.app.location.Fix
import com.trailmind.app.location.TrackingState
import com.trailmind.app.map.MercatorLine
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Notifications
import com.trailmind.core.format.Units
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.Sun
import com.trailmind.core.geo.SunTimes
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Waypoint
import com.trailmind.core.nav.OffRouteDetector
import com.trailmind.core.nav.RouteFix
import com.trailmind.core.nav.RouteGuide
import com.trailmind.core.nav.RouteStart
import com.trailmind.core.nav.TracBack
import com.trailmind.core.stats.HikeEstimate
import com.trailmind.core.stats.HikeEstimator
import com.trailmind.core.stats.Daylight
import com.trailmind.core.stats.DaylightEstimate
import com.trailmind.core.stats.TrackStats
import java.time.Instant
import java.time.ZoneId
import java.util.concurrent.CopyOnWriteArraySet

/** A route loaded for display and guidance. */
class ActiveRoute(val data: RouteData, val guide: RouteGuide, val line: MercatorLine, val estimate: HikeEstimate)

/**
 * Guidance along an imported line plus an optional "go to" target. All methods run on the main thread.
 * This does not create routes: it measures where you are relative to a line you imported.
 */
class NavigationController(private val app: TrailMindApp) {
    var active: ActiveRoute? = null; private set
    var fix: RouteFix? = null; private set
    var target: LatLon? = null; private set
    var lastFix: Fix? = null; private set
    var offRoute = false; private set
    /** Estimated minutes remaining (planning pace) from the snapped position to the end. */
    var remainingMinutes: Double? = null; private set
    var daylight: DaylightEstimate? = null; private set
    var daylightSun: SunTimes? = null; private set
    var routeStarted = false; private set

    private var detector = OffRouteDetector(app.prefs.offRouteThresholdM.toDouble())
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private var lastEstimateSeg = -1
    private var lastDaylightMs = 0L
    private var alertWalkKey: Long? = null
    private var sunsetAlerted = false
    private var duskAlerted = false
    private var start = RouteStart()

    fun addListener(l: () -> Unit) = listeners.add(l)
    fun removeListener(l: () -> Unit) = listeners.remove(l)
    private fun changed() = listeners.forEach { it() }

    init {
        val id = app.prefs.activeRouteId
        if (id > 0) follow(id, persist = false)
    }

    fun follow(routeId: Long, persist: Boolean = true, done: ((ActiveRoute?) -> Unit)? = null) {
        Async.run({ app.db.routeData(routeId)?.let { build(it) } }) { r ->
            val route = r.getOrNull()
            if (route == null) {
                if (app.prefs.activeRouteId == routeId) app.prefs.activeRouteId = -1
            } else {
                active = route
                if (persist) app.prefs.activeRouteId = routeId
                resetGuidance()
                lastFix?.let { onFix(it) }
            }
            changed()
            done?.invoke(route)
        }
    }

    fun stopFollowing() {
        val resume = app.prefs.activeRouteId.takeIf { active?.data?.meta?.id == TRACBACK_ID && it > 0 }
        active = null
        resetGuidance()
        if (TrackingState.status == TrackingState.Status.IDLE) { alertWalkKey = null; app.prefs.daylightAlertState = "" }
        Notifications.manager(app).cancel(Notifications.ID_OFF_ROUTE)
        changed()
        if (resume != null) follow(resume, persist = false) else app.prefs.activeRouteId = -1
    }

    /** Guides back along the recorded track to where the hike started. False if too little is recorded. */
    fun traceBack(): Boolean {
        val line = TracBack.line(TrackingState.points) ?: return false
        val start = line.last()
        val meta = RouteMeta(TRACBACK_ID, TracBack.ROUTE_NAME, System.currentTimeMillis(), 0.0, 0.0, 0.0, null, line.size, 1)
        val route = build(RouteData(meta, line, listOf(Waypoint(start.lat, start.lon, TracBack.START_NAME)))) ?: return false
        active = route
        resetGuidance()
        lastFix?.let { onFix(it) }
        changed()
        return true
    }

    /** Re-reads threshold / pace preferences. */
    fun settingsChanged() {
        detector = OffRouteDetector(app.prefs.offRouteThresholdM.toDouble())
        offRoute = false
        lastEstimateSeg = -1
        daylight = null
        daylightSun = null
        active?.let { a -> active = ActiveRoute(a.data, a.guide, a.line, HikeEstimator.estimate(a.data.points, app.prefs.pace)) }
        changed()
    }

    private fun resetGuidance() {
        fix = null
        offRoute = false
        remainingMinutes = null
        daylight = null
        daylightSun = null
        lastDaylightMs = 0L
        lastEstimateSeg = -1
        detector = OffRouteDetector(app.prefs.offRouteThresholdM.toDouble())
        start = RouteStart()
        routeStarted = false
        active?.guide?.reset()
    }

    private fun build(data: RouteData): ActiveRoute? {
        if (data.points.size < 2) return null
        val guide = runCatching { RouteGuide(data.points, data.waypoints) }.getOrNull() ?: return null
        val line = MercatorLine().apply { data.points.forEach { add(it.latLon()) } }
        return ActiveRoute(data, guide, line, HikeEstimator.estimate(data.points, app.prefs.pace))
    }

    fun setTarget(p: LatLon?) {
        target = p
        changed()
    }

    fun onFix(f: Fix) {
        lastFix = f
        val route = active
        if (route != null) {
            val rf = route.guide.locate(LatLon(f.lat, f.lon), f.location.time)
            fix = rf
            val wasStarted = routeStarted
            routeStarted = start.update(rf, TrackingState.status == TrackingState.Status.RECORDING)
            if (rf.segmentIndex != lastEstimateSeg || remainingMinutes == null) {
                lastEstimateSeg = rf.segmentIndex
                val rest = ArrayList<TrackPoint>()
                rest.add(TrackPoint(rf.snapped.lat, rf.snapped.lon, route.guide.points[rf.segmentIndex].ele))
                rest.addAll(route.guide.points.subList(rf.segmentIndex + 1, route.guide.points.size))
                remainingMinutes = if (rest.size >= 2) HikeEstimator.estimate(rest, app.prefs.pace).planningMinutes else 0.0
            }
            val now = System.currentTimeMillis()
            val offRouteDistance = rf.offRouteM - f.accuracyM.coerceIn(0f, app.prefs.offRouteThresholdM.toFloat())
            if (offRouteDistance > app.prefs.offRouteThresholdM) {
                daylight = null
                daylightSun = null
            } else if (daylight == null || now - lastDaylightMs >= 30_000 || routeStarted && !wasStarted) {
                lastDaylightMs = now
                val points = route.guide.points
                val snapped = TrackPoint(rf.snapped.lat, rf.snapped.lon,
                    points[rf.segmentIndex].ele?.let { elevation ->
                        val next = points[rf.segmentIndex + 1].ele ?: elevation
                        val distance = route.guide.cumulative[rf.segmentIndex + 1] - route.guide.cumulative[rf.segmentIndex]
                        elevation + (next - elevation) * ((rf.alongM - route.guide.cumulative[rf.segmentIndex]) / distance).coerceIn(0.0, 1.0)
                    })
                val walked = points.subList(0, rf.segmentIndex + 1) + snapped
                val remaining = listOf(snapped) + points.subList(rf.segmentIndex + 1, points.size)
                val date = Instant.ofEpochMilli(now).atZone(ZoneId.systemDefault()).toLocalDate()
                val sun = Sun.times(date, rf.snapped)
                daylightSun = sun
                val recorded = if (TrackingState.status != TrackingState.Status.IDLE) TrackStats.summarize(TrackingState.points) else null
                val movingMinutes = recorded?.takeIf { rf.alongM >= 500 && it.distanceM in rf.alongM * 0.6..rf.alongM * 1.4 }
                    ?.movingMs?.div(60_000.0)
                daylight = Daylight.estimate(now, remaining, walked,
                    movingMinutes,
                    app.prefs.pace, sun, app.prefs.daylightMarginMinutes)
                val walkKey = TrackingState.hikeId ?: -route.data.meta.id
                if (walkKey != alertWalkKey) {
                    alertWalkKey = walkKey
                    val saved = app.prefs.daylightAlertState.split(':')
                    val flags = if (saved.firstOrNull()?.toLongOrNull() == walkKey) saved.getOrNull(1)?.toIntOrNull() ?: 0 else 0
                    sunsetAlerted = flags and 1 != 0
                    duskAlerted = flags and 2 != 0
                }
                val forecast = daylight!!
                val cutoff = sun.sunsetMs?.minus(app.prefs.daylightMarginMinutes * 60_000L)
                val dusk = sun.civilDuskMs
                val duskDue = routeStarted && dusk != null && forecast.afterCivilDusk == true && forecast.finishMs > dusk + 2 * 60_000L
                val alert = Daylight.alertDue(routeStarted && cutoff != null && forecast.afterSafeSunset == true &&
                    forecast.finishMs > cutoff + 2 * 60_000L, duskDue, sunsetAlerted, duskAlerted)
                if (alert == 1) {
                    sunsetAlerted = true
                    if (duskDue) duskAlerted = true
                    val finishDate = Instant.ofEpochMilli(forecast.finishMs).atZone(ZoneId.systemDefault()).toLocalDate()
                    val finishLabel = when {
                        finishDate == date.plusDays(1) -> "tomorrow "
                        finishDate > date -> android.text.format.DateFormat.getDateFormat(app).format(java.util.Date(forecast.finishMs)) + " "
                        else -> ""
                    }
                    val text = if (forecast.darkNow == true) "It's dark now. " +
                        (forecast.nextSunriseMs?.let { "Sunrise ${android.text.format.DateFormat.getTimeFormat(app).format(java.util.Date(it))}." }
                            ?: "No sunrise time available.") else
                        "Estimated finish $finishLabel${android.text.format.DateFormat.getTimeFormat(app).format(java.util.Date(forecast.finishMs))} " +
                            "is after the sunset safety margin (${app.prefs.daylightMarginMinutes} min)."
                    alertDaylight(Notifications.ID_DAYLIGHT, "Daylight warning", text)
                    app.watch.daylightAlert(Daylight.watchAlert(forecast.darkNow == true))
                }
                if (alert == 2) {
                    duskAlerted = true
                    alertDaylight(Notifications.ID_DUSK, "Dark by finish", "Estimated finish is after civil dusk. Plan a safe way down.")
                }
                val flags = (if (sunsetAlerted) 1 else 0) or (if (duskAlerted) 2 else 0)
                val state = "$walkKey:$flags"
                if (app.prefs.daylightAlertState != state) app.prefs.daylightAlertState = state
            }
            when (detector.update(rf.offRouteM, f.accuracyM.toDouble())) {
                OffRouteDetector.Event.LEFT_ROUTE -> { offRoute = true; alertOffRoute(rf, f) }
                OffRouteDetector.Event.REJOINED_ROUTE -> {
                    offRoute = false
                    Notifications.manager(app).cancel(Notifications.ID_OFF_ROUTE)
                    vibrate(longArrayOf(0, 80))
                }
                OffRouteDetector.Event.NONE -> Unit
            }
        }
        changed()
    }

    private fun alertOffRoute(rf: RouteFix, f: Fix) {
        vibrate(longArrayOf(0, 400, 200, 400, 200, 400))
        val back = Geo.bearingDeg(LatLon(f.lat, f.lon), rf.snapped)
        val text = "${Units.distance(rf.offRouteM, app.prefs.imperial)} from the route. " +
            "Nearest route point is ${Units.bearing(back)} (${Geo.cardinal(back)})."
        val open = PendingIntent.getActivity(app, 10, Intent(app, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(app, Notifications.CH_ALERTS)
            .setSmallIcon(R.drawable.ic_stat_hike)
            .setContentTitle("Off route")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .apply { if (Build.VERSION.SDK_INT >= 28) setCategory(Notification.CATEGORY_NAVIGATION) }
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { Notifications.manager(app).notify(Notifications.ID_OFF_ROUTE, n) }
    }

    private fun alertDaylight(id: Int, title: String, text: String) {
        vibrate(longArrayOf(0, 400, 200, 400))
        val open = PendingIntent.getActivity(app, 10, Intent(app, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(app, Notifications.CH_ALERTS)
            .setSmallIcon(R.drawable.ic_stat_hike).setContentTitle(title).setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text)).setContentIntent(open).setAutoCancel(true).build()
        runCatching { Notifications.manager(app).notify(id, notification) }
    }

    private fun vibrate(pattern: LongArray) {
        val v: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
            (app.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            app.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        runCatching { v?.vibrate(VibrationEffect.createWaveform(pattern, -1)) }
    }

    companion object {
        /** Id of the in-memory "retrace steps" route; stored routes start at 1. */
        const val TRACBACK_ID = 0L
    }
}
