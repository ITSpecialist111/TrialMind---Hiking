package com.trailmind.app.ui

import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.data.HikeMeta
import com.trailmind.app.data.HikeStatus
import com.trailmind.app.data.RouteData
import com.trailmind.app.data.RouteMeta
import com.trailmind.app.data.WaymarkedTrails
import com.trailmind.app.location.TrackingState
import com.trailmind.core.format.Units
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.gpx.GpxWriter
import com.trailmind.core.stats.HikeEstimator
import com.trailmind.core.stats.TrackStats
import java.io.StringWriter
import java.text.DateFormat
import java.util.Date

private fun fmtDate(ms: Long): String = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(ms))

// ====================================================================== routes

class RoutesPage(host: MainActivity) : Page(host) {
    private var routes: List<RouteMeta>? = null
    private val navListener: () -> Unit = { if (activeId != app.nav.active?.data?.meta?.id) refresh() }
    private var activeId: Long? = null

    override fun onShow() {
        app.nav.addListener(navListener)
        load()
    }

    override fun onHide() { app.nav.removeListener(navListener) }

    private fun load() = Async.run({ app.db.routes() }) { r -> routes = r.getOrDefault(emptyList()); refresh() }

    override fun render(): View = scaffold("Routes", actions = listOf(
        ui.button("Find", R.drawable.ic_route, Ui.B.TONAL) { host.push(RouteFinderPage(host)) },
        ui.button("Import", R.drawable.ic_upload, Ui.B.TONAL) { host.pickGpx() },
    )) {
        activeId = app.nav.active?.data?.meta?.id
        val list = routes
        when {
            list == null -> addView(ui.text("Loading…", Ui.T.CAPTION))
            list.isEmpty() -> addView(ui.card(spacing = 10) {
                addView(ui.text("No routes yet", Ui.T.TITLE))
                addView(ui.text("Find a waymarked route near you or by name, or import a GPX track or route (from Komoot, OS Maps, AllTrails exports, a club website…). TrailMind shows it on the map, estimates timings and warns you if you stray from it.", Ui.T.BODY))
                addView(ui.text("You can also open or share a .gpx file to TrailMind from your file manager or browser.", Ui.T.CAPTION))
                addView(ui.button("Find routes", R.drawable.ic_route) { host.push(RouteFinderPage(host)) })
                addView(ui.button("Import GPX file", R.drawable.ic_upload, Ui.B.TONAL) { host.pickGpx() })
            })
            else -> list.forEach { r ->
                val imperial = app.prefs.imperial
                addView(ui.listItem(
                    r.name,
                    "${nb(Units.distance(r.distanceM, imperial))} · ${nb("↑" + Units.elevation(r.ascentM, imperial))}" +
                        (r.maxEleM?.let { " · ${nb("max " + Units.elevation(it, imperial))}" } ?: "") +
                        " · ${nb("~" + Units.minutes(naismithQuick(r)))}",
                    R.drawable.ic_route,
                    if (r.id == activeId) "Following" else null,
                ) { host.push(RouteDetailPage(host, r.id)) })
            }
        }
    }

    /** Quick Naismith (with the user's pace) from stored totals; the detail page uses the full profile. */
    private fun naismithQuick(r: RouteMeta): Double {
        val pace = app.prefs.pace
        return (r.distanceM / 1000.0 / pace.flatSpeedKmh * 60.0 + r.ascentM / 10.0) * pace.conditionsFactor
    }
}

/** Waymarked routes from OpenStreetMap, listed near you or found by name, added in one tap. */
class RouteFinderPage(host: MainActivity) : Page(host) {
    private enum class Mode { NEAR_ME, MAP_VIEW, SEARCH }

    private var mode = Mode.NEAR_ME
    private var searched = ""
    private var results: List<WaymarkedTrails.Trail>? = null
    private var error: String? = null
    private var noFix = false
    private var job = 0

    /** One search box for the page's life, so typing is not interrupted when results arrive and the page re-renders. */
    private val box: EditText by lazy {
        ui.input("Route name, e.g. Offa's Dyke").apply {
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            setOnEditorActionListener { _, action, _ -> if (action == EditorInfo.IME_ACTION_SEARCH) { submit(); true } else false }
        }
    }

    override fun onShow() { if (results == null && error == null) load(Mode.NEAR_ME) }

    override fun refresh() {
        val typing = box.hasFocus()
        super.refresh()
        if (typing) box.requestFocus()
    }

    /** The map's visible area; when the map is hidden (cover screen) it has no size, so use an area round its centre. */
    private fun mapBox(): BoundingBox {
        val b = host.map.mapView.visibleBounds()
        val span = Geo.distanceM(LatLon(b.minLat, b.minLon), LatLon(b.maxLat, b.maxLon))
        return if (span < 500) b.expandedByMetres(NEAR_M) else b
    }

    private fun load(m: Mode) {
        val q = box.text.toString().trim()
        if (m == Mode.SEARCH && q.length < 2) { host.toast("Type at least two letters of the route name"); return }
        mode = m
        if (m == Mode.SEARCH) searched = q
        val fix = app.location.latest
        noFix = m == Mode.NEAR_ME && fix == null
        val area = when {
            m == Mode.SEARCH -> null
            m == Mode.NEAR_ME && fix != null -> BoundingBox(fix.lat, fix.lon, fix.lat, fix.lon).expandedByMetres(NEAR_M)
            else -> mapBox()
        }
        val id = ++job
        results = null
        error = null
        refresh()
        Async.run({ if (area != null) WaymarkedTrails.inArea(area) else WaymarkedTrails.search(q) }) { r ->
            if (id != job) return@run
            results = r.getOrNull()
            error = r.exceptionOrNull()?.let { friendly(it) }
            refresh()
        }
    }

    private fun submit() {
        host.getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(box.windowToken, 0)
        box.clearFocus()
        load(Mode.SEARCH)
    }

    override fun render(): View = scaffold("Find routes") {
        (box.parent as? ViewGroup)?.removeView(box)
        addView(ui.row {
            addView(box, ui.lp(0, weight = 1f))
            addView(ui.button("Search", null, Ui.B.TONAL) { submit() })
        })
        addView(ui.flow {
            addView(ui.chip("Near me", mode == Mode.NEAR_ME) { load(Mode.NEAR_ME) })
            addView(ui.chip("In map view", mode == Mode.MAP_VIEW) { load(Mode.MAP_VIEW) })
        })
        val list = results
        val err = error
        when {
            err != null -> addView(ui.banner(err))
            list == null -> addView(ui.text(if (mode == Mode.SEARCH) "Searching…" else "Looking for waymarked routes…", Ui.T.CAPTION))
            list.isEmpty() -> addView(ui.text(
                if (mode == Mode.SEARCH) "No waymarked route is called \"$searched\". Try part of the name."
                else "No waymarked routes here. Zoom the map out and try \"In map view\", or search by name.",
                Ui.T.CAPTION,
            ))
            else -> {
                addView(ui.text(when (mode) {
                    Mode.SEARCH -> "Routes matching \"$searched\""
                    Mode.MAP_VIEW -> "Routes in the map view"
                    Mode.NEAR_ME -> if (noFix) "No GPS fix yet, so these are routes around the map centre"
                        else "Routes within ${Units.distance(NEAR_M, app.prefs.imperial)} of you"
                }, Ui.T.LABEL))
                list.forEach { t ->
                    addView(ui.listItem(t.name, listOfNotNull(t.kind, t.ref?.takeIf { it != t.name }).joinToString(" · "), R.drawable.ic_route) { add(t) })
                }
            }
        }
        addView(ui.text("These are signed routes mapped in OpenStreetMap: national trails, regional ways and local waymarked walks. Tap one to add it to your routes. " + WaymarkedTrails.ATTRIBUTION, Ui.T.CAPTION))
    }

    private fun add(t: WaymarkedTrails.Trail) {
        val progress = ui.dialog().setTitle(t.name).setMessage("Downloading the route…").setCancelable(false).show()
        Async.run({
            val d = WaymarkedTrails.download(t)
            d to app.db.insertRoute(d.name, d.points, emptyList())
        }) { r ->
            progress.dismiss()
            r.onSuccess { (d, id) ->
                host.toast(when {
                    d.hasElevation -> "Route added"
                    d.lengthM > WaymarkedTrails.ELEVATION_MAX_M -> "Route added. Heights are only downloaded for routes up to ${Units.distance(WaymarkedTrails.ELEVATION_MAX_M, app.prefs.imperial)}."
                    else -> "Route added without heights"
                })
                host.push(RouteDetailPage(host, id))
            }.onFailure { e ->
                ui.dialog().setTitle("Could not add the route").setMessage(friendly(e)).setPositiveButton("OK", null).show()
            }
        }
    }

    private fun friendly(e: Throwable): String = when (e) {
        is java.net.UnknownHostException, is java.net.ConnectException, is java.net.SocketTimeoutException ->
            "Waymarked Trails could not be reached. Check your mobile data or Wi-Fi."
        else -> e.message ?: e.toString()
    }

    private companion object {
        const val NEAR_M = 10_000.0
    }
}

class RouteDetailPage(host: MainActivity, private val routeId: Long) : Page(host) {
    private var data: RouteData? = null
    private var loaded = false
    private var profile: ElevationProfileView? = null
    private val navListener: () -> Unit = {
        val following = app.nav.active?.data?.meta?.id == routeId
        if (following != wasFollowing) refresh() else profile?.cursorM = if (following) app.nav.fix?.alongM else null
    }
    private var wasFollowing = false

    override fun onShow() {
        app.nav.addListener(navListener)
        if (!loaded) Async.run({ app.db.routeData(routeId) }) { r -> data = r.getOrNull(); loaded = true; refresh() }
    }

    override fun onHide() { app.nav.removeListener(navListener) }

    override fun render(): View {
        val d = data
        if (d == null) return scaffold("Route") { addView(ui.text(if (loaded) "This route no longer exists." else "Loading…", Ui.T.CAPTION)) }
        val imperial = app.prefs.imperial
        val following = app.nav.active?.data?.meta?.id == routeId
        wasFollowing = following
        val est = HikeEstimator.estimate(d.points, app.prefs.pace)
        return scaffold(d.meta.name) {
            addView(ui.card {
                addView(ui.statGrid(listOf(
                    "Distance" to Units.distance(d.meta.distanceM, imperial),
                    "Ascent" to "↑" + Units.elevation(d.meta.ascentM, imperial),
                    "Descent" to "↓" + Units.elevation(d.meta.descentM, imperial),
                    "Naismith" to Units.minutes(est.naismithMinutes),
                    "Tobler" to Units.minutes(est.toblerMinutes),
                    "Highest" to (d.meta.maxEleM?.let { Units.elevation(it, imperial) } ?: "—"),
                )))
                addView(ui.text("Planning time ${Units.minutes(est.planningMinutes)} (slower of Naismith+Langmuir and Tobler at ${app.prefs.flatSpeedKmh} km/h, ×${app.prefs.conditionsFactor} for conditions). Excludes breaks.", Ui.T.CAPTION))
            })
            addView(ui.card(padding = 12) {
                addView(ui.text("Elevation profile", Ui.T.LABEL))
                addView(ElevationProfileView(host, imperial).also {
                    it.setPoints(d.points)
                    if (following) it.cursorM = app.nav.fix?.alongM
                    profile = it
                })
            })
            addView(ui.row {
                if (following) addView(ui.button("Stop following", R.drawable.ic_close, Ui.B.TONAL) { app.nav.stopFollowing() }, ui.lp(0, weight = 1f))
                else addView(ui.button("Follow route", R.drawable.ic_navigation) {
                    app.nav.follow(routeId) { r -> r?.let { host.map.fit(BoundingBox.of(it.data.points.map { p -> p.latLon() })) } }
                }, ui.lp(0, weight = 1f))
                addView(ui.button("Show on map", R.drawable.ic_map, Ui.B.OUTLINED) {
                    if (!following) app.nav.follow(routeId)
                    host.map.fit(BoundingBox.of(d.points.map { it.latLon() }))
                }, ui.lp(0, weight = 1f))
            })
            addView(ui.row {
                addView(ui.button("Offline map", R.drawable.ic_download, Ui.B.TONAL) { host.push(OfflinePage(host, routeId)) }, ui.lp(0, weight = 1f))
                addView(ui.button("Briefing", R.drawable.ic_sparkle, Ui.B.TONAL) { host.push(AssistantPage(host, routeId)) }, ui.lp(0, weight = 1f))
            })
            val start = d.points.first().latLon()
            addView(ui.card(spacing = 4) {
                addView(ui.text("Start", Ui.T.LABEL))
                addView(ui.text(OsGrid.fromWgs84(start)?.format(8) ?: Units.latLon(start.lat, start.lon), Ui.T.MONO))
                addView(ui.text(Units.latLon(start.lat, start.lon) + " · ${d.points.size} points · imported ${fmtDate(d.meta.createdMs)}", Ui.T.CAPTION))
            })
            if (d.waypoints.isNotEmpty()) {
                addView(ui.text("Waypoints", Ui.T.LABEL))
                d.waypoints.take(100).forEach { w ->
                    addView(ui.listItem(w.name, (OsGrid.fromWgs84(w.latLon())?.format(6) ?: Units.latLon(w.lat, w.lon)) +
                        (w.ele?.let { " · ${Units.elevation(it, imperial)}" } ?: "") + (w.description?.let { " · $it" } ?: "")) {
                        host.map.centerOn(w.latLon(), 15.0)
                    })
                }
            }
            addView(ui.row {
                addView(ui.button("Save GPX", R.drawable.ic_folder, Ui.B.OUTLINED) { host.saveGpx(d.meta.name, routeGpx(d)) }, ui.lp(0, weight = 1f))
                addView(ui.button("Share", R.drawable.ic_share, Ui.B.OUTLINED) { host.shareGpx(d.meta.name, routeGpx(d)) }, ui.lp(0, weight = 1f))
            })
            addView(ui.row {
                addView(ui.button("Rename", null, Ui.B.TEXT) {
                    ui.prompt("Rename route", d.meta.name) { n ->
                        if (n.isNotBlank()) Async.run({ app.db.renameRoute(routeId, n); app.db.routeData(routeId) }) { r -> data = r.getOrNull(); refresh() }
                    }
                }, ui.lp(0, weight = 1f))
                addView(ui.button("Delete", R.drawable.ic_delete, Ui.B.TEXT) {
                    ui.confirm("Delete route?", "\"${d.meta.name}\" will be removed. Recorded hikes are kept.", "Delete") {
                        if (following) app.nav.stopFollowing()
                        Async.run({ app.db.deleteRoute(routeId) }) { host.goBack() }
                    }
                }, ui.lp(0, weight = 1f))
            })
        }
    }

    private fun routeGpx(d: RouteData): String = StringWriter().also { GpxWriter.writeRoute(it, d.meta.name, d.points, d.waypoints) }.toString()
}

// ====================================================================== hikes

class HikesPage(host: MainActivity) : Page(host) {
    private var hikes: List<HikeMeta>? = null
    private val trackingListener: () -> Unit = { if (TrackingState.status == TrackingState.Status.IDLE) load() }

    override fun onShow() {
        TrackingState.addListener(trackingListener)
        load()
    }

    override fun onHide() { TrackingState.removeListener(trackingListener) }

    private fun load() = Async.run({ app.db.hikes() }) { r -> hikes = r.getOrDefault(emptyList()); refresh() }

    override fun render(): View = scaffold("Hikes") {
        val list = hikes
        val imperial = app.prefs.imperial
        when {
            list == null -> addView(ui.text("Loading…", Ui.T.CAPTION))
            list.isEmpty() -> addView(ui.card(spacing = 10) {
                addView(ui.text("No hikes recorded yet", Ui.T.TITLE))
                addView(ui.text("Tap Start hike on the map. TrailMind records a breadcrumb trail with GPS, even with the screen off, and saves every point immediately so nothing is lost if the phone restarts.", Ui.T.BODY))
                addView(ui.button("Go to map", R.drawable.ic_map) { host.showTab(MainActivity.Tab.MAP) })
            })
            else -> {
                val total = list.filter { it.status == HikeStatus.DONE }
                addView(ui.card {
                    addView(ui.statGrid(listOf(
                        "Hikes" to total.size.toString(),
                        "Distance" to Units.distance(total.sumOf { it.distanceM }, imperial),
                        "Ascent" to "↑" + Units.elevation(total.sumOf { it.ascentM }, imperial),
                    )))
                })
                list.forEach { h ->
                    val live = h.id == TrackingState.hikeId
                    addView(ui.listItem(
                        h.name,
                        "${fmtDate(h.startMs)} · ${nb(Units.distance(h.distanceM, imperial))} · ${nb(Units.duration(h.durationMs))} · ${nb("↑" + Units.elevation(h.ascentM, imperial))}",
                        R.drawable.ic_walk,
                        when {
                            live -> "Recording"
                            h.status != HikeStatus.DONE -> "Unfinished"
                            else -> null
                        },
                    ) { host.push(HikeDetailPage(host, h.id)) })
                }
            }
        }
    }
}

class HikeDetailPage(host: MainActivity, private val hikeId: Long) : Page(host) {
    private var meta: HikeMeta? = null
    private var segments: List<List<TrackPoint>> = emptyList()
    private var loaded = false

    override fun onShow() {
        if (!loaded) load()
    }

    private fun load() = Async.run({ app.db.hike(hikeId) to app.db.hikeSegments(hikeId) }) { r ->
        loaded = true
        r.getOrNull()?.let { meta = it.first; segments = it.second }
        refresh()
    }

    override fun render(): View {
        val h = meta ?: return scaffold("Hike") { addView(ui.text(if (loaded) "This hike no longer exists." else "Loading…", Ui.T.CAPTION)) }
        val imperial = app.prefs.imperial
        val all = segments.flatten()
        val live = h.id == TrackingState.hikeId
        return scaffold(h.name) {
            if (live) addView(ui.banner("This hike is still being recorded. Finish it from the map to finalise the stats."))
            addView(ui.text(fmtDate(h.startMs) + (h.endMs?.let { " – " + DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(it)) } ?: ""), Ui.T.CAPTION))
            addView(ui.card {
                val avg = if (h.movingMs > 0) h.distanceM / (h.movingMs / 1000.0) else 0.0
                addView(ui.statGrid(listOf(
                    "Distance" to Units.distance(h.distanceM, imperial),
                    "Time" to Units.duration(h.durationMs),
                    "Moving" to Units.duration(h.movingMs),
                    "Ascent" to "↑" + Units.elevation(h.ascentM, imperial),
                    "Descent" to "↓" + Units.elevation(h.descentM, imperial),
                    "Avg moving" to Units.speedKmh(avg, imperial),
                    "Highest" to (h.maxEleM?.let { Units.elevation(it, imperial) } ?: "—"),
                    "Lowest" to (h.minEleM?.let { Units.elevation(it, imperial) } ?: "—"),
                    "Points" to all.size.toString(),
                )))
                addView(ui.text("Ascent uses a ${TrackStats.DEFAULT_ELEVATION_THRESHOLD_M.toInt()} m hysteresis to ignore GPS altitude noise; GPS altitude is typically ±10–20 m.", Ui.T.CAPTION))
            })
            addView(ui.card(padding = 12) {
                addView(ui.text("Elevation profile", Ui.T.LABEL))
                addView(ElevationProfileView(host, imperial).also { it.setPoints(all) })
            })
            if (all.size >= 2) addView(ui.button("Show on map", R.drawable.ic_map, Ui.B.OUTLINED) {
                host.map.showTrack(segments)
                host.map.fit(BoundingBox.of(all.map { it.latLon() }))
            })
            addView(ui.card(spacing = 10) {
                addView(ui.text("Export", Ui.T.LABEL))
                addView(ui.row {
                    addView(ui.button("Save GPX", R.drawable.ic_folder) { host.saveGpx(fileBase(h), gpx(h)) }, ui.lp(0, weight = 1f))
                    addView(ui.button("Share GPX", R.drawable.ic_share, Ui.B.TONAL) { host.shareGpx(fileBase(h), gpx(h)) }, ui.lp(0, weight = 1f))
                })
                addView(ui.button("Upload to Strava…", R.drawable.ic_upload, Ui.B.OUTLINED) { stravaHelp(h) })
            })
            addView(ui.row {
                addView(ui.button("Rename", null, Ui.B.TEXT) {
                    ui.prompt("Rename hike", h.name, type = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES) { n ->
                        if (n.isNotBlank()) Async.run({ app.db.renameHike(hikeId, n) }) { load() }
                    }
                }, ui.lp(0, weight = 1f))
                if (!live) addView(ui.button("Delete", R.drawable.ic_delete, Ui.B.TEXT) {
                    ui.confirm("Delete hike?", "\"${h.name}\" and its GPS track will be permanently deleted. Export it first if you want a copy.", "Delete") {
                        Async.run({ app.db.deleteHike(hikeId) }) { host.goBack() }
                    }
                }, ui.lp(0, weight = 1f))
            })
        }
    }

    private fun fileBase(h: HikeMeta) = h.name

    private fun gpx(h: HikeMeta): String = StringWriter().also {
        GpxWriter.writeTrack(it, h.name, segments, description = "Recorded with TrailMind", activityType = "hiking")
    }.toString()

    private fun stravaHelp(h: HikeMeta) {
        val msg = "TrailMind has no direct Strava connection. Strava's API requires OAuth with a registered app and a client secret that must stay on a server, " +
            "and embedding one in an app would be insecure.\n\n" +
            "Reliable manual upload:\n" +
            "1. Save the GPX (e.g. to Downloads or Drive).\n" +
            "2. Open strava.com/upload/select in a browser (use 'Desktop site' on a phone) and choose the file.\n\n" +
            "The GPX includes timestamps, elevation and the activity type 'hiking'."
        ui.dialog().setTitle("Upload to Strava")
            .setMessage(msg)
            .setPositiveButton("Save GPX") { _, _ -> host.saveGpx(fileBase(h), gpx(h)) }
            .setNeutralButton("Open upload page") { _, _ -> host.openUrl("https://www.strava.com/upload/select") }
            .setNegativeButton("Close", null)
            .show()
    }
}
