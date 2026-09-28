package com.trailmind.app.ui

import android.text.InputType
import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.data.HikeMeta
import com.trailmind.app.data.HikeStatus
import com.trailmind.app.data.LidarChecks
import com.trailmind.app.data.OpenMeteo
import com.trailmind.app.data.OverpassFacilities
import com.trailmind.app.data.RouteData
import com.trailmind.app.data.RouteMeta
import com.trailmind.app.data.SavedFacilities
import com.trailmind.app.data.SavedLidarCheck
import com.trailmind.app.data.WaymarkedTrails
import com.trailmind.app.location.TrackingState
import com.trailmind.app.location.CheckIn
import com.trailmind.app.location.LocationHub
import com.trailmind.app.map.LidarProvider
import com.trailmind.app.map.TileSources
import com.trailmind.app.map.TileGrid
import com.trailmind.app.map.TerrainProvider
import com.trailmind.core.geo.WebMercator
import com.trailmind.core.stats.TripReadiness
import com.trailmind.core.weather.MountainWeather
import com.trailmind.core.format.Units
import com.trailmind.core.geo.FacilityCategory
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.TileKey
import com.trailmind.core.map.BngTiles
import com.trailmind.core.gpx.GpxWriter
import com.trailmind.core.stats.HikeEstimator
import com.trailmind.core.stats.TrackStats
import java.io.StringWriter
import java.text.DateFormat
import java.util.Date
import kotlin.math.roundToInt

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
        ui.button("Plan", R.drawable.ic_map, Ui.B.TONAL) { host.map.startPlan() },
        ui.button("Import", R.drawable.ic_upload, Ui.B.TONAL) { host.pickGpx() },
    )) {
        activeId = app.nav.active?.data?.meta?.id
        val list = routes
        when {
            list == null -> addView(ui.text("Loading…", Ui.T.CAPTION))
            list.isEmpty() -> addView(ui.card(spacing = 10) {
                addView(ui.text("No routes yet", Ui.T.TITLE))
                addView(ui.text("Find a waymarked route, plan a walk on the map, or import a GPX track or route. TrailMind shows it on the map, estimates timings and warns you if you stray from it.", Ui.T.BODY))
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
    private var facilities: SavedFacilities? = null
    private var facilityFilter: FacilityCategory? = null
    private var facilityCacheUnreadable = false
    private var showAllFacilities = false
    private var loaded = false
    private var loading = false
    private var profile: ElevationProfileView? = null
    private var mapCoverage: Int? = null
    private var mapCoverageUntilMs: Long? = null
    private var coverageSourceId: String? = null
    private var forecast: com.trailmind.core.weather.PointForecast? = null
    private var checking = false
    private var fetchingWeather = false
    private var addingTerrain = false
    private var lidarCheck: SavedLidarCheck? = null
    private var lidarSquares: Int? = null
    private var lidarMissing = 0
    private val lidarListener: () -> Unit = { loadLidar() }
    private val facilityListener: (Result<SavedFacilities>) -> Unit = { result ->
        result.onSuccess { facilities = it; facilityCacheUnreadable = false; showAllFacilities = false; host.map.updateFacilities() }
            .onFailure { host.toast("Could not find facilities: ${it.message ?: "connection failed"}") }
        updateReadiness()
        refresh()
    }
    private val navListener: () -> Unit = {
        val following = app.nav.active?.data?.meta?.id == routeId
        if (following != wasFollowing) refresh() else profile?.cursorM = if (following) app.nav.fix?.alongM else null
    }
    private var wasFollowing = false

    override fun onShow() {
        app.nav.addListener(navListener)
        OverpassFacilities.addListener(routeId, facilityListener)
        LidarChecks.addListener(routeId, lidarListener)
        if (!loading) {
            loading = true
            Async.run({ Triple(app.db.routeData(routeId), OverpassFacilities.saved(host.applicationContext, routeId), OverpassFacilities.hasSaved(host.applicationContext, routeId)) }) { r ->
            if (!loaded) data = r.getOrNull()?.first
            facilities = r.getOrNull()?.second
            facilityCacheUnreadable = r.getOrNull()?.third == true && facilities == null
            loaded = true
            loading = false
            updateReadiness()
            loadLidar()
            refresh()
            }
        }
        if (loaded) updateReadiness()
        if (loaded) loadLidar()
        if (loaded) refresh()
    }

    override fun onHide() {
        app.nav.removeListener(navListener)
        OverpassFacilities.removeListener(routeId, facilityListener)
        LidarChecks.removeListener(routeId, lidarListener)
    }

    /** The saved LiDAR check, and how many squares a check needs and still has to download. */
    private fun loadLidar() {
        val points = data?.points?.map { it.latLon() } ?: return
        Async.run({
            val squares = LidarChecks.squares(points)
            Triple(LidarChecks.saved(host, routeId), squares.size, app.lidar.missing(squares))
        }) { r ->
            r.getOrNull()?.let { (saved, count, missing) -> lidarCheck = saved; lidarSquares = count; lidarMissing = missing }
            refresh()
        }
    }

    private fun lidarCard(d: RouteData): View = ui.card(spacing = 6) {
        val imperial = app.prefs.imperial
        addView(ui.text("Terrain check (1 m LiDAR)", Ui.T.TITLE))
        val squares = lidarSquares
        if (squares == 0) {
            addView(ui.text("The Environment Agency's LiDAR covers England, and this route is outside it.", Ui.T.CAPTION))
            return@card
        }
        val progress = LidarChecks.progress(routeId)
        val saved = lidarCheck
        when {
            progress != null -> addView(ui.text(if (progress.total == 0) "Starting…"
                else "Downloading LiDAR: ${progress.done} of ${progress.total} squares… You can leave this page.", Ui.T.CAPTION))
            saved == null -> addView(ui.text("Looks along the route for ground steep enough to need hands (35° or more over 10 m) and for crags " +
                "within 10 m, from the Environment Agency's 1 m survey of England.", Ui.T.CAPTION))
        }
        if (progress == null) LidarChecks.error(routeId)?.let { addView(ui.text(it, Ui.T.CAPTION, p.danger)) }
        if (saved != null && progress == null) {
            val report = saved.report
            // A result for the whole route needs LiDAR along all of it; a gap is never rounded up to 100%.
            val full = report.lengthM > 0 && report.coveredM >= report.lengthM - 0.5
            val coverage = when {
                full -> 100
                report.lengthM > 0 -> (report.coveredM / report.lengthM * 100).toInt().coerceAtMost(99)
                else -> 0
            }
            addView(ui.text("Checked ${fmtDate(saved.checkedMs)} · LiDAR covers $coverage% of the route", Ui.T.CAPTION))
            if (report.steep.isEmpty() && report.crags.isEmpty()) addView(ui.text(when {
                full -> "No stretch of the line is 35° or steeper over 10 m, and no crag is within 10 m of it."
                report.coveredM > 0 -> "Where LiDAR covers the route, no stretch of the line is 35° or steeper over 10 m, and no crag " +
                    "is within 10 m of it. The rest of the route wasn't checked."
                report.lengthM < 1 -> "The route is too short to check."
                else -> "LiDAR has no heights along this route, so it couldn't be checked. The Environment Agency's survey covers " +
                    "most of England, but not Wales or Scotland."
            }, Ui.T.BODY))
            else if (!full) addView(ui.text("Only the $coverage% of the route that LiDAR covers was checked.", Ui.T.CAPTION))
            if (report.steep.isNotEmpty()) {
                addView(ui.text("Steep enough for hands: ${report.steep.size}", Ui.T.LABEL))
                report.steep.take(12).forEach { s ->
                    addView(ui.listItem("At ${Units.distance(s.startM, imperial)} · ${s.value.roundToInt()}°",
                        "For ${Units.distance(s.endM - s.startM, imperial)} along the line. Tap to see it.") { showOnMap(s.at) })
                }
            }
            if (report.crags.isNotEmpty()) {
                addView(ui.text("Crag within 10 m: ${report.crags.size}", Ui.T.LABEL))
                report.crags.take(12).forEach { s ->
                    addView(ui.listItem("At ${Units.distance(s.startM, imperial)} · ${if (s.value < 1) "on the line" else "${Units.distance(s.value, imperial)} away"}",
                        "For ${Units.distance(maxOf(s.endM - s.startM, 1.0), imperial)} along the line. Tap to see it.") { showOnMap(s.at) })
                }
            }
            addView(ui.text("Measured along the route line: a path that zigzags up a slope is less steep than the line, and the line " +
                "can be a few metres off the path. LiDAR is the bare ground, without walls, trees or buildings. Look at the map before you rely on it.", Ui.T.CAPTION))
        }
        if (progress == null) {
            val online = app.tiles.networkAllowed()
            val missing = lidarMissing
            addView(ui.button(if (saved == null) "Check with LiDAR" else "Check again", R.drawable.ic_route, Ui.B.TONAL) {
                if (LidarChecks.start(host, routeId, d.points.map { it.latLon() })) refresh()
            }.apply { isEnabled = squares != null && (online || missing == 0); alpha = if (isEnabled) 1f else 0.5f })
            addView(ui.text(when {
                squares == null -> "Working out the download…"
                missing == 0 -> "The LiDAR for this route is on the phone."
                !online -> "Needs normal signal to download about ${lidarMb(missing)}."
                else -> "Downloads about ${lidarMb(missing)} and keeps it on the phone."
            }, Ui.T.CAPTION))
        }
        addView(ui.link(LidarProvider.CREDIT) { host.openUrl(LidarProvider.DATASET_URL) })
    }

    private fun lidarMb(squares: Int) = "%.1f MB".format(squares * LidarProvider.SQUARE_BYTES_ESTIMATE / 1_048_576.0)

    private fun showOnMap(at: LatLon) {
        host.map.showLidarLayer()
        if (app.nav.active?.data?.meta?.id == routeId) host.map.centerOn(at, 17.0)
        else app.nav.follow(routeId) { if (it != null) host.map.centerOn(at, 17.0) }
    }

    fun onBaseMapChanged() {
        refresh()
        updateReadiness()
    }

    fun applyTerrainData(updated: RouteData?) {
        if (updated != null) data = updated
        refresh()
    }

    private fun updateReadiness() {
        val route = data ?: return
        if (checking) return
        checking = true
        val source = TileSources.byId(app.prefs.baseSourceId, app.prefs, app.tiles.packs)
        Async.run({
            val saved = OpenMeteo.saved(host, routeId)
            val points = TripReadiness.sampleRoute(route.points.map { it.latLon() })
            val packs = app.tiles.packsFor(source)
            val leisure = source.grid == TileGrid.BRITISH_NATIONAL_GRID
            val detailZoom = if (leisure) packs.maxOfOrNull { it.premiumMaxZoom }?.takeIf { it >= 6 } else null
            val coverage = if (source.id == TileSources.OSM ||
                source.isOnline && !source.offlineDownloadAllowed) null else {
                val footprints = packs.associate { it.id to app.tiles.footprint(it) }
                val hits = points.count { point -> packs.any { pack ->
                    val grid = if (leisure) OsGrid.fromWgs84(point) else null
                    val tile = if (leisure) grid?.let {
                        TileKey(pack.maxZoom, BngTiles.column(it.easting, pack.maxZoom), BngTiles.row(it.northing, pack.maxZoom))
                    } else WebMercator.tileFor(point, pack.maxZoom)
                    val footprint = footprints[pack.id]
                    val spans = footprint?.spans
                    val inside = tile != null && (spans == null || footprint.zoom != pack.maxZoom ||
                        spans.indices.step(3).any { spans[it] == tile.y && tile.x in spans[it + 1] until spans[it + 2] })
                    inside && runCatching { app.tiles.openPack(pack)?.hasTile(tile) == true }.getOrDefault(false)
                } && (detailZoom == null || run {
                    val grid = OsGrid.fromWgs84(point)
                    grid != null && app.tiles.hasFreshPremium(source, TileKey(detailZoom,
                        BngTiles.column(grid.easting, detailZoom), BngTiles.row(grid.northing, detailZoom)))
                }) }
                TripReadiness.coverage(hits, points.size)
            }
            val expiry = detailZoom?.let { zoom -> points.mapNotNull { point ->
                val grid = OsGrid.fromWgs84(point) ?: return@mapNotNull null
                val tile = TileKey(zoom, BngTiles.column(grid.easting, zoom), BngTiles.row(grid.northing, zoom))
                app.tiles.premiumCachedAt(source, tile).takeIf { it > 0 }?.plus(24 * 3_600_000L)
            }.minOrNull() } ?: if (leisure) packs.filter { it.premiumMaxZoom >= 6 && it.premiumMs > 0 }
                .maxOfOrNull { it.premiumMs + 24 * 3_600_000L } else null
            Triple(saved, coverage, expiry)
        }) { result ->
            result.getOrNull()?.let { (weather, coverage, until) ->
                forecast = weather; mapCoverage = coverage; coverageSourceId = source.id; mapCoverageUntilMs = until
            }
            checking = false
            if (app.prefs.baseSourceId != source.id) { updateReadiness(); return@run }
            refresh()
        }
    }

    private fun readinessCard(route: RouteData, planningMinutes: Double): View = ui.card(spacing = 6) {
        data class Check(val title: String, val detail: String, val ready: Boolean, val fix: String? = null, val action: (() -> Unit)? = null)
        val now = System.currentTimeMillis()
        val source = TileSources.byId(app.prefs.baseSourceId, app.prefs, app.tiles.packs)
        val mapNeedsSignal = source.id == TileSources.OSM ||
            source.isOnline && !source.offlineDownloadAllowed
        val coverage = mapCoverage.takeIf { coverageSourceId == source.id }
        val explorerExpired = source.id == TileSources.OS_LEISURE && mapCoverageUntilMs?.let { it <= now } == true
        val currentCoverage = if (explorerExpired) 0 else coverage
        val canDownload = source.offlineDownloadAllowed
        val daylight = startByText(host, route.points, app.prefs.pace, app.prefs.daylightMarginMinutes, now)
        val daylightSafe = daylight.startsWith("Start by") && !daylight.contains("has passed")
        val high = HikeEstimator.highPoint(route.points, app.prefs.pace)
        val weather = forecast
        val fresh = weather != null && now - weather.fetchedMs in 0 until 6 * 3_600_000L
        val hour = if (high != null) weather?.at(now + (high.minutesFromStart * 1.2 * 60_000).toLong()) else null
        val warnings = if (hour != null && high != null) MountainWeather.warnings(hour, high.eleM, app.prefs.imperial) else emptyList()
        val battery = host.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val rawLevel = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val level = if (rawLevel >= 0 && scale > 0) rawLevel * 100 / scale else -1
        val charging = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, 0) in listOf(BatteryManager.BATTERY_STATUS_CHARGING, BatteryManager.BATTERY_STATUS_FULL)
        val threshold = maxOf(30, (20 + planningMinutes / 6).toInt())
        val location = LocationHub.hasPermission(host) && host.isGpsEnabled()
        val checkInAlerts = (Build.VERSION.SDK_INT < 33 || host.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            Notifications.manager(host).areNotificationsEnabled() &&
            Notifications.manager(host).getNotificationChannel(Notifications.CH_CHECK_IN)?.importance != NotificationManager.IMPORTANCE_NONE
        val alerts = checkInAlerts && Notifications.manager(host).getNotificationChannel(Notifications.CH_ALERTS)?.importance != NotificationManager.IMPORTANCE_NONE
        val due = app.prefs.checkInDueMs
        val contact = app.prefs.emergencyContact.isNotBlank()
        val checks = mutableListOf(
            Check("Offline map", if (mapNeedsSignal) "${source.name} needs signal" else when (currentCoverage) {
                null -> "Checking saved tiles…"
                100 -> if (source.id == TileSources.OS_LEISURE && mapCoverageUntilMs?.let { it > now } == true)
                    "OS detail covered until ${java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT, java.text.DateFormat.SHORT).format(java.util.Date(mapCoverageUntilMs!!))}"
                    else "Covered at pack detail"
                0 -> if (explorerExpired)
                    "OS detail expired; reload for today's walk" else "Not covered"
                else -> "Partly covered ($currentCoverage%)"
            }, !mapNeedsSignal && currentCoverage == 100, if (canDownload && currentCoverage != 100) "Download route corridor" else null,
                if (canDownload && currentCoverage != 100) ({ host.push(OfflinePage(host, routeId)) }) else null),
            Check("Daylight", daylight, daylightSafe),
            Check("Weather", when {
                high == null -> "No high point forecast; check conditions yourself"
                weather == null -> "No forecast saved"
                !fresh -> "Saved forecast is over 6 hours old"
                hour == null -> "Forecast does not cover the planned high point time"
                warnings.isNotEmpty() -> warnings.joinToString("; ")
                else -> "Saved forecast is fresh"
            }, fresh && hour != null && warnings.isEmpty(), if (high != null && !fetchingWeather) "Fetch forecast" else null,
                if (high != null && !fetchingWeather) ({
                    fetchingWeather = true; refresh()
                    Async.run({ OpenMeteo.fetch(host, routeId, high.position, high.eleM) }) { r ->
                        fetchingWeather = false
                        r.onSuccess { forecast = it }.onFailure { host.toast("Forecast unavailable: ${it.message}") }
                        refresh()
                    }
                }) else null),
            Check("Facilities", if (facilities != null) "Saved for offline use" else "Not saved for offline use", facilities != null,
                if (facilities == null) "Find facilities" else null, if (facilities == null) ({
                    OverpassFacilities.start(host, routeId, route.points.map { it.latLon() }); refresh()
                }) else null),
            Check("Battery", if (level < 0) "Battery level unavailable" else "$level%${if (charging) ", charging" else ""}; aim for at least $threshold% for this walk",
                level >= threshold),
            Check("Location & alerts", if (location && alerts) "Location and notifications ready" else
                "${if (!location) "Location permission or services off" else "Location ready"}; ${if (alerts) "alerts allowed" else "allow notifications"}", location && alerts,
                if (location && alerts) null else "Fix settings", {
                    when { !LocationHub.hasPermission(host) -> host.withLocationPermission { refresh() }
                        !host.isGpsEnabled() -> host.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                        host.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED -> host.requestNotificationPermissionIfNeeded()
                        else -> host.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, host.packageName)) }
                }),
            Check("Check-in & contact", "${when { due > now -> "Check-in ${clockTime(host, due)}"; due > 0 -> "Check-in overdue"; else -> "No check-in set" }} · ${if (contact) "contact saved" else "contact missing"}${if (!checkInAlerts) " · notifications off" else ""}${if (due > 0 && CheckIn.delayedAlarm(host)) " · alarm may be late" else ""}",
                due > now && contact && checkInAlerts && !CheckIn.delayedAlarm(host),
                if (due > 0 && CheckIn.delayedAlarm(host)) "Allow exact alarms" else if (due > 0) "Edit check-in" else "Set check-in",
                { if (due > 0 && CheckIn.delayedAlarm(host)) requestExactAlarms(host) else pickCheckIn(host, route.meta.name, planningMinutes, routeId) { refresh() } }),
        )
        if (app.prefs.watchEnabled) checks += Check("Watch", app.watch.statusText(), app.watch.status == com.trailmind.app.watch.WatchLink.Status.CONNECTED,
            "Watch settings", { host.push(SettingsPage(host)) })
        addView(ui.text("Ready to go?", Ui.T.TITLE))
        addView(ui.text(TripReadiness.summary(checks.count { it.ready }, checks.size), Ui.T.BODY))
        checks.forEach { check ->
            addView(ui.text("${if (check.ready) "Ready" else "Check"} · ${check.title}: ${check.detail}", Ui.T.CAPTION))
            if (check.fix != null && check.action != null) addView(ui.button(check.fix, null, Ui.B.TEXT) { check.action.invoke() })
        }
        if (!contact) addView(ui.button("Save emergency contact", R.drawable.ic_tune, Ui.B.TEXT) { host.push(SettingsPage(host)) })
        addView(ui.link(OpenMeteo.ATTRIBUTION) { host.openUrl(OpenMeteo.URL) })
    }

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
                addView(ui.text("Planning time ${Units.minutes(est.planningMinutes)} (slower of Naismith+Langmuir and Tobler at ${Units.speedKmh(app.prefs.flatSpeedKmh / 3.6, imperial)}, ×${app.prefs.conditionsFactor} for conditions). Excludes breaks.", Ui.T.CAPTION))
                addView(ui.text(startByText(host, d.points, app.prefs.pace, app.prefs.daylightMarginMinutes, System.currentTimeMillis()), Ui.T.BODY))
            })
            addView(readinessCard(d, est.planningMinutes))
            addView(ui.card(padding = 12) {
                addView(ui.text("Elevation profile", Ui.T.LABEL))
                addView(ElevationProfileView(host, imperial).also {
                    it.setPoints(d.points)
                    if (following) it.cursorM = app.nav.fix?.alongM
                    profile = it
                })
                if (d.meta.terrainDerived) addView(ui.text(TerrainProvider.CREDIT, Ui.T.CAPTION))
                if (d.points.isNotEmpty() && d.points.any { it.ele == null }) {
                    addView(ui.button(if (addingTerrain) "Adding heights…" else "Add heights", R.drawable.ic_add, Ui.B.TONAL) {
                        if (addingTerrain) return@button
                        addingTerrain = true
                        refresh()
                        Async.run({
                            val filled = app.terrain.fill(d.points)
                            val changed = app.db.updateRouteHeights(routeId, filled)
                            changed to app.db.routeData(routeId)
                        }) { result ->
                            addingTerrain = false
                            result.onSuccess { (changed, updated) ->
                                if (changed) {
                                    data = updated
                                    host.toast("Terrain heights added")
                                } else host.toast("Terrain heights unavailable")
                            }.onFailure { host.toast("Terrain heights unavailable") }
                            refresh()
                        }
                    }.apply { isEnabled = !addingTerrain })
                }
            })
            addView(lidarCard(d))
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
            addView(ui.card(spacing = 8) {
                addView(ui.text("Facilities along the way", Ui.T.TITLE))
                val saved = facilities
                if (facilityCacheUnreadable) addView(ui.text("Saved facilities couldn't be read. Update to fetch them again.", Ui.T.CAPTION))
                else if (saved == null) addView(ui.text("Find parking, toilets, water, food, transport and places to stay near this route. Save the results for offline use.", Ui.T.CAPTION))
                else {
                    addView(ui.text("Updated ${fmtDate(saved.fetchedMs)}", Ui.T.CAPTION))
                    if (saved.partial) addView(ui.text("Long route or response limit: showing a limited selection of nearby facilities.", Ui.T.CAPTION))
                    if (saved.items.isEmpty()) addView(ui.text(if (saved.partial) "No facilities returned in the limited results." else "No mapped facilities found near this route.", Ui.T.CAPTION))
                    else {
                        addView(ui.flow {
                            saved.items.groupingBy { it.category }.eachCount().forEach { (category, count) ->
                                addView(ui.chip("${category.label} $count", facilityFilter == category) {
                                    facilityFilter = if (facilityFilter == category) null else category
                                    refresh()
                                })
                            }
                        })
                        val visible = saved.items.filter { facilityFilter == null || it.category == facilityFilter }
                        (if (showAllFacilities) visible else visible.take(60)).forEach { item ->
                            val title = item.name.ifBlank { item.category.label }
                            val detail = "${item.category.label} · at ${Units.distance(item.alongM, imperial)}, ${Units.distance(item.offM, imperial)} off route" +
                                item.openingHours.takeIf { it.isNotBlank() }?.let { " · Hours: $it" }.orEmpty() +
                                item.ele.toDoubleOrNull()?.let { " · ${Units.elevation(it, imperial)} high" }.orEmpty()
                            addView(ui.listItem(title, detail) {
                                if (app.nav.active?.data?.meta?.id == routeId) host.map.centerOn(item.position, 16.0)
                                else app.nav.follow(routeId) { if (it != null) host.map.centerOn(item.position, 16.0) }
                            })
                        }
                        if (!showAllFacilities && visible.size > 60) addView(ui.button("Show all ${visible.size}", R.drawable.ic_search, Ui.B.TONAL) {
                            showAllFacilities = true
                            refresh()
                        })
                    }
                    addView(ui.switch("Show facilities on the map", app.prefs.showFacilities) {
                        app.prefs.showFacilities = it
                        host.map.updateFacilities()
                    })
                }
                val fetching = OverpassFacilities.isFetching(routeId)
                val online = !app.prefs.offlineOnly && OverpassFacilities.online(host)
                if (fetching) {
                    addView(ui.text("Finding facilities… Long routes can take about two minutes. You can leave this page and return.", Ui.T.CAPTION))
                    addView(ui.button("Finding facilities", R.drawable.ic_search, Ui.B.TONAL) {}.apply { isEnabled = false })
                } else if (!online) {
                    addView(ui.text("Connect to the internet to find or update facilities. Saved results are still available.", Ui.T.CAPTION))
                    addView(ui.button(if (saved == null && !facilityCacheUnreadable) "Find facilities" else "Update", R.drawable.ic_search, Ui.B.TONAL) {}.apply { isEnabled = false })
                } else addView(ui.button(if (saved == null && !facilityCacheUnreadable) "Find facilities" else "Update", R.drawable.ic_search, Ui.B.TONAL) {
                    OverpassFacilities.start(host, routeId, d.points.map { it.latLon() })
                    refresh()
                })
                addView(ui.text(OverpassFacilities.ATTRIBUTION, Ui.T.CAPTION))
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
                        if (n.isNotBlank()) Async.run({ app.db.renameRoute(routeId, n); app.db.routeData(routeId) }) { r ->
                            data = r.getOrNull()
                            if (data != null && app.prefs.checkInRouteId == routeId) app.prefs.checkInRoute = n
                            refresh()
                        }
                    }
                }, ui.lp(0, weight = 1f))
                addView(ui.button("Delete", R.drawable.ic_delete, Ui.B.TEXT) {
                    ui.confirm("Delete route?", "\"${d.meta.name}\" will be removed. Recorded hikes are kept.", "Delete") {
                        if (following) app.nav.stopFollowing()
                        Async.run({ app.db.deleteRoute(routeId); OpenMeteo.delete(host, routeId); OverpassFacilities.delete(host, routeId); LidarChecks.delete(host, routeId) }) { result ->
                            if (result.isSuccess && app.prefs.checkInRouteId == routeId) CheckIn.clear(host)
                            host.goBack()
                        }
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
