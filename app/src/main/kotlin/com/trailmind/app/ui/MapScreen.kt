package com.trailmind.app.ui

import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.SeekBar
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.data.HikeStatus
import com.trailmind.app.data.OverpassFacilities
import com.trailmind.app.location.Fix
import com.trailmind.app.location.TrackingService
import com.trailmind.app.location.TrackingState
import com.trailmind.app.map.HikerMarker
import com.trailmind.app.map.LidarProvider
import com.trailmind.app.map.MapMarker
import com.trailmind.app.map.MercatorLine
import com.trailmind.app.map.TileMapView
import com.trailmind.app.map.TileSource
import com.trailmind.app.map.TileSources
import com.trailmind.app.map.TerrainProvider
import com.trailmind.core.format.Units
import com.trailmind.core.frontier.group.PeerTable
import com.trailmind.core.frontier.group.needsHelp
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.nav.DistanceMarks
import com.trailmind.core.stats.TrackStats
import com.trailmind.app.location.CheckIn
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Side length of a button in the map's tool capsule. */
private const val FAB_DP = 44

/** The map plus its floating controls: status chips, route guidance card, go-to target, recording bar. */
class MapScreen(private val host: MainActivity) : TileMapView.Listener {
    private val app = host.app
    private val ui = host.ui
    private val p = ui.p
    val mapView = TileMapView(host)
    val view = FrameLayout(host)
    // Places the map buttons in the gap between the top cards and the bottom bar so they never cover either.
    private val overlay = object : FrameLayout(host) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
            val gap = freeBottom() - freeTop()
            val fabs = if (fullScreenFab.visibility == View.VISIBLE) 7 else 6
            val showZoom = gap >= host.dp(fabs * FAB_DP + 12)
            if (zoomButtons.any { (it.visibility == View.VISIBLE) != showZoom }) {
                zoomButtons.forEach { it.visibility = if (showZoom) View.VISIBLE else View.GONE }
                super.onMeasure(widthMeasureSpec, heightMeasureSpec)
            }
        }

        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
            super.onLayout(changed, l, t, r, b)
            val top = freeTop()
            val y = maxOf(top, (top + freeBottom() - fabColumn.measuredHeight) / 2)
            val x = width - paddingRight - fabColumn.measuredWidth
            fabColumn.layout(x, y, x + fabColumn.measuredWidth, y + fabColumn.measuredHeight)
        }

        private fun freeTop() = paddingTop + topColumn.measuredHeight + host.dp(12)
        private fun freeBottom() = measuredHeight - paddingBottom - recordBar.measuredHeight - host.dp(12)
    }
    private val topColumn = ui.column(spacing = 8)
    // Every status chip in one wrapping row, so GPS, group, map name and any old-map fade share a line when they fit.
    private val statusRow = ui.flow(6)
    private val gpsChip = ui.chip("GPS off", glass = true) { host.push(SafetyPage(host)) }
    private val layerChip = ui.chip("Map", glass = true) { chooseLayer() }
    private val navCard = ui.glassCard(padding = 14, spacing = 6)
    private val targetCard = ui.glassCard(padding = 14, spacing = 4)
    private val recoverCard = ui.card(color = p.warnContainer, padding = 14, spacing = 8)
    // One capsule of map tools, not six separate buttons.
    private val fabColumn = ui.column(padding = 4, spacing = 2).apply {
        background = rounded(p.glass, host.dp(28).toFloat(), p.glassStroke, host.dp(1))
        elevation = host.dp(6).toFloat()
    }
    private var followFab: ImageButton
    private val orientationFab = ui.fab(R.drawable.ic_north, "North up", sizeDp = FAB_DP, flat = true) { toggleHeadingUp() }
    private var orientationState = -1
    /** Direction of travel from GPS while walking, for heading up when the compass is disturbed. */
    private var courseDeg: Float? = null
    private val fullScreenFab = ui.fab(R.drawable.ic_fullscreen, "Full-screen map", sizeDp = FAB_DP, flat = true) { host.setMapFullScreen(!host.mapFullScreen) }
    private val zoomButtons: List<View>
    // Caps the recording card at 420 dp in the wide layout without overflowing a narrower map pane.
    private val recordBar = object : FrameLayout(host) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val cap = host.dp(420)
            val w = if (wide && MeasureSpec.getSize(widthMeasureSpec) > cap) MeasureSpec.makeMeasureSpec(cap, MeasureSpec.EXACTLY) else widthMeasureSpec
            super.onMeasure(w, heightMeasureSpec)
        }
    }
    private var wide = false
    private var bottomInset = 0
    private var lastStatus = TrackingState.Status.IDLE
    private var builtStatus: TrackingState.Status? = null
    private var shownTrack: MercatorLine? = null
    private var premiumNoticeShown = false
    private var offlineAreasKey: Any? = null
    private var facilitiesRouteId = -1L
    private var facilitiesJob = 0
    private var searchPinHeightJob = 0
    private var startByKey: Any? = null
    private var startByLine: String? = null
    private val trackChip = ui.chip("Hike track  ✕", glass = true) { clearShownTrack() }.apply { visibility = View.GONE }
    private val pinChip = ui.chip("Clear search pin  ✕", glass = true) { clearSearchPin() }.apply { visibility = View.GONE }
    private val oldMapChip = ui.chip("Old map", glass = true) { chooseOldMap() }.apply {
        visibility = View.GONE
        contentDescription = "Old map settings"
    }
    private val groupChip = ui.chip("Group", glass = true) { fitGroup() }.apply {
        visibility = View.GONE
        contentDescription = "Show the trip group on the map"
    }
    private val onGroup: () -> Unit = { updateHikers() }

    private val ticker = object : Runnable {
        override fun run() {
            if (TrackingState.status == TrackingState.Status.RECORDING) updateRecordStats()
            Async.main.postDelayed(this, 1000)
        }
    }

    private val onFix: (Fix) -> Unit = { f ->
        mapView.setPosition(LatLon(f.lat, f.lon), f.accuracyM)
        courseDeg = f.location.takeIf { it.hasBearing() && it.hasSpeed() && it.speed >= 1f }?.bearing
        if (app.prefs.mapHeadingUp) updateHeading()
        host.compass.updateLocation(f.lat, f.lon, f.altitudeM ?: 0.0)
        updateGps(f)
        updateTarget()
    }
    private val onNav: () -> Unit = { updateNav(); updateTarget() }
    private val onTracking: () -> Unit = { updateTracking() }
    private val onTiles: () -> Unit = { updateHint(); updateOfflineAreas() }
    private val onHeading: () -> Unit = { updateHeading() }
    private val onPlan: (String?) -> Unit = { message ->
        if (message != null) host.toast(message)
        updatePlanner()
        app.planner.takeSaveResult()?.onSuccess { id ->
            host.showTab(MainActivity.Tab.ROUTES)
            host.push(RouteDetailPage(host, id))
        }?.onFailure { host.toast("Could not save this route.") }
    }

    init {
        mapView.listener = this
        view.addView(mapView, FrameLayout.LayoutParams(-1, -1))
        // Subtle scrim so status-bar icons stay legible over light map tiles.
        view.addView(View(host).apply {
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(0x55000000, 0x00000000))
            tag = "scrim"
        }, FrameLayout.LayoutParams(-1, host.dp(56), Gravity.TOP))
        view.addView(overlay, FrameLayout.LayoutParams(-1, -1))

        statusRow.addView(gpsChip)
        statusRow.addView(groupChip)
        statusRow.addView(layerChip)
        statusRow.addView(trackChip)
        statusRow.addView(oldMapChip)
        statusRow.addView(pinChip)
        layerChip.maxWidth = host.dp(170)
        oldMapChip.maxWidth = host.dp(230)
        topColumn.addView(statusRow)
        topColumn.addView(recoverCard)
        topColumn.addView(navCard)
        topColumn.addView(targetCard)
        overlay.addView(topColumn, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))

        fabColumn.addView(ui.fab(R.drawable.ic_search, "Search", sizeDp = FAB_DP, flat = true) { host.push(SearchPage(host)) })
        fabColumn.addView(fullScreenFab)
        fabColumn.addView(ui.fab(R.drawable.ic_layers, "Map layers", sizeDp = FAB_DP, flat = true) { chooseLayer() })
        zoomButtons = listOf(
            ui.fab(R.drawable.ic_add, "Zoom in", sizeDp = FAB_DP, flat = true) { mapView.zoomBy(1.0) },
            ui.fab(R.drawable.ic_remove, "Zoom out", sizeDp = FAB_DP, flat = true) { mapView.zoomBy(-1.0) },
        )
        zoomButtons.forEach { fabColumn.addView(it) }
        fabColumn.addView(orientationFab)
        followFab = ui.fab(R.drawable.ic_my_location, "My location", sizeDp = FAB_DP, flat = true) { locate() }
        fabColumn.addView(followFab)
        overlay.addView(fabColumn, FrameLayout.LayoutParams(-2, -2, Gravity.END or Gravity.CENTER_VERTICAL))
        overlay.addView(recordBar, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
        recordBar.addOnLayoutChangeListener { _, _, top, _, bottom, _, _, _, _ -> updateBottomChrome(bottom - top) }

        mapView.setCenter(app.prefs.mapLat, app.prefs.mapLon, app.prefs.mapZoom)
        applySource()
        updateHeading()
        // Heading up turns the map about you, so it opens on your position once there is a fix.
        if (app.prefs.mapHeadingUp) mapView.follow = true
        mapView.track = TrackingState.line
    }

    fun onStart() {
        app.location.addListener(onFix)
        app.nav.addListener(onNav)
        TrackingState.addListener(onTracking)
        app.tiles.addListener(onTiles)
        app.planner.addListener(onPlan)
        host.addHeadingListener(onHeading)
        app.group.addListener(onGroup)
        app.location.latest?.let(onFix)
        applySource()
        updateNav(); updateTarget(); updateTracking(); updateRecover(); updateHikers()
        Async.main.removeCallbacks(ticker)
        Async.main.post(ticker)
    }

    fun onStop() {
        app.location.removeListener(onFix)
        app.nav.removeListener(onNav)
        TrackingState.removeListener(onTracking)
        app.tiles.removeListener(onTiles)
        app.planner.removeListener(onPlan)
        host.removeHeadingListener(onHeading)
        app.group.removeListener(onGroup)
        Async.main.removeCallbacks(ticker)
    }

    fun saveCamera() {
        app.prefs.mapLat = mapView.centerLat
        app.prefs.mapLon = mapView.centerLon
        app.prefs.mapZoom = mapView.zoom
    }

    fun onLayoutChanged(wide: Boolean) {
        this.wide = wide
        fullScreenFab.visibility = if (wide) View.VISIBLE else View.GONE
        updateTracking(force = true)
    }

    fun onFullScreenChanged(full: Boolean) {
        fullScreenFab.setImageDrawable(host.getDrawable(if (full) R.drawable.ic_fullscreen_exit else R.drawable.ic_fullscreen)?.mutate()
            ?.apply { setTint(p.onSurface) })
        fullScreenFab.contentDescription = if (full) "Exit full-screen map" else "Full-screen map"
    }

    fun onResize() = mapView.invalidate()

    fun setInsets(left: Int, top: Int, right: Int, bottom: Int) {
        bottomInset = bottom
        overlay.setPadding(left + host.dp(12), top + host.dp(8), right + host.dp(12), bottom + host.dp(12))
        view.findViewWithTag<View>("scrim")?.layoutParams?.height = top + host.dp(24)
        updateBottomChrome(recordBar.height)
    }

    private fun updateBottomChrome(recordH: Int) {
        mapView.bottomChromePx = (bottomInset + recordH + host.dp(if (recordH > 0) 20 else 12)).toFloat()
    }

    // ---------------------------------------------------------------- camera & layers

    fun locate() {
        host.withLocationPermission {
            val f = app.location.latest
            if (f == null) {
                if (!host.isGpsEnabled()) host.ensureGpsEnabled {} else host.toast("Waiting for a GPS fix…")
            }
            mapView.follow = true
            f?.let { mapView.setCenter(it.lat, it.lon, maxOf(mapView.zoom, 14.0)) }
        }
    }

    fun fit(b: BoundingBox?) {
        if (b == null) return
        mapView.follow = false
        host.showMap()
        mapView.post { mapView.fitBounds(b) }
    }

    private fun toggleHeadingUp() {
        val on = !app.prefs.mapHeadingUp
        app.prefs.mapHeadingUp = on
        updateHeading()
        // The map turns about its centre, so centre it on you.
        if (on) locate()
        host.toast(when {
            !on -> "North up"
            host.compassDisturbed -> "Heading up. Metal or electronics nearby may upset the compass here, so the arrow is orange."
            host.compassUnreliable -> "Heading up. Move the phone in a figure of eight to calibrate the compass."
            else -> "Heading up: the map turns as you turn"
        })
    }

    /**
     * North up shows the compass on the position cone. Heading up turns the map with the compass, or with the direction
     * of walking while the compass is disturbed or uncalibrated; the cone shows the same heading and the arrow turns orange.
     */
    private fun updateHeading() {
        val on = app.prefs.mapHeadingUp
        val compass = host.headingDeg?.toFloat()
        val doubtful = host.compassDisturbed || host.compassUnreliable
        if (!on) {
            mapView.headingDeg = compass
            mapView.bearing = 0f
        } else {
            val heading = (if (doubtful) courseDeg else null) ?: compass ?: courseDeg
            mapView.headingDeg = heading
            heading?.let { mapView.bearing = it }
        }
        val state = if (!on) 0 else if (doubtful) 1 else 2
        if (state != orientationState) {
            orientationState = state
            val tint = when (state) { 0 -> p.onSurface; 1 -> p.accent; else -> p.primary }
            orientationFab.setImageDrawable(host.getDrawable(R.drawable.ic_north)?.mutate()?.apply { setTint(tint) })
            orientationFab.contentDescription = when (state) {
                0 -> "North up. Tap for heading up."
                1 -> "Heading up, but the compass may be off here. Tap for north up."
                else -> "Heading up. Tap for north up."
            }
        }
        // The arrow points to north on the screen.
        orientationFab.rotation = -mapView.bearing
    }

    fun centerOn(p: LatLon, zoom: Double = 15.0) {
        mapView.follow = false
        host.showMap()
        mapView.setCenter(p.lat, p.lon, zoom)
    }

    fun showSearchPin(name: String, position: LatLon, zoom: Double) {
        mapView.searchPin = MapMarker(position, name)
        pinChip.visibility = View.VISIBLE
        pinChip.text = "Clear search pin  ✕"
        val job = ++searchPinHeightJob
        centerOn(position, zoom)
        Async.run({ groundHeight(position) }) { result ->
            if (job != searchPinHeightJob || mapView.searchPin?.position != position) return@run
            result.getOrNull()?.let { (height, credit) ->
                pinChip.text = "$name · Height about ${Units.elevation(height, app.prefs.imperial)} · $credit · Clear search pin  ✕"
            }
        }
    }

    /** Ground height at [at] with its credit: LiDAR already on the phone first, then the terrain model. */
    private fun groundHeight(at: LatLon): Pair<Double, String>? =
        app.lidar.sample(at)?.let { it to LidarProvider.CREDIT } ?: app.terrain.sample(at)?.let { it to TerrainProvider.CREDIT }

    fun clearSearchPin() {
        searchPinHeightJob++
        mapView.searchPin = null
        pinChip.visibility = View.GONE
    }

    fun currentSource(): TileSource = TileSources.byId(app.prefs.baseSourceId, app.prefs, app.tiles.packs)

    fun setSource(id: String) {
        app.prefs.baseSourceId = id
        app.tiles.clearErrors()
        applySource()
        host.refreshRouteReadiness()
    }

    private fun applySource() {
        val s = currentSource()
        mapView.source = s
        mapView.showSteepGround = app.prefs.showSteepGround
        mapView.showLidar = app.prefs.showLidar
        mapView.hillshade = if (app.prefs.showGsiHillshade) TileSources.hillshade() else null
        layerChip.text = s.name
        applyHistoric()
        updateHint()
        updateOfflineAreas()
    }

    private fun applyHistoric() {
        val s = TileSources.historicOverlay(app.prefs)
        mapView.historic = s
        mapView.historicAlpha = app.prefs.historicOverlayPercent / 100f
        oldMapChip.visibility = if (s != null) View.VISIBLE else View.GONE
        if (s != null) oldMapChip.text = "${s.name.removePrefix(TileSources.OLD_MAP_PREFIX)} · ${app.prefs.historicOverlayPercent}%"
    }

    /** Which old map to fade over today's, and how much: all the controls for the time-travel overlay. */
    private fun chooseOldMap() {
        val layers = TileSources.historic()
        val labels = (listOf("Off: today's map only") + layers.map { it.name.removePrefix(TileSources.OLD_MAP_PREFIX) }).toTypedArray()
        val note = ui.text("", Ui.T.CAPTION)
        val percentLabel = ui.text("", Ui.T.LABEL)
        fun showNote() {
            val s = TileSources.historicOverlay(app.prefs)
            note.text = s?.let { "${it.note}\nAppears from zoom ${it.minZoom}." } ?: "Pick a map to fade over the current one."
            percentLabel.text = "Old map showing: ${app.prefs.historicOverlayPercent}%"
        }
        val bar = SeekBar(host).apply {
            max = 90
            progress = app.prefs.historicOverlayPercent - 10
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar, value: Int, fromUser: Boolean) {
                    if (!fromUser) return
                    app.prefs.historicOverlayPercent = value + 10
                    applyHistoric()
                    showNote()
                }
                override fun onStartTrackingTouch(bar: SeekBar) = Unit
                override fun onStopTrackingTouch(bar: SeekBar) = Unit
            })
        }
        val title = ui.column(padding = 20, spacing = 6) {
            addView(ui.text("Old maps", Ui.T.TITLE))
            addView(ui.text("Fade a scanned Ordnance Survey map over today's to find what has gone from the Forest of Dean: " +
                "mines and scowles, tramroads, quarries, forges and lost railways. They cover all of Great Britain.", Ui.T.CAPTION))
            if (app.prefs.mapTilerKey.isBlank()) {
                addView(ui.text("No MapTiler key yet. The maps are free to use with your own key.", Ui.T.CAPTION, p.danger))
                addView(ui.button("Add MapTiler key", null, Ui.B.TONAL) { host.push(SettingsPage(host)) })
            }
            addView(note)
            addView(percentLabel)
            addView(bar, ui.lp())
        }
        showNote()
        val current = layers.indexOfFirst { it.id == app.prefs.historicOverlayId } + 1
        ui.dialog().setCustomTitle(title)
            .setSingleChoiceItems(labels, current) { d, which ->
                if (which == 0) {
                    app.prefs.historicOverlayId = ""
                } else {
                    val s = layers[which - 1]
                    if (TileSources.missingKey(s, app.prefs)) {
                        d.dismiss()
                        askForMapTilerKey(s)
                        return@setSingleChoiceItems
                    }
                    app.prefs.historicOverlayId = s.id
                    app.tiles.clearErrors()
                }
                applyHistoric()
                updateHint()
                showNote()
            }
            .setPositiveButton("Done", null)
            .setNeutralButton("Forest of Dean") { _, _ -> showOldMap(at = LatLon(TileSources.FOREST_OF_DEAN_LAT, TileSources.FOREST_OF_DEAN_LON)) }
            .show()
    }

    private fun askForMapTilerKey(s: TileSource) {
        ui.dialog().setTitle("MapTiler key needed")
            .setMessage("${s.note}\n\nThe old maps are served by MapTiler Cloud. Create a free account, copy a key from " +
                "your account page, and paste it in Settings.")
            .setPositiveButton("Add key") { _, _ -> host.push(SettingsPage(host)) }
            .setNegativeButton("Cancel", null).show()
    }

    /**
     * Fades an old map over the current one and moves the map there: the Forest of Dean by default, or [box] (a route).
     * Uses the old map already chosen, else the six-inch, which is the one for the Forest's mines, scowles and tramroads.
     */
    fun showOldMap(box: BoundingBox? = null, at: LatLon? = null) {
        val s = TileSources.historicOverlay(app.prefs) ?: TileSources.historic().first { it.id == TileSources.NLS_SIX_INCH }
        if (TileSources.missingKey(s, app.prefs)) {
            askForMapTilerKey(s)
            return
        }
        app.prefs.historicOverlayId = s.id
        app.tiles.clearErrors()
        applyHistoric()
        updateHint()
        when {
            box != null -> fit(box)
            at != null -> centerOn(at, TileSources.FOREST_OF_DEAN_ZOOM)
            else -> host.showMap()
        }
        host.toast("${s.name.removePrefix(TileSources.OLD_MAP_PREFIX)} over today's map. Drag the slider under Map layers → Old maps to fade it.")
    }

    /** Outlines the base map's offline packs; the tile listener calls this often, so it only reloads when they change. */
    private fun updateOfflineAreas() {
        val packs = if (app.prefs.showOfflineAreas) app.tiles.packsFor(mapView.source) else emptyList()
        val key = packs.map { Triple(it.id, it.tileDone, it.status) }
        if (key == offlineAreasKey) return
        offlineAreasKey = key
        if (packs.isEmpty()) { mapView.offlineAreas = emptyList(); return }
        Async.run({ packs.mapNotNull { app.tiles.footprint(it) } }) { r ->
            if (key == offlineAreasKey) mapView.offlineAreas = r.getOrDefault(emptyList())
        }
    }

    private fun updateHint() {
        val s = mapView.source
        if (!premiumNoticeShown && app.tiles.premiumDenied(s)) {
            premiumNoticeShown = true
            host.toast("${s.name}: your OS plan does not include closer detail, so the map enlarges the last available overview tile.")
        }
        mapView.hint = when {
            TileSources.missingKey(s, app.prefs) ->
                "Add your free ${s.keyKind.label} in Settings to show this map"
            app.tiles.lastError != null && (s.isOnline || mapView.historic != null) -> app.tiles.lastError
            else -> null
        }
    }

    private fun chooseLayer() {
        val sources = TileSources.baseLayers(app.prefs, app.tiles.packs)
        val current = currentSource().id
        val labels = sources.map { s ->
            buildString {
                append(s.name)
                if (TileSources.missingKey(s, app.prefs)) append("  (needs API key)")
                val packs = app.tiles.packsFor(s).size
                if (s.packId == null && packs > 0) append("  · $packs offline pack${if (packs > 1) "s" else ""}")
            }
        }.toTypedArray()
        ui.dialog().setTitle("Map layers")
            .setSingleChoiceItems(labels, sources.indexOfFirst { it.id == current }) { d, which ->
                val s = sources[which]
                d.dismiss()
                if (TileSources.missingKey(s, app.prefs)) {
                    ui.dialog().setTitle(s.name).setMessage(s.note)
                        .setPositiveButton("Add key") { _, _ -> host.push(SettingsPage(host)) }
                        .setNegativeButton("Cancel", null).show()
                } else setSource(s.id)
            }
            .setNeutralButton("About sources") { _, _ ->
                ui.dialog().setTitle("Map sources")
                    .setMessage(TileSources.all(app.prefs, app.tiles.packs).joinToString("\n\n") { "${it.name}\n${it.note}" } +
                        "\n\n${TerrainProvider.CREDIT}\n${TerrainProvider.REQUIRED_ATTRIBUTION}" +
                        "\n\n1 m LiDAR hill shading, crags and heights for England: Environment Agency LIDAR Composite DTM, " +
                        "Open Government Licence v3.0.\n${LidarProvider.CREDIT}")
                    .setPositiveButton("OK", null)
                    .setNeutralButton("LiDAR licence") { _, _ -> host.openUrl(LidarProvider.LICENCE_URL) }
                    .show()
            }
            .setPositiveButton("Overlays") { _, _ -> chooseOverlays() }
            .setNegativeButton("Old maps") { _, _ -> chooseOldMap() }
            .show()
    }

    private fun chooseOverlays() {
        val labels = arrayOf("Steep ground (25° and steeper)", "LiDAR hill shading and crags (England)", "Hill shading (Japan, GSI)", "Offline areas")
        val checked = booleanArrayOf(app.prefs.showSteepGround, app.prefs.showLidar, app.prefs.showGsiHillshade, app.prefs.showOfflineAreas)
        // A dialog with a list cannot also show a message, so the note goes in a custom title.
        val title = ui.column(padding = 20, spacing = 4) {
            addView(ui.text("Overlays", Ui.T.TITLE))
            addView(ui.text("LiDAR shows 1 m detail of the ground in England, with crags in dark red. It loads when you zoom in close " +
                "with signal, stays on the phone, and route offline maps save it along the route. " +
                "Japan's hill shading comes from GSI; download it from Offline maps to see it without signal.", Ui.T.CAPTION))
        }
        ui.dialog().setCustomTitle(title)
            .setMultiChoiceItems(labels, checked) { _, which, on ->
                when (which) {
                    0 -> { app.prefs.showSteepGround = on; mapView.showSteepGround = on }
                    1 -> { app.prefs.showLidar = on; mapView.showLidar = on }
                    2 -> { app.prefs.showGsiHillshade = on; mapView.hillshade = if (on) TileSources.hillshade() else null }
                    else -> { app.prefs.showOfflineAreas = on; updateOfflineAreas() }
                }
            }
            .setPositiveButton("Done", null)
            .show()
    }

    /** Turns on LiDAR shading, for places a route check points to. */
    fun showLidarLayer() {
        app.prefs.showLidar = true
        mapView.showLidar = true
    }

    // ---------------------------------------------------------------- TileMapView.Listener

    override fun onFollowChanged(follow: Boolean) {
        followFab.setImageDrawable(host.getDrawable(if (follow) R.drawable.ic_navigation else R.drawable.ic_my_location)?.mutate()
            ?.apply { setTint(if (follow) p.primary else p.onSurface) })
    }

    override fun onLongPress(at: LatLon) {
        val grid = OsGrid.fromWgs84(at)?.format(8)
        val items = arrayOf("Plan a route from here", "Go to here (bearing & distance)", "Copy position", "Offline map of this area…")
        // A dialog with a list cannot also show a message, so the height goes in a custom title.
        val heightText = ui.text("", Ui.T.CAPTION).apply { visibility = View.GONE }
        val title = ui.column(padding = 20, spacing = 2) {
            addView(ui.text(grid ?: Units.latLon(at.lat, at.lon), Ui.T.TITLE))
            addView(heightText)
        }
        val dialog = ui.dialog().setCustomTitle(title)
            .setItems(items) { _, which ->
                when (which) {
                    0 -> startPlan(at)
                    1 -> app.nav.setTarget(at)
                    2 -> host.copy("Position", listOfNotNull(grid, Units.latLon(at.lat, at.lon)).joinToString(" · "))
                    3 -> { mapView.setCenter(at.lat, at.lon, maxOf(mapView.zoom, 12.0)); host.showTab(MainActivity.Tab.OFFLINE) }
                }
            }.create()
        dialog.show()
        Async.run({ groundHeight(at) }) { result ->
            result.getOrNull()?.let { (height, credit) ->
                heightText.text = "Height about ${Units.elevation(height, app.prefs.imperial)}\n$credit"
                heightText.visibility = View.VISIBLE
            }
        }
    }

    override fun onSingleTap(at: LatLon) {
        if (app.planner.active) app.planner.add(at)
        else mapView.hikerNear(at)?.let { showMember(it.memberId) }
    }

    // ---------------------------------------------------------------- trip group

    private fun updateHikers() {
        val sharing = app.group
        if (sharing.group == null || !app.prefs.groupShowOnMap || !app.prefs.frontierEnabled) {
            if (mapView.hikers.isNotEmpty()) mapView.hikers = emptyList()
            groupChip.visibility = View.GONE
            return
        }
        val nowS = sharing.nowS()
        val peers = sharing.members
        val markers = peers.mapNotNull { peer ->
            val pos = peer.position ?: return@mapNotNull null
            val name = sharing.nameOf(peer)
            val age = when (PeerTable.freshness(pos, nowS)) {
                PeerTable.Freshness.FRESH -> HikerMarker.Age.FRESH
                PeerTable.Freshness.STALE -> HikerMarker.Age.STALE
                PeerTable.Freshness.LAST_SEEN -> HikerMarker.Age.LAST_SEEN
            }
            val label = if (age == HikerMarker.Age.FRESH) name else "$name · ${groupAge(nowS - pos.originTimeS)}"
            HikerMarker(peer.memberId, LatLon(pos.lat, pos.lon), groupInitials(name), label, sharing.colourOf(peer), age,
                relayed = pos.hops > 0, help = pos.status.needsHelp)
        }
        if (markers != mapView.hikers) mapView.hikers = markers
        // Setting a TextView's text, even to the same value, announces a change to accessibility services.
        val chip = sharing.summary() ?: "Group"
        if (groupChip.text.toString() != chip) groupChip.text = chip
        groupChip.visibility = View.VISIBLE
    }

    /** Fits everyone in the group seen in the last 15 minutes, and you, on the map. */
    private fun fitGroup() {
        val nowS = app.group.nowS()
        val points = app.group.members.mapNotNull { peer ->
            peer.position?.takeIf { PeerTable.freshness(it, nowS) != PeerTable.Freshness.LAST_SEEN }?.let { LatLon(it.lat, it.lon) }
        } + listOfNotNull(app.location.latest?.let { LatLon(it.lat, it.lon) })
        when {
            points.isEmpty() -> host.toast("No one in the group has been heard in the last 15 minutes.")
            points.size == 1 -> centerOn(points.single(), maxOf(mapView.zoom, 15.0))
            else -> fit(BoundingBox.of(points)?.expandedByMetres(150.0))
        }
    }

    fun showMember(memberId: Int) {
        app.group.members.firstOrNull { it.memberId == memberId }?.let { showGroupMember(host, it) }
    }

    /** Centres a member (from their call-for-help notification); the group may still be loading at app start. */
    fun focusMember(memberId: Int, attempt: Int = 0) {
        val pos = app.group.members.firstOrNull { it.memberId == memberId }?.position
        if (pos == null) {
            if (attempt < 5) Async.main.postDelayed({ focusMember(memberId, attempt + 1) }, 600)
            return
        }
        centerOn(LatLon(pos.lat, pos.lon), maxOf(mapView.zoom, 15.0))
        showMember(memberId)
    }

    override fun onAttributionTap() {
        val s = currentSource()
        val credits = listOfNotNull(
            s.attribution,
            mapView.historic?.let { "${it.attribution}\n${TileSources.NLS_MAPS_URL}\nScanned and georeferenced: features may sit a little off their true position." },
            OverpassFacilities.ATTRIBUTION.takeIf { mapView.facilities.isNotEmpty() },
            TerrainProvider.CREDIT.takeIf { app.prefs.showSteepGround },
            LidarProvider.CREDIT.takeIf { app.prefs.showLidar },
            "Hill shading (Japan): ${TileSources.GSI_ATTRIBUTION}".takeIf { app.prefs.showGsiHillshade && s.attribution != TileSources.GSI_ATTRIBUTION },
        ).joinToString("\n\n")
        val dialog = ui.dialog().setTitle("Map data").setMessage(credits).setNegativeButton("Close", null)
        when {
            s.showsOsLogo -> dialog.setPositiveButton("OS terms") { _, _ -> host.openUrl(TileSources.OS_TERMS_URL) }
                .setNeutralButton("Report an error") { _, _ -> host.openUrl(TileSources.OS_ERRORS_URL) }
            s.id == TileSources.OSM -> dialog.setPositiveButton("Licence") { _, _ -> host.openUrl(TileSources.OSM_COPYRIGHT_URL) }
                .setNeutralButton("Report a map issue") { _, _ -> host.openUrl(TileSources.OSM_FIX_THE_MAP_URL) }
            s.attribution == TileSources.GSI_ATTRIBUTION || app.prefs.showGsiHillshade ->
                dialog.setPositiveButton("GSI tiles") { _, _ -> host.openUrl(TileSources.GSI_TILES_URL) }
            mapView.historic != null ->
                dialog.setPositiveButton("National Library of Scotland") { _, _ -> host.openUrl(TileSources.NLS_MAPS_URL) }
                    .setNeutralButton("MapTiler") { _, _ -> host.openUrl(TileSources.MAPTILER_COPYRIGHT_URL) }
        }
        dialog.show()
    }

    fun startPlan(at: LatLon? = null) {
        mapView.flushPendingTaps()
        if (app.planner.active && app.planner.plan.controlPoints.isNotEmpty()) {
            ui.confirm("Start a new plan?", "The unsaved plan will be discarded.", "Discard", danger = true) {
                app.planner.start(at)
                host.showMap()
            }
        } else {
            app.planner.start(at)
            host.showMap()
        }
    }

    private fun updatePlanner() {
        val planner = app.planner
        mapView.plannedLegs = if (planner.active) planner.plan.legs.flatMap { leg ->
            leg.parts.map { part -> MercatorLine.of(part.points.map { it.latLon() }) to part.snapped }
        } else emptyList()
        mapView.planControls = if (planner.active) planner.plan.controlPoints else emptyList()
        updateTracking(force = true)
    }

    fun refreshPlannerDisplay() {
        if (app.planner.active) updatePlanner()
    }

    private fun plannerCard() {
        val planner = app.planner
        val points = planner.plan.controlPoints
        val est = planner.plan.estimate(app.prefs.pace)
        val summary = TrackStats.summarize(planner.plan.line)
        val card = ui.glassCard(padding = 12, spacing = 6)
        card.addView(ui.row {
            addView(ui.text("Plan a route", Ui.T.TITLE), ui.lp(0, weight = 1f))
            addView(miniIcon(R.drawable.ic_close, "Close planner") { closePlanner() })
        })
        card.addView(ui.row(spacing = 8) {
            addView(ui.stat("Distance", Units.distance(summary.distanceM, app.prefs.imperial)), ui.lp(0, weight = 1f))
            addView(ui.stat("Ascent", Units.elevation(summary.ascentM, app.prefs.imperial)), ui.lp(0, weight = 1f))
            addView(ui.stat("Time", Units.minutes(est.planningMinutes)), ui.lp(0, weight = 1f))
        })
        card.addView(ui.switch("Snap to paths", planner.snap) { mapView.flushPendingTaps(); planner.snap = it; updatePlanner() })
        card.addView(ui.flow(spacing = 4) {
            addView(ui.button("Undo", R.drawable.ic_remove, Ui.B.TONAL) { mapView.flushPendingTaps(); planner.undo() }.apply { isEnabled = points.isNotEmpty() })
            addView(ui.button("Clear", R.drawable.ic_delete, Ui.B.TONAL) { mapView.flushPendingTaps(); planner.clear() }.apply { isEnabled = points.isNotEmpty() })
            addView(ui.button("Back to start", R.drawable.ic_route, Ui.B.TONAL) { mapView.flushPendingTaps(); planner.backToStart() }.apply {
                isEnabled = points.size >= 2 && !planner.plan.isLoop && !planner.pending
            })
            addView(ui.button("Save", R.drawable.ic_folder) { savePlan() }.apply { isEnabled = points.size >= 2 && !planner.pending && !planner.saving })
        })
        card.addView(ui.text(if (planner.pending) "Finding a path…" else if (points.isEmpty()) "Tap the map to add a start point." else if (points.size == 1) "1 point" else "${points.size} points", Ui.T.CAPTION))
        planner.notice?.let { card.addView(ui.text(it, Ui.T.CAPTION)) }
        card.addView(ui.text("Routing: BRouter, © OpenStreetMap contributors", Ui.T.CAPTION))
        recordBar.addView(card, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
    }

    private fun closePlanner() {
        mapView.flushPendingTaps()
        if (app.planner.plan.controlPoints.isEmpty()) app.planner.close()
        else ui.confirm("Discard this plan?", "The unsaved points will be lost.", "Discard", danger = true) { app.planner.close() }
    }

    private fun savePlan() {
        mapView.flushPendingTaps()
        if (app.planner.saving || app.planner.pending || app.planner.plan.legs.isEmpty()) return
        val name = SimpleDateFormat("'Walk' d MMM", Locale.UK).format(Date())
        val input = ui.input("Route name", name)
        val box = FrameLayout(host).apply {
            setPadding(host.dp(20), host.dp(8), host.dp(20), 0)
            addView(input)
        }
        val dialog = ui.dialog().setTitle("Save route").setView(box)
            .setPositiveButton("Save", null).setNegativeButton("Cancel", null).create()
        dialog.setOnShowListener {
            dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE).setOnClickListener {
                val title = input.text.toString().trim()
                if (title.isEmpty()) { input.error = "Give the walk a name."; return@setOnClickListener }
                if (!app.planner.active || app.planner.pending || app.planner.plan.legs.isEmpty()) return@setOnClickListener
                dialog.dismiss()
                app.planner.save(title)
            }
        }
        dialog.show()
    }

    // ---------------------------------------------------------------- overlays

    // What each overlay last showed: GPS fixes arrive every second, and rebuilding identical views
    // wastes battery and keeps the UI from ever going idle.
    private var navShown: String? = null
    private var targetShown: String? = null
    private var statsShown: String? = null
    private var waypointsRouteId = Long.MIN_VALUE
    private var distanceMarksKey: Any? = null

    private fun updateGps(f: Fix?) {
        val text = if (f == null) {
            if (host.hasLocationPermission()) "Finding GPS…" else "Location off"
        } else {
            val grid = OsGrid.fromWgs84(LatLon(f.lat, f.lon))?.format(6)
            listOfNotNull(grid ?: Units.latLon(f.lat, f.lon), "±" + Units.distance(f.accuracyM.toDouble(), app.prefs.imperial)).joinToString(" · ")
        }
        if (gpsChip.text.toString() != text) gpsChip.text = text
    }

    private fun updateNav() {
        val route = app.nav.active
        mapView.route = route?.line
        val routeId = route?.data?.meta?.id ?: -1L
        if (routeId != facilitiesRouteId) {
            facilitiesRouteId = routeId
            updateFacilities()
        }
        if (routeId != waypointsRouteId) {
            waypointsRouteId = routeId
            mapView.waypoints = route?.data?.waypoints?.map { MapMarker(it.latLon(), it.name) } ?: emptyList()
        }
        val marksKey = route?.let { it to app.prefs.imperial }
        if (marksKey != distanceMarksKey) {
            distanceMarksKey = marksKey
            mapView.distanceStepM = DistanceMarks.stepM(app.prefs.imperial)
            mapView.distanceMarks = route?.let { DistanceMarks.along(it.guide, mapView.distanceStepM) } ?: emptyList()
        }
        if (route == null) {
            navShown = null
            if (navCard.childCount > 0) navCard.removeAllViews()
            navCard.visibility = View.GONE
            return
        }
        val imperial = app.prefs.imperial
        val fix = app.nav.fix
        val offRoute = app.nav.offRoute
        val waiting = if (fix == null) "${Units.distance(route.guide.totalM, imperial)} · planning time ${Units.minutes(route.estimate.planningMinutes)} · waiting for GPS" else null
        val stats = fix?.let { rf ->
            listOf(Units.distance(rf.remainingM, imperial), app.nav.remainingMinutes?.let { Units.minutes(it) } ?: "—",
                "↑" + Units.elevation(rf.remainingAscentM, imperial), "${(rf.progress * 100).toInt()}%")
        }
        val status = when {
            fix == null -> null
            offRoute -> {
                val back = app.nav.lastFix?.let { Geo.bearingDeg(LatLon(it.lat, it.lon), fix.snapped) }
                "Off route by ${Units.distance(fix.offRouteM, imperial)}" + (back?.let { " – route is ${Units.bearing(it)} ${Geo.cardinal(it)}" } ?: "")
            }
            fix.atEnd -> "You have reached the end of the route."
            else -> null
        }
        val next = fix?.nextWaypoint?.let { w -> "Next: ${w.waypoint.name} in ${Units.distance(w.alongRouteM, imperial)} (${Units.bearing(w.bearingDeg)})" }
        val daylight = app.nav.daylight
        val sunset = app.nav.daylightSun?.sunsetMs
        val daylightLine = if (fix != null && !app.nav.routeStarted) {
            val now = System.currentTimeMillis()
            val key = Triple(route, app.prefs.pace, app.prefs.daylightMarginMinutes to now / 60_000L)
            if (key != startByKey) {
                startByKey = key
                startByLine = startByText(host, route.data.points, app.prefs.pace, app.prefs.daylightMarginMinutes, now)
            }
            startByLine
        }
        else if (fix != null && daylight?.darkNow == true)
            "It's dark now. " + (daylight.nextSunriseMs?.let { "Sunrise ${finishTime(host, it)}" } ?: "No sunrise time available.")
        else if (fix != null && daylight != null && sunset == null)
            if (daylight.darkNow == false) "No sunset today at this location." else "Daylight times unavailable here."
        else if (fix != null && daylight != null && sunset != null)
            if (daylight.afterSafeSunset == true && daylight.finishMs > sunset)
                "Finish ≈ ${finishTime(host, daylight.finishMs)}, after sunset (${clockTime(host, sunset)})"
            else if (daylight.afterSafeSunset == true)
                "Finish ≈ ${finishTime(host, daylight.finishMs)}, inside ${app.prefs.daylightMarginMinutes} min sunset margin (${clockTime(host, sunset)})"
            else "Finish ≈ ${finishTime(host, daylight.finishMs)} · sunset ${clockTime(host, sunset)}"
        else null
        val shown = listOf(routeId, route.data.meta.name, offRoute, waiting, stats, status, next, daylightLine).joinToString("|")
        if (shown == navShown) return
        navShown = shown
        navCard.removeAllViews()
        navCard.visibility = View.VISIBLE
        navCard.background = rounded(if (offRoute) p.dangerContainer else p.surface, host.dp(20).toFloat(), p.outline, host.dp(1))
        navCard.addView(ui.row(spacing = 8) {
            addView(ui.text("Following", Ui.T.LABEL, p.primary))
            addView(ui.text(route.data.meta.name, Ui.T.TITLE).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }, ui.lp(0, weight = 1f))
            addView(miniIcon(R.drawable.ic_close, "Stop following") {
                ui.confirm("Stop following?", "The route will be removed from the map.", "Stop") { app.nav.stopFollowing() }
            })
        })
        if (waiting != null) { navCard.addView(ui.text(waiting, Ui.T.CAPTION)); return }
        if (stats != null) navCard.addView(ui.row(spacing = 12) {
            listOf("To go", "Time", "Climb", "Done").forEachIndexed { i, label -> addView(ui.stat(label, stats[i]), ui.lp(0, weight = 1f)) }
        })
        status?.let { navCard.addView(if (offRoute) ui.text(it, Ui.T.TITLE, p.danger) else ui.text(it, Ui.T.CAPTION)) }
        next?.let { navCard.addView(ui.text(it, Ui.T.CAPTION)) }
        if (daylightLine != null) {
            navCard.addView(ui.text(daylightLine, Ui.T.CAPTION, if (app.nav.routeStarted && daylight?.afterSafeSunset == true) p.danger else p.onSurface).apply {
                setOnClickListener {
                    if (daylight == null || sunset == null) return@setOnClickListener
                    val margin = app.prefs.daylightMarginMinutes
                    val back = daylight.walkBackMinutes?.let { "Going back to the start now takes about ${Units.minutes(it)}.\n" } ?: ""
                    val turn = daylight.turnBackByMs?.let {
                        "Turn back by ${finishTime(host, it)} to be down before sunset with $margin min to spare.\n"
                    } ?: ""
                    val dusk = app.nav.daylightSun?.civilDuskMs?.let { "Civil dusk (dark by) ${finishTime(host, it)}.\n" } ?: ""
                    val left = if (daylight.darkNow == true) "It's dark now" else
                        daylight.daylightLeftMs?.takeIf { it > 0 }?.let { "${Units.duration(it)} of daylight left" } ?: "Sunset has passed"
                    ui.dialog().setTitle("Daylight check").setMessage(
                        "Estimated finish ${finishTime(host, daylight.finishMs)}. Sunset ${clockTime(host, sunset)}; " +
                            "$left.\n" +
                            back + turn + dusk + "Estimate uses route climb, your pace and conditions; allow extra for breaks and poor weather."
                    ).setPositiveButton("OK", null).show()
                }
            })
        }
    }

    fun updateFacilities() {
        val routeId = facilitiesRouteId
        val job = ++facilitiesJob
        mapView.facilities = emptyList()
        if (routeId < 0 || !app.prefs.showFacilities) return
        Async.run({ OverpassFacilities.saved(host, routeId)?.items.orEmpty() }) { result ->
            if (job == facilitiesJob && routeId == facilitiesRouteId && app.prefs.showFacilities) {
                mapView.facilities = result.getOrDefault(emptyList())
            }
        }
    }

    private fun updateTarget() {
        val t = app.nav.target
        mapView.target = t
        if (t == null) {
            targetShown = null
            if (targetCard.childCount > 0) targetCard.removeAllViews()
            targetCard.visibility = View.GONE
            return
        }
        val f = app.nav.lastFix
        val grid = OsGrid.fromWgs84(t)?.format(8) ?: Units.latLon(t.lat, t.lon)
        val detail = if (f != null) {
            val here = LatLon(f.lat, f.lon)
            val b = Geo.bearingDeg(here, t)
            "${Units.distance(Geo.distanceM(here, t), app.prefs.imperial)} · ${Units.bearing(b)} ${Geo.cardinal(b)} (straight line, not a path)"
        } else "Waiting for GPS to give bearing and distance"
        if ("$grid|$detail" == targetShown) return
        targetShown = "$grid|$detail"
        targetCard.removeAllViews()
        targetCard.visibility = View.VISIBLE
        targetCard.addView(ui.row(spacing = 8) {
            addView(ui.text("Go to", Ui.T.LABEL, p.accent))
            addView(ui.text(grid, Ui.T.TITLE), ui.lp(0, weight = 1f))
            addView(miniIcon(R.drawable.ic_close, "Clear target") { app.nav.setTarget(null) })
        })
        targetCard.addView(ui.text(detail, Ui.T.CAPTION))
    }

    private fun updateRecover() {
        recoverCard.removeAllViews()
        recoverCard.visibility = View.GONE
        if (TrackingState.status != TrackingState.Status.IDLE || TrackingService.running) return
        Async.run({ app.db.unfinishedHike() }) { r ->
            val h = r.getOrNull() ?: return@run
            if (TrackingState.status != TrackingState.Status.IDLE || TrackingService.running) return@run
            recoverCard.removeAllViews()
            recoverCard.visibility = View.VISIBLE
            recoverCard.addView(ui.text("Unfinished recording: ${h.name}", Ui.T.TITLE))
            recoverCard.addView(ui.text(if (h.status == HikeStatus.PAUSED) "Recording was paused or interrupted." else "The app was closed while recording.", Ui.T.CAPTION))
            recoverCard.addView(ui.row {
                addView(ui.button("Resume", R.drawable.ic_play, Ui.B.FILLED) {
                    host.withLocationPermission { TrackingService.resumeHike(host, h.id); recoverCard.visibility = View.GONE }
                })
                addView(ui.button("Finish", R.drawable.ic_stop, Ui.B.TONAL) {
                    Async.run({ app.db.finalizeHike(h.id, System.currentTimeMillis(), null) }) { res ->
                        recoverCard.visibility = View.GONE
                        res.getOrNull()?.let {
                            app.strava.onHikeFinished(it.id)
                            host.showTab(MainActivity.Tab.HIKES); host.push(HikeDetailPage(host, it.id))
                        }
                    }
                })
            })
        }
    }

    /** Shows a recorded hike's breadcrumb trail (when not recording). */
    fun showTrack(segments: List<List<TrackPoint>>) {
        if (TrackingState.status != TrackingState.Status.IDLE) return
        shownTrack = MercatorLine().apply { segments.forEach { seg -> breakHere(); seg.forEach { add(it.latLon()) } } }
        mapView.track = shownTrack
        trackChip.visibility = View.VISIBLE
    }

    private fun clearShownTrack() {
        if (shownTrack == null) return
        shownTrack = null
        trackChip.visibility = View.GONE
        mapView.track = TrackingState.line
    }

    private fun updateTracking(force: Boolean = false) {
        val status = TrackingState.status
        if (lastStatus != TrackingState.Status.IDLE && status == TrackingState.Status.IDLE) {
            TrackingService.finishedHikeId?.let { id ->
                TrackingService.finishedHikeId = null
                host.showTab(MainActivity.Tab.HIKES)
                host.push(HikeDetailPage(host, id))
            }
        }
        lastStatus = status
        if (status != TrackingState.Status.IDLE) clearShownTrack()
        mapView.track = shownTrack ?: TrackingState.line
        mapView.invalidate()
        if (app.planner.active) {
            recordBar.removeAllViews()
            plannerCard()
            return
        }
        if (status == builtStatus && !force) { updateRecordStats(); return }
        builtStatus = status
        if (status != TrackingState.Status.IDLE) recoverCard.visibility = View.GONE
        recordBar.removeAllViews()
        when (status) {
            TrackingState.Status.IDLE -> {
                val start = ui.button("Start hike", R.drawable.ic_play, Ui.B.FILLED) { startRecording() }
                start.elevation = host.dp(8).toFloat()
                start.setPadding(host.dp(26), host.dp(10), host.dp(28), host.dp(10))
                recordBar.addView(start, FrameLayout.LayoutParams(-2, host.dp(56), Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM))
            }
            else -> {
                val card = ui.glassCard(padding = 12, spacing = 0)
                val row = ui.row(spacing = 12) {
                    addView(ui.row(spacing = 14) {
                        tag = "stats"
                    }, ui.lp(0, weight = 1f))
                    val paused = status == TrackingState.Status.PAUSED
                    addView(ui.fab(if (paused) R.drawable.ic_play else R.drawable.ic_pause, if (paused) "Resume" else "Pause",
                        bg = p.primaryContainer, fg = p.onPrimaryContainer) {
                        TrackingService.send(host, if (paused) TrackingService.ACTION_RESUME else TrackingService.ACTION_PAUSE)
                    })
                    addView(ui.fab(R.drawable.ic_stop, "Finish", bg = p.danger, fg = Color.WHITE) { confirmFinish() })
                }
                card.addView(row)
                // Check-in controls as small chips on one line, so the recording card stays short and the map stays visible.
                val due = app.prefs.checkInDueMs
                card.addView(ui.flow(6) {
                    setPadding(0, host.dp(8), 0, 0)
                    addView(ui.chip(if (due > 0) "Check-in ${clockTime(host, due)} · Edit" else "Set check-in") {
                        val route = app.nav.active?.data
                        val minutes = route?.let { com.trailmind.core.stats.HikeEstimator.estimate(it.points, app.prefs.pace).planningMinutes } ?: 60.0
                        pickCheckIn(host, route?.meta?.name ?: TrackingState.hikeName, minutes, route?.meta?.id ?: 0L) { updateTracking(force = true) }
                    })
                    if (due > 0) addView(ui.chip("Cancel check-in  ✕") {
                        CheckIn.clear(host); updateTracking(force = true)
                    })
                })
                recordBar.addView(card, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
                updateRecordStats()
            }
        }
    }

    private fun updateRecordStats() {
        val stats = recordBar.findViewWithTag<LinearLayout>("stats") ?: return
        val imperial = app.prefs.imperial
        val paused = TrackingState.status == TrackingState.Status.PAUSED
        val values = listOf(if (paused) "Paused" else "Time", Units.duration(TrackingState.activeMs()),
            Units.distance(TrackingState.distanceM, imperial), "↑" + Units.elevation(TrackingState.ascentM, imperial))
        val shown = values.joinToString("|")
        if (shown == statsShown && stats.childCount > 0) return
        statsShown = shown
        stats.removeAllViews()
        stats.addView(ui.stat(values[0], values[1]), ui.lp(0, weight = 1f))
        stats.addView(ui.stat("Distance", values[2]), ui.lp(0, weight = 1f))
        stats.addView(ui.stat("Ascent", values[3]), ui.lp(0, weight = 1f))
    }

    private fun startRecording() {
        host.withLocationPermission {
            host.ensureGpsEnabled {
                host.requestNotificationPermissionIfNeeded()
                TrackingService.start(host)
                if (app.prefs.checkInDueMs <= 0) {
                    val route = app.nav.active?.data
                    val minutes = route?.let { com.trailmind.core.stats.HikeEstimator.estimate(it.points, app.prefs.pace).planningMinutes } ?: 60.0
                    pickCheckIn(host, route?.meta?.name ?: "my walk", minutes, route?.meta?.id ?: 0L) { updateTracking(force = true) }
                }
                if (app.location.latest != null) mapView.follow = true
                host.toast("Recording. Tracking continues with the screen off; keep TrailMind exempt from battery optimisation for long hikes.")
            }
        }
    }

    private fun confirmFinish() {
        ui.dialog().setTitle("Finish hike?")
            .setMessage("Recording stops and the hike is saved. You can export it as GPX afterwards.")
            .setPositiveButton("Finish") { _, _ -> TrackingService.send(host, TrackingService.ACTION_STOP) }
            .setNegativeButton("Keep recording", null).show()
    }

    private fun miniIcon(icon: Int, desc: String, onClick: () -> Unit) = ImageButton(host).apply {
        setImageDrawable(host.getDrawable(icon)?.mutate()?.apply { setTint(p.muted) })
        contentDescription = desc
        background = ripple(null, 0x22000000, GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) })
        layoutParams = LinearLayout.LayoutParams(host.dp(36), host.dp(36))
        setOnClickListener { onClick() }
    }
}
