package com.trailmind.app.ui

import android.content.Intent
import android.net.Uri
import android.text.InputType
import android.view.View
import android.widget.TextView
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.data.PackKind
import com.trailmind.app.data.PackMeta
import com.trailmind.app.data.PackStatus
import com.trailmind.app.data.RouteData
import com.trailmind.app.data.RouteMeta
import com.trailmind.app.location.Fix
import com.trailmind.app.map.DownloadService
import com.trailmind.app.map.DownloadState
import com.trailmind.app.map.MbTiles
import com.trailmind.app.map.TileProvider
import com.trailmind.app.map.TileSource
import com.trailmind.app.map.TileSources
import com.trailmind.core.ai.Briefing
import com.trailmind.core.ai.BriefingInput
import com.trailmind.core.format.Units
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.Sun
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.WebMercator
import com.trailmind.core.map.TileCoverage
import com.trailmind.core.map.TilePolicy
import com.trailmind.core.stats.HikeEstimator
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Calendar

// ====================================================================== offline maps

class OfflinePage(host: MainActivity, private val presetRouteId: Long? = null) : Page(host) {
    private var packs: List<PackMeta> = emptyList()
    private var routes: List<RouteMeta> = emptyList()
    private var routeId: Long? = presetRouteId
    private var routeData: RouteData? = null
    private var sourceId: String? = null
    private var maxZoom = 15
    private var bufferM = 500.0
    private var count: Long? = null
    private var countJob = 0
    private var progressViews = HashMap<Long, Pair<android.widget.ProgressBar, TextView>>()
    private val onDownload: () -> Unit = { updateProgress() }
    private val onTiles: () -> Unit = { reload() }

    override fun onShow() {
        DownloadState.addListener(onDownload)
        app.tiles.addListener(onTiles)
        reload()
    }

    override fun onHide() {
        DownloadState.removeListener(onDownload)
        app.tiles.removeListener(onTiles)
    }

    private fun reload() = Async.run({ app.db.packs() to app.db.routes() }) { r ->
        r.getOrNull()?.let { packs = it.first; routes = it.second }
        loadRoute()
    }

    private fun loadRoute() {
        val id = routeId
        if (id == null || routeData?.meta?.id == id) { recount(); refresh(); return }
        Async.run({ app.db.routeData(id) }) { r -> routeData = r.getOrNull(); recount(); refresh() }
    }

    private fun downloadable(): List<TileSource> = TileSources.all(app.prefs, packs).filter {
        it.isOnline && it.offlineDownloadAllowed && !TilePolicy.isBulkDownloadForbidden(it.template!!)
    }

    private fun source(): TileSource? {
        val list = downloadable()
        return list.firstOrNull { it.id == sourceId } ?: list.firstOrNull { it.id == app.prefs.baseSourceId } ?: list.firstOrNull()
    }

    private fun area(): BoundingBox = routeData?.let { BoundingBox.of(it.points.map { p -> p.latLon() })?.expandedByMetres(bufferM) }
        ?: host.map.mapView.visibleBounds()

    private fun minZoom(s: TileSource) = maxOf(s.minZoom, 7)

    private fun recount() {
        val s = source() ?: run { count = null; return }
        val job = ++countJob
        val rd = routeData
        val box = area()
        val minZ = minZoom(s)
        val maxZ = maxZoom.coerceAtMost(s.downloadMaxZoom)
        count = null
        Async.run({
            if (rd != null) TileCoverage.corridorCount(rd.points.map { it.latLon() }, bufferM, minZ, maxZ)
            else WebMercator.countTiles(box, minZ, maxZ)
        }) { r -> if (job == countJob) { count = r.getOrNull(); refresh() } }
    }

    override fun render(): View = scaffold("Offline maps") {
        val s = source()
        addView(ui.card(spacing = 8) {
            addView(ui.text("What can be offline", Ui.T.LABEL))
            addView(ui.text("• OS Maps (Outdoor/Road/Light) areas, downloaded with your own OS Data Hub key, limited to the free OS OpenData zoom levels (up to 16).\n" +
                "• Any raster MBTiles file you have the right to use (e.g. made with QGIS, MOBAC or bought).\n" +
                "• OpenStreetMap's public tiles are never bulk-downloaded: their usage policy forbids it. Areas you browse are cached for a few days only.", Ui.T.CAPTION))
        })

        // --- new download
        addView(ui.card(spacing = 10) {
            addView(ui.text("Download an area", Ui.T.TITLE))
            if (s == null) {
                addView(ui.banner("No source that permits offline storage is set up. Add your free OS Data Hub key in Settings (or a custom source whose licence allows offline use)."))
                addView(ui.button("Open settings", R.drawable.ic_tune, Ui.B.TONAL) { host.push(SettingsPage(host)) })
                return@card
            }
            if (s.requiresKey && app.prefs.osApiKey.isBlank()) addView(ui.banner("${s.name} needs your OS Data Hub API key (Settings)."))
            addView(ui.text("Source", Ui.T.LABEL))
            addView(chipRow(downloadable().map { it.name.removePrefix("OS Maps – ") to it.id }, s.id) { sourceId = it; recount(); refresh() })
            addView(ui.text("Area", Ui.T.LABEL))
            val options = listOf<Pair<String, Long?>>("Visible map area" to null) + routes.take(8).map { it.name to it.id }
            addView(chipRow(options.map { it.first to (it.second?.toString() ?: "") }, routeId?.toString() ?: "") { v ->
                routeId = v.toLongOrNull(); routeData = null; loadRoute()
            })
            if (routeId != null) {
                addView(ui.text("Corridor either side of the route", Ui.T.LABEL))
                addView(chipRow(listOf("250 m" to "250", "500 m" to "500", "1 km" to "1000", "2 km" to "2000"), bufferM.toInt().toString()) {
                    bufferM = it.toDouble(); recount(); refresh()
                })
            }
            addView(ui.text("Most detailed zoom", Ui.T.LABEL))
            val zs = (12..s.downloadMaxZoom).map { z -> "$z" to "$z" }
            if (maxZoom > s.downloadMaxZoom) maxZoom = s.downloadMaxZoom
            addView(chipRow(zs, maxZoom.toString()) { maxZoom = it.toInt(); recount(); refresh() })
            addView(ui.text("Zoom 15 ≈ 1:18k detail, 16 ≈ 1:9k. Lower zooms (${minZoom(s)}+) are included for overview.", Ui.T.CAPTION))
            val c = count
            val tooMany = c != null && c > TilePolicy.MAX_TILES_PER_DOWNLOAD
            addView(ui.text(when {
                c == null -> "Counting tiles…"
                else -> "$c tiles · about ${"%.0f".format(c * AVG_TILE_KB / 1024.0)} MB" +
                    if (tooMany) "\nToo large: the limit is ${TilePolicy.MAX_TILES_PER_DOWNLOAD} tiles per pack. Choose a smaller area, a narrower corridor or a lower zoom." else ""
            }, Ui.T.BODY, if (tooMany) p.danger else p.onSurface))
            addView(ui.text(s.note, Ui.T.CAPTION))
            addView(ui.button("Download", R.drawable.ic_download) {
                if (c == null || c == 0L || tooMany) return@button
                if (DownloadState.packId != null) { host.toast("Another download is running."); return@button }
                val defaultName = routeData?.meta?.name ?: "Area ${java.text.DateFormat.getDateInstance().format(java.util.Date())}"
                ui.prompt("Name this offline map", defaultName) { name -> startDownload(s, name.ifBlank { defaultName }, c) }
            }.apply { isEnabled = c != null && c > 0 && !tooMany; alpha = if (isEnabled) 1f else 0.5f })
        })

        // --- import
        addView(ui.card(spacing = 8) {
            addView(ui.text("Import an MBTiles file", Ui.T.TITLE))
            addView(ui.text("Raster PNG/JPEG/WebP MBTiles (Web Mercator, XYZ/TMS). The file is copied into app storage and works fully offline.", Ui.T.CAPTION))
            addView(ui.button("Choose .mbtiles file", R.drawable.ic_folder, Ui.B.TONAL) { host.pickMbtiles() })
        })

        // --- existing packs
        progressViews = HashMap()
        if (packs.isNotEmpty()) addView(ui.text("Your offline maps", Ui.T.LABEL))
        packs.forEach { pk -> addView(packCard(pk)) }
        addView(ui.card(spacing = 6) {
            addView(ui.text("Browse cache", Ui.T.LABEL))
            val cacheText = ui.text("Calculating…", Ui.T.CAPTION)
            addView(cacheText)
            Async.run({ app.tiles.diskCacheBytes() }) { r -> cacheText.text = "Recently viewed tiles: ${mb(r.getOrDefault(0))} (auto-trimmed to 300 MB, refreshed after 7 days)" }
            addView(ui.button("Clear cache", R.drawable.ic_delete, Ui.B.TEXT) {
                Async.run({ app.tiles.clearDiskCache() }) { refresh() }
            })
        })
    }

    private fun chipRow(items: List<Pair<String, String>>, selected: String, onPick: (String) -> Unit): View {
        val row = ui.row(spacing = 8)
        items.forEach { (label, value) -> row.addView(ui.chip(label, value == selected) { onPick(value) }) }
        return android.widget.HorizontalScrollView(host).apply {
            isHorizontalScrollBarEnabled = false
            addView(row)
        }
    }

    private fun packCard(pk: PackMeta): View = ui.card(spacing = 6) {
        val active = DownloadState.packId == pk.id
        addView(ui.row(spacing = 8) {
            addView(ui.text(pk.name, Ui.T.TITLE), ui.lp(0, weight = 1f))
            addView(ui.chip(if (active) "Downloading" else pk.status.name.lowercase().replaceFirstChar { it.uppercase() }, pk.status == PackStatus.COMPLETE || pk.status == PackStatus.READY))
        })
        val srcName = if (pk.kind == PackKind.IMPORT) "Imported ${pk.format.uppercase()}" else TileSources.byId(pk.sourceId, app.prefs, packs).name
        addView(ui.text("$srcName · zoom ${pk.minZoom}–${pk.maxZoom} · ${mb(pk.bytes)}", Ui.T.CAPTION))
        if (pk.kind == PackKind.DOWNLOAD) {
            val bar = ui.progress().apply { progress = if (pk.tileTotal > 0) (pk.tileDone * 1000 / pk.tileTotal).toInt() else 0 }
            val label = ui.text("${pk.tileDone} / ${pk.tileTotal} tiles" + if (pk.tileFailed > 0) " · ${pk.tileFailed} failed" else "", Ui.T.CAPTION)
            addView(bar, ui.lp()); addView(label)
            progressViews[pk.id] = bar to label
        }
        pk.message?.let { addView(ui.text(it, Ui.T.CAPTION, p.danger)) }
        addView(ui.row(spacing = 4) {
            if (pk.kind == PackKind.DOWNLOAD) {
                if (active) addView(ui.button("Pause", R.drawable.ic_pause, Ui.B.TEXT) { DownloadService.pause(host) })
                else if (pk.status != PackStatus.COMPLETE) addView(ui.button("Resume", R.drawable.ic_play, Ui.B.TEXT) {
                    if (DownloadState.packId != null) host.toast("Another download is running.") else {
                        host.requestNotificationPermissionIfNeeded(); DownloadService.start(host, pk.id)
                    }
                })
            } else {
                addView(ui.button("Use as map", R.drawable.ic_map, Ui.B.TEXT) { host.map.setSource("pack:${pk.id}"); host.showMap() })
            }
            pk.bounds?.let { b -> addView(ui.button("Show", null, Ui.B.TEXT) { host.map.fit(b) }) }
            addView(ui.button("Delete", R.drawable.ic_delete, Ui.B.TEXT) {
                if (active) { host.toast("Pause the download first."); return@button }
                ui.confirm("Delete offline map?", "\"${pk.name}\" (${mb(pk.bytes)}) will be removed from this phone.", "Delete") {
                    Async.run({
                        app.tiles.closePack(pk.id)
                        TileProvider.packFile(host, pk.fileName).delete()
                        app.db.deletePack(pk.id)
                        if (app.prefs.baseSourceId == "pack:${pk.id}") app.prefs.baseSourceId = TileSources.OSM
                        app.tiles.reloadPacks()
                    }) { reload() }
                }
            })
        })
    }

    private fun updateProgress() {
        val id = DownloadState.packId
        if (id == null) { reload(); return }
        val (bar, label) = progressViews[id] ?: run { reload(); return }
        val total = DownloadState.total.coerceAtLeast(1)
        bar.progress = (DownloadState.done * 1000 / total).toInt()
        label.text = "${DownloadState.done} / ${DownloadState.total} tiles" + if (DownloadState.failed > 0) " · ${DownloadState.failed} failed" else ""
    }

    private fun startDownload(s: TileSource, name: String, tiles: Long) {
        val rd = routeData
        val box = area()
        val minZ = minZoom(s)
        val maxZ = maxZoom.coerceAtMost(s.downloadMaxZoom)
        Async.run({
            val fileName = "dl_${System.currentTimeMillis()}.mbtiles"
            MbTiles.create(TileProvider.packFile(host, fileName), name, box, minZ, maxZ, s.attribution).close()
            val id = app.db.insertPack(name, PackKind.DOWNLOAD, s.id, fileName, minZ, maxZ, box, rd?.meta?.id,
                if (rd != null) bufferM else 0.0, tiles, PackStatus.QUEUED, "png", s.attribution)
            app.tiles.reloadPacks()
            id
        }) { r ->
            r.onSuccess { id ->
                host.requestNotificationPermissionIfNeeded()
                DownloadService.start(host, id)
                host.toast("Downloading $name in the background")
                reload()
            }.onFailure { host.toast("Could not start download: ${it.message}") }
        }
    }

    companion object {
        /** Typical OS raster PNG tile size; real sizes vary 5–40 KB. */
        const val AVG_TILE_KB = 18.0
        fun mb(bytes: Long) = if (bytes < 1_048_576) "${bytes / 1024} KB" else "%.1f MB".format(bytes / 1_048_576.0)
    }
}

// ====================================================================== assistant

class AssistantPage(host: MainActivity, private val presetRouteId: Long? = null) : Page(host) {
    private var routes: List<RouteMeta> = emptyList()
    private var routeId: Long? = presetRouteId
    private var data: RouteData? = null
    private var startMs: Long = nextQuarterHour()

    override fun onShow() {
        Async.run({ app.db.routes() }) { r ->
            routes = r.getOrDefault(emptyList())
            if (routeId == null) routeId = app.nav.active?.data?.meta?.id ?: routes.firstOrNull()?.id
            load()
        }
    }

    private fun load() {
        val id = routeId ?: run { refresh(); return }
        Async.run({ app.db.routeData(id) }) { r -> data = r.getOrNull(); refresh() }
    }

    private fun input(d: RouteData): BriefingInput {
        val start = d.points.first().latLon()
        val date = Instant.ofEpochMilli(startMs).atZone(ZoneId.systemDefault()).toLocalDate()
        return BriefingInput(
            routeName = d.meta.name,
            estimate = HikeEstimator.estimate(d.points, app.prefs.pace),
            start = start,
            end = d.points.last().latLon(),
            maxEleM = d.meta.maxEleM,
            waypointNames = d.waypoints.map { it.name },
            sun = Sun.times(date, start),
            plannedStartMs = startMs,
            imperial = app.prefs.imperial,
        )
    }

    override fun render(): View = scaffold("Hike assistant") {
        addView(ui.card(spacing = 8) {
            addView(ui.text("How this works", Ui.T.LABEL))
            addView(ui.text("TrailMind builds a briefing on-device from your route, pace settings and sunset time using fixed rules (no AI, no internet). " +
                "For a richer write-up, it can hand a prompt to Google AI Edge Gallery, which runs Gemma locally. Edge Gallery has no app-to-app API, so the prompt is copied for you to paste. " +
                "AI output can be wrong – never rely on it for safety decisions.", Ui.T.CAPTION))
        })
        if (routes.isEmpty()) {
            addView(ui.card(spacing = 8) {
                addView(ui.text("Import a route first", Ui.T.TITLE))
                addView(ui.button("Import GPX", R.drawable.ic_upload) { host.pickGpx() })
            })
            return@scaffold
        }
        addView(ui.text("Route", Ui.T.LABEL))
        addView(android.widget.HorizontalScrollView(host).apply {
            isHorizontalScrollBarEnabled = false
            addView(ui.row(spacing = 8) {
                routes.take(12).forEach { r -> addView(ui.chip(r.name, r.id == routeId) { routeId = r.id; load() }) }
            })
        })
        addView(ui.text("Planned start", Ui.T.LABEL))
        addView(ui.row(spacing = 8) {
            addView(ui.chip(java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(startMs)), true) { pickTime() })
            addView(ui.chip("Now") { startMs = nextQuarterHour(); refresh() })
            addView(ui.chip("Tomorrow 09:00") { startMs = tomorrowAt(9); refresh() })
        })
        val d = data
        if (d == null || d.meta.id != routeId) { addView(ui.text("Loading…", Ui.T.CAPTION)); return@scaffold }
        val inp = input(d)
        addView(ui.card(spacing = 8) {
            addView(ui.text("Offline briefing", Ui.T.TITLE))
            Briefing.ruleBased(inp).forEach { line ->
                val warn = line.startsWith("⚠") || line.contains("after sunset", true) || line.contains("dark", true)
                addView(ui.text("•  $line", Ui.T.BODY, if (warn) p.danger else p.onSurface))
            }
        })
        val prompt = Briefing.gemmaPrompt(inp)
        addView(ui.card(spacing = 10) {
            addView(ui.text("Ask Gemma on-device", Ui.T.TITLE))
            addView(ui.text(if (host.edgeGalleryInstalled()) "AI Edge Gallery is installed. Tap below, choose AI Chat with a Gemma model, and paste." else
                "AI Edge Gallery isn't installed. You can still copy the prompt into any assistant you trust.", Ui.T.CAPTION))
            addView(ui.button("Copy prompt & open Edge Gallery", R.drawable.ic_sparkle) { host.openEdgeGallery(prompt) })
            addView(ui.row {
                addView(ui.button("Copy", null, Ui.B.TONAL) { host.copy("TrailMind prompt", prompt) }, ui.lp(0, weight = 1f))
                addView(ui.button("Share…", R.drawable.ic_share, Ui.B.TONAL) { host.shareText("Hike briefing prompt", prompt) }, ui.lp(0, weight = 1f))
            })
            addView(ui.text(prompt, Ui.T.CAPTION).apply { setTextIsSelectable(true) })
        })
    }

    private fun pickTime() {
        val cal = Calendar.getInstance().apply { timeInMillis = startMs }
        val theme = if (p.night) android.R.style.Theme_DeviceDefault_Dialog_Alert else android.R.style.Theme_DeviceDefault_Light_Dialog_Alert
        android.app.DatePickerDialog(host, theme, { _, y, m, day ->
            android.app.TimePickerDialog(host, theme, { _, h, min ->
                cal.set(y, m, day, h, min, 0)
                startMs = cal.timeInMillis
                refresh()
            }, cal.get(Calendar.HOUR_OF_DAY), cal.get(Calendar.MINUTE), android.text.format.DateFormat.is24HourFormat(host)).show()
        }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).show()
    }

    private fun nextQuarterHour(): Long {
        val q = 15 * 60_000L
        return (System.currentTimeMillis() / q + 1) * q
    }

    private fun tomorrowAt(hour: Int): Long = LocalDate.now().plusDays(1).atTime(hour, 0).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
}

// ====================================================================== safety

class SafetyPage(host: MainActivity) : Page(host) {
    private val onFix: (Fix) -> Unit = { update() }
    private var grid: TextView? = null
    private var detail: TextView? = null

    override fun onShow() { app.location.addListener(onFix); update() }
    override fun onHide() { app.location.removeListener(onFix) }

    private fun locationText(f: Fix?): String? {
        f ?: return null
        val ll = LatLon(f.lat, f.lon)
        return buildString {
            OsGrid.fromWgs84(ll)?.format(10)?.let { append("OS grid ref: ").append(it).append('\n') }
            append("Lat/Lon: ").append(Units.latLon(f.lat, f.lon)).append(" (±${f.accuracyM.toInt()} m)\n")
            f.altitudeMslM?.let { append("Altitude: ").append(Units.elevation(it, app.prefs.imperial)).append('\n') }
            append("https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f#map=16/%.5f/%.5f".format(f.lat, f.lon, f.lat, f.lon))
        }
    }

    override fun render(): View = scaffold("Safety & location") {
        addView(ui.card(spacing = 6) {
            addView(ui.text("Your grid reference", Ui.T.LABEL))
            grid = ui.text("—", Ui.T.DISPLAY).also { it.setTextIsSelectable(true); addView(it) }
            detail = ui.text("", Ui.T.CAPTION).also { addView(it) }
        })
        addView(ui.row {
            addView(ui.button("Copy", null, Ui.B.TONAL) {
                locationText(app.location.latest)?.let { host.copy("My location", it) } ?: host.toast("No GPS fix yet")
            }, ui.lp(0, weight = 1f))
            addView(ui.button("Share", R.drawable.ic_share, Ui.B.TONAL) {
                locationText(app.location.latest)?.let { host.shareText("My location", it) } ?: host.toast("No GPS fix yet")
            }, ui.lp(0, weight = 1f))
        })
        val contact = app.prefs.emergencyContact
        addView(ui.button(if (contact.isBlank()) "Text my location…" else "Text location to $contact", R.drawable.ic_sos, Ui.B.OUTLINED) {
            val text = locationText(app.location.latest) ?: "I need help – no GPS fix available."
            val uri = Uri.parse("smsto:" + Uri.encode(contact))
            runCatching { host.startActivity(Intent(Intent.ACTION_SENDTO, uri).putExtra("sms_body", text)) }
                .onFailure { host.toast("No SMS app available") }
        })
        addView(ui.button("Call 999", R.drawable.ic_sos, Ui.B.DANGER) {
            host.startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:999")))
        })
        addView(ui.card(color = p.dangerContainer, spacing = 6) {
            addView(ui.text("In an emergency (UK)", Ui.T.TITLE))
            addView(ui.text("• Call 999 or 112 and ask for Police, then Mountain Rescue.\n" +
                "• Give your grid reference, what happened, number of people and injuries.\n" +
                "• No signal for calls? Register in advance for emergencySMS by texting 'register' to 999.\n" +
                "• Stay put, keep warm, and save battery once help is on the way.\n" +
                "Android also sends your location to UK 999 automatically when you call (Emergency Location Service), where supported.", Ui.T.CAPTION, p.onSurface))
        })
        if (contact.isBlank()) addView(ui.button("Set emergency contact", R.drawable.ic_tune, Ui.B.TEXT) { host.push(SettingsPage(host)) })
    }

    private fun update() {
        val f = app.location.latest
        if (f == null) { grid?.text = "No fix"; detail?.text = "Waiting for GPS. Move to open ground for a better signal."; return }
        val ll = LatLon(f.lat, f.lon)
        grid?.text = OsGrid.fromWgs84(ll)?.format(10) ?: Units.latLon(f.lat, f.lon)
        detail?.text = buildString {
            append(Units.latLon(f.lat, f.lon)).append(" · ±${f.accuracyM.toInt()} m")
            f.altitudeMslM?.let { append(" · ${Units.elevation(it, app.prefs.imperial)}") }
            val age = (System.currentTimeMillis() - f.location.time) / 1000
            append(" · ${if (age < 90) "${age}s" else "${age / 60} min"} ago")
        }
    }
}

// ====================================================================== settings

class SettingsPage(host: MainActivity) : Page(host) {
    override fun render(): View = scaffold("Settings") {
        val prefs = app.prefs

        addView(ui.card(spacing = 10) {
            addView(ui.text("Ordnance Survey maps", Ui.T.TITLE))
            addView(ui.text("Create a free account and API project on the OS Data Hub, add the OS Maps API, and paste the project API key here. The key is stored only on this phone. " +
                "Zoom 7–16 uses OS OpenData (free); closer zooms are OS Premium data and use your plan's allowance.", Ui.T.CAPTION))
            val key = ui.input("OS Data Hub API key", prefs.osApiKey, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)
            addView(key, ui.lp())
            val status = ui.text("", Ui.T.CAPTION)
            addView(ui.row {
                addView(ui.button("Save & test", null) {
                    prefs.osApiKey = key.text.toString().trim()
                    app.tiles.clearErrors()
                    status.text = "Testing…"
                    testKey(status)
                }, ui.lp(0, weight = 1f))
                addView(ui.button("Get a key", null, Ui.B.TONAL) { host.openUrl("https://osdatahub.os.uk/") }, ui.lp(0, weight = 1f))
            })
            addView(status)
        })

        addView(ui.card(spacing = 6) {
            addView(ui.text("Units & pace", Ui.T.TITLE))
            addView(ui.switch("Miles and feet", prefs.imperial) { prefs.imperial = it; app.nav.settingsChanged() })
            addView(ui.text("Flat walking speed", Ui.T.LABEL))
            addView(chips(listOf(3.5, 4.0, 4.5, 5.0, 5.5, 6.0).map { "$it km/h" to it }, prefs.flatSpeedKmh) {
                prefs.flatSpeedKmh = it; app.nav.settingsChanged(); refresh()
            })
            addView(ui.text("Conditions / group factor", Ui.T.LABEL))
            addView(chips(listOf("Good ×1.0" to 1.0, "Wet ×1.15" to 1.15, "Rough ×1.3" to 1.3, "Snow/slow ×1.5" to 1.5), prefs.conditionsFactor) {
                prefs.conditionsFactor = it; app.nav.settingsChanged(); refresh()
            })
        })

        addView(ui.card(spacing = 6) {
            addView(ui.text("Navigation", Ui.T.TITLE))
            addView(ui.text("Off-route alert distance", Ui.T.LABEL))
            addView(chips(listOf(30, 60, 100, 150).map { "$it m" to it.toDouble() }, prefs.offRouteThresholdM.toDouble()) {
                prefs.offRouteThresholdM = it.toInt(); app.nav.settingsChanged(); refresh()
            })
            addView(ui.text("Alerts need 3 consecutive GPS fixes beyond this distance (after allowing for GPS accuracy), then vibrate and notify.", Ui.T.CAPTION))
            addView(ui.switch("Offline only (never use mobile data for maps)", prefs.offlineOnly) { prefs.offlineOnly = it; app.tiles.clearErrors() })
        })

        addView(ui.card(spacing = 8) {
            addView(ui.text("Emergency contact", Ui.T.TITLE))
            val phone = ui.input("Phone number for location SMS", prefs.emergencyContact, InputType.TYPE_CLASS_PHONE)
            addView(phone, ui.lp())
            addView(ui.button("Save contact", null, Ui.B.TONAL) { prefs.emergencyContact = phone.text.toString().trim(); host.toast("Saved") })
        })

        addView(ui.card(spacing = 8) {
            addView(ui.text("Custom tile source (advanced)", Ui.T.TITLE))
            addView(ui.text("An XYZ raster template such as https://example.com/{z}/{x}/{y}.png ({s}, {-y} and {key} are supported). You must follow the provider's terms. " +
                "Hosts whose policies forbid bulk downloads (e.g. openstreetmap.org, OpenTopoMap) can be browsed but never downloaded.", Ui.T.CAPTION))
            val name = ui.input("Name", prefs.customName)
            val template = ui.input("URL template", prefs.customTemplate, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
            val attribution = ui.input("Attribution text (required by most licences)", prefs.customAttribution)
            val maxZ = ui.input("Max zoom", prefs.customMaxZoom.toString(), InputType.TYPE_CLASS_NUMBER)
            listOf(name, template, attribution, maxZ).forEach { addView(it, ui.lp()) }
            var allow = prefs.customOfflineAllowed
            addView(ui.switch("Its licence allows me to store tiles offline", allow) { allow = it })
            val err = ui.text("", Ui.T.CAPTION, p.danger)
            addView(err)
            addView(ui.row {
                addView(ui.button("Save source", null, Ui.B.TONAL) {
                    val t = template.text.toString().trim()
                    val problem = if (t.isBlank()) null else TilePolicy.validateTemplate(t)
                    if (problem != null) { err.text = problem; return@button }
                    prefs.customName = name.text.toString().trim()
                    prefs.customTemplate = t
                    prefs.customAttribution = attribution.text.toString().trim()
                    prefs.customMaxZoom = maxZ.text.toString().toIntOrNull()?.coerceIn(1, TilePolicy.MAX_ZOOM) ?: 18
                    prefs.customOfflineAllowed = allow
                    err.text = if (t.isNotBlank() && TilePolicy.isBulkDownloadForbidden(t)) "Saved. This host forbids bulk downloads, so it's browse-only." else ""
                    host.toast(if (t.isBlank()) "Custom source removed" else "Saved – pick it from the map layers button")
                }, ui.lp(0, weight = 1f))
            })
        })

        addView(ui.card(spacing = 6) {
            addView(ui.text("About", Ui.T.TITLE))
            addView(ui.text("TrailMind 0.1 · personal offline-first hiking app.\n" +
                "Map data: © OpenStreetMap contributors (ODbL); Contains OS data © Crown copyright and database rights (OS OpenData under the Open Government Licence; OS Premium under your OS Data Hub plan).\n" +
                "Icons: Material Symbols (Apache 2.0).\n" +
                "Estimates use Naismith's rule with Langmuir corrections and Tobler's hiking function; they exclude breaks.", Ui.T.CAPTION))
            addView(ui.button("Show safety introduction", null, Ui.B.TEXT) { host.push(OnboardingPage(host).also { app.prefs.onboardingAccepted = true }) })
        })
    }

    private fun chips(items: List<Pair<String, Double>>, selected: Double, onPick: (Double) -> Unit): View {
        val row = ui.row(spacing = 8)
        items.forEach { (label, v) -> row.addView(ui.chip(label, kotlin.math.abs(v - selected) < 1e-6) { onPick(v) }) }
        return android.widget.HorizontalScrollView(host).apply { isHorizontalScrollBarEnabled = false; addView(row) }
    }

    private fun testKey(status: TextView) {
        val source = TileSources.builtIns().first { it.id == TileSources.OS_OUTDOOR }
        // One overview tile over Great Britain (zoom 7, OpenData).
        val tile = TileKey(7, 63, 41)
        Async.run({ app.tiles.fetchNetwork(source, tile) }) { r ->
            status.text = when (val f = r.getOrNull()) {
                is TileProvider.Fetch.Ok -> "✓ Key works. Choose an OS map from the layers button."
                is TileProvider.Fetch.Http -> when (f.code) {
                    401, 403 -> "✗ Key rejected (HTTP ${f.code}). Check the OS Maps API is added to your Data Hub project."
                    429 -> "✗ Rate limited (HTTP 429). Try again later."
                    else -> "✗ OS server returned HTTP ${f.code}."
                }
                TileProvider.Fetch.NoKey -> "No key entered."
                TileProvider.Fetch.NoNetwork -> "No internet connection (or offline-only mode is on)."
                is TileProvider.Fetch.Error -> "✗ ${f.message}"
                null -> "✗ ${r.exceptionOrNull()?.message}"
            }
            host.map.setSource(app.prefs.baseSourceId)
        }
    }
}
