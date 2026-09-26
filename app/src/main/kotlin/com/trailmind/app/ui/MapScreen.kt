package com.trailmind.app.ui

import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.data.HikeStatus
import com.trailmind.app.location.Fix
import com.trailmind.app.location.TrackingService
import com.trailmind.app.location.TrackingState
import com.trailmind.app.map.MapMarker
import com.trailmind.app.map.MercatorLine
import com.trailmind.app.map.TileMapView
import com.trailmind.app.map.TileSource
import com.trailmind.app.map.TileSources
import com.trailmind.core.format.Units
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.nav.DistanceMarks

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
            val fabs = if (fullScreenFab.visibility == View.VISIBLE) 5 else 4
            val showZoom = gap >= host.dp(fabs * 48 + (fabs - 1) * 10)
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
    private val statusRow = ui.row(spacing = 8)
    private val gpsChip = ui.chip("GPS off") { host.push(SafetyPage(host)) }
    private val layerChip = ui.chip("Map") { chooseLayer() }
    private val navCard = ui.card(padding = 14, spacing = 6)
    private val targetCard = ui.card(padding = 14, spacing = 4)
    private val recoverCard = ui.card(color = p.warnContainer, padding = 14, spacing = 8)
    private val fabColumn = ui.column(spacing = 10)
    private var followFab: ImageButton
    private val fullScreenFab = ui.fab(R.drawable.ic_fullscreen, "Full-screen map") { host.setMapFullScreen(!host.mapFullScreen) }
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
    private val trackChip = ui.chip("Hike track  ✕") { clearShownTrack() }.apply { visibility = View.GONE }

    private val ticker = object : Runnable {
        override fun run() {
            if (TrackingState.status == TrackingState.Status.RECORDING) updateRecordStats()
            Async.main.postDelayed(this, 1000)
        }
    }

    private val onFix: (Fix) -> Unit = { f ->
        mapView.setPosition(LatLon(f.lat, f.lon), f.accuracyM)
        host.compass.updateLocation(f.lat, f.lon, f.altitudeM ?: 0.0)
        updateGps(f)
        updateTarget()
    }
    private val onNav: () -> Unit = { updateNav(); updateTarget() }
    private val onTracking: () -> Unit = { updateTracking() }
    private val onTiles: () -> Unit = { updateHint() }
    private val onHeading: () -> Unit = { mapView.headingDeg = host.headingDeg?.toFloat() }

    init {
        mapView.listener = this
        view.addView(mapView, FrameLayout.LayoutParams(-1, -1))
        // Subtle scrim so status-bar icons stay legible over light map tiles.
        view.addView(View(host).apply {
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(0x55000000, 0x00000000))
            tag = "scrim"
        }, FrameLayout.LayoutParams(-1, host.dp(56), Gravity.TOP))
        view.addView(overlay, FrameLayout.LayoutParams(-1, -1))

        statusRow.addView(gpsChip, ui.lp(-2))
        statusRow.addView(View(host), ui.lp(0, 1, 1f))
        statusRow.addView(trackChip, ui.lp(-2))
        statusRow.addView(layerChip, ui.lp(-2))
        layerChip.maxWidth = host.dp(200)
        topColumn.addView(statusRow)
        topColumn.addView(recoverCard)
        topColumn.addView(navCard)
        topColumn.addView(targetCard)
        overlay.addView(topColumn, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))

        fabColumn.addView(fullScreenFab)
        fabColumn.addView(ui.fab(R.drawable.ic_layers, "Map layers") { chooseLayer() })
        zoomButtons = listOf(
            ui.fab(R.drawable.ic_add, "Zoom in") { mapView.zoomBy(1.0) },
            ui.fab(R.drawable.ic_remove, "Zoom out") { mapView.zoomBy(-1.0) },
        )
        zoomButtons.forEach { fabColumn.addView(it) }
        followFab = ui.fab(R.drawable.ic_my_location, "My location") { locate() }
        fabColumn.addView(followFab)
        overlay.addView(fabColumn, FrameLayout.LayoutParams(-2, -2, Gravity.END or Gravity.CENTER_VERTICAL))
        overlay.addView(recordBar, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
        recordBar.addOnLayoutChangeListener { _, _, top, _, bottom, _, _, _, _ -> updateBottomChrome(bottom - top) }

        mapView.setCenter(app.prefs.mapLat, app.prefs.mapLon, app.prefs.mapZoom)
        applySource()
        mapView.track = TrackingState.line
    }

    fun onStart() {
        app.location.addListener(onFix)
        app.nav.addListener(onNav)
        TrackingState.addListener(onTracking)
        app.tiles.addListener(onTiles)
        host.addHeadingListener(onHeading)
        app.location.latest?.let(onFix)
        applySource()
        updateNav(); updateTarget(); updateTracking(); updateRecover()
        Async.main.removeCallbacks(ticker)
        Async.main.post(ticker)
    }

    fun onStop() {
        app.location.removeListener(onFix)
        app.nav.removeListener(onNav)
        TrackingState.removeListener(onTracking)
        app.tiles.removeListener(onTiles)
        host.removeHeadingListener(onHeading)
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

    fun centerOn(p: LatLon, zoom: Double = 15.0) {
        mapView.follow = false
        host.showMap()
        mapView.setCenter(p.lat, p.lon, zoom)
    }

    fun currentSource(): TileSource = TileSources.byId(app.prefs.baseSourceId, app.prefs, app.tiles.packs)

    fun setSource(id: String) {
        app.prefs.baseSourceId = id
        app.tiles.clearErrors()
        applySource()
    }

    private fun applySource() {
        val s = currentSource()
        mapView.source = s
        layerChip.text = s.name
        updateHint()
    }

    private fun updateHint() {
        val s = mapView.source
        if (!premiumNoticeShown && app.tiles.premiumDenied(s)) {
            premiumNoticeShown = true
            host.toast("Zoom 17+ is OS Premium data. Your OS plan is the free OpenData plan, so the map shows zoom 16 enlarged.")
        }
        mapView.hint = when {
            s.requiresKey && app.prefs.osApiKey.isBlank() ->
                "Add your free OS Data Hub API key in Settings to show OS maps"
            app.tiles.lastError != null && s.isOnline -> app.tiles.lastError
            else -> null
        }
    }

    private fun chooseLayer() {
        val sources = TileSources.all(app.prefs, app.tiles.packs)
        val current = currentSource().id
        val labels = sources.map { s ->
            buildString {
                append(s.name)
                if (s.requiresKey && app.prefs.osApiKey.isBlank()) append("  (needs API key)")
                val packs = app.tiles.packsFor(s).size
                if (s.packId == null && packs > 0) append("  · $packs offline pack${if (packs > 1) "s" else ""}")
            }
        }.toTypedArray()
        ui.dialog().setTitle("Base map")
            .setSingleChoiceItems(labels, sources.indexOfFirst { it.id == current }) { d, which ->
                val s = sources[which]
                d.dismiss()
                if (s.requiresKey && app.prefs.osApiKey.isBlank()) {
                    ui.dialog().setTitle(s.name).setMessage(s.note)
                        .setPositiveButton("Add key") { _, _ -> host.push(SettingsPage(host)) }
                        .setNegativeButton("Cancel", null).show()
                } else setSource(s.id)
            }
            .setNeutralButton("About sources") { _, _ ->
                ui.dialog().setTitle("Map sources")
                    .setMessage(TileSources.all(app.prefs, app.tiles.packs).joinToString("\n\n") { "${it.name}\n${it.note}" })
                    .setPositiveButton("OK", null).show()
            }
            .setNegativeButton("Close", null)
            .show()
    }

    // ---------------------------------------------------------------- TileMapView.Listener

    override fun onFollowChanged(follow: Boolean) {
        followFab.setImageDrawable(host.getDrawable(if (follow) R.drawable.ic_navigation else R.drawable.ic_my_location)?.mutate()
            ?.apply { setTint(if (follow) p.primary else p.onSurface) })
    }

    override fun onLongPress(at: LatLon) {
        val grid = OsGrid.fromWgs84(at)?.format(8)
        val items = arrayOf("Go to here (bearing & distance)", "Copy position", "Offline map of this area…")
        ui.dialog().setTitle(grid ?: Units.latLon(at.lat, at.lon))
            .setItems(items) { _, which ->
                when (which) {
                    0 -> app.nav.setTarget(at)
                    1 -> host.copy("Position", listOfNotNull(grid, Units.latLon(at.lat, at.lon)).joinToString(" · "))
                    2 -> { mapView.setCenter(at.lat, at.lon, maxOf(mapView.zoom, 12.0)); host.showTab(MainActivity.Tab.OFFLINE) }
                }
            }.show()
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
        if (route == null) { navShown = null; navCard.removeAllViews(); navCard.visibility = View.GONE; return }
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
        val shown = listOf(routeId, route.data.meta.name, offRoute, waiting, stats, status, next).joinToString("|")
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
    }

    private fun updateTarget() {
        val t = app.nav.target
        mapView.target = t
        if (t == null) { targetShown = null; targetCard.removeAllViews(); targetCard.visibility = View.GONE; return }
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
                        res.getOrNull()?.let { host.showTab(MainActivity.Tab.HIKES); host.push(HikeDetailPage(host, it.id)) }
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
        if (status == builtStatus && !force) { updateRecordStats(); return }
        builtStatus = status
        if (status != TrackingState.Status.IDLE) recoverCard.visibility = View.GONE
        recordBar.removeAllViews()
        when (status) {
            TrackingState.Status.IDLE -> {
                val start = ui.button("Start hike", R.drawable.ic_play, Ui.B.FILLED) { startRecording() }
                start.elevation = host.dp(6).toFloat()
                recordBar.addView(start, FrameLayout.LayoutParams(-2, host.dp(56), Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM))
            }
            else -> {
                val card = ui.card(padding = 12, spacing = 0).apply { elevation = host.dp(6).toFloat() }
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
