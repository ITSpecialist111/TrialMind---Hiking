package com.trailmind.app

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import com.trailmind.app.data.Db
import com.trailmind.app.data.HikeStatus
import com.trailmind.app.data.OsNames
import com.trailmind.app.data.Prefs
import com.trailmind.app.data.What3words
import com.trailmind.app.map.TileMapView
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Waypoint
import kotlin.math.abs

/** Framework-only regression runner; all mutable data uses a dedicated test namespace. */
class RedesignInstrumentation : Instrumentation() {
    private var menuAudit = false
    private val isolated by lazy {
        object : android.content.ContextWrapper(targetContext) {
            override fun getDatabasePath(name: String) = super.getDatabasePath("redesign-tests-$name")
            override fun deleteDatabase(name: String) = super.deleteDatabase("redesign-tests-$name")
            override fun openOrCreateDatabase(name: String, mode: Int, factory: android.database.sqlite.SQLiteDatabase.CursorFactory?) =
                super.openOrCreateDatabase("redesign-tests-$name", mode, factory)
            override fun openOrCreateDatabase(name: String, mode: Int, factory: android.database.sqlite.SQLiteDatabase.CursorFactory?, handler: android.database.DatabaseErrorHandler?) =
                super.openOrCreateDatabase("redesign-tests-$name", mode, factory, handler)
            override fun getSharedPreferences(name: String, mode: Int) = super.getSharedPreferences("redesign-tests-$name", mode)
        }
    }
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        menuAudit = arguments?.getString("menuAudit") == "true"
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            if (menuAudit) {
                result.putString("stream", MenuLayoutAudit.run(this))
                finish(Activity.RESULT_OK, result)
                return
            }
            bulkDeletion()
            preferences()
            mapCamera()
            what3wordsResponse()
            unfoldingMenu()
            narrowRouteCard()
            adaptiveMenuActions()
            try {
                What3words.search("///filled.count.soap", "", OsNames.Request())
                error("Missing what3words key must fail explicitly")
            } catch (expected: java.io.IOException) {
                check(expected.message?.contains("API key") == true)
            }
            result.putString("stream", "PASS: bulk deletion/cascades, protected unfinished hikes, opacity persistence, retired maps, camera origin/rotation/zoom, what3words validation, unfolding menu gestures, narrow route-card layout, adaptive menu actions/choices\n")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            android.util.Log.e("RedesignTests", "Regression failure", error)
            result.putString("stream", "FAIL: ${error.stackTraceToString()}\n")
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun bulkDeletion() {
        isolated.deleteDatabase("trailmind.db")
        val db = Db(isolated)
        try {
            val points = listOf(TrackPoint(51.0, -2.0, timeMs = 1_000), TrackPoint(51.001, -2.001, timeMs = 2_000))
            val first = db.insertRoute("Delete first", points, listOf(Waypoint(51.0, -2.0, "Waypoint")))
            val second = db.insertRoute("Keep second", points, emptyList())
            val live = db.createHike("Recording", 1_000, first)
            val paused = db.createHike("Paused", 1_000, second)
            db.setHikeStatus(paused, HikeStatus.PAUSED)
            val finished = db.createHike("Finished", 1_000, first)
            for (id in listOf(live, paused, finished)) db.appendHikePoint(id, 0, 0, points.first())
            db.setHikeStatus(finished, HikeStatus.DONE)
            check(db.deleteRoutes(emptySet()) == 0)
            check(db.deleteRoutes(setOf(first)) == 1)
            check(db.routeData(first) == null && db.routeData(second)?.points?.size == 2)
            for (table in listOf("route_points", "route_waypoints")) {
                db.readableDatabase.rawQuery("SELECT COUNT(*) FROM $table WHERE route_id=?", arrayOf(first.toString())).use {
                    check(it.moveToFirst() && it.getInt(0) == 0)
                }
            }
            check(db.hike(live)?.routeId == null)
            check(db.deleteFinishedHikes(setOf(live, paused, finished)) == 1)
            check(db.hike(live)?.status == HikeStatus.RECORDING)
            check(db.hike(paused)?.status == HikeStatus.PAUSED)
            check(db.hike(finished) == null && db.hikeSegments(finished).isEmpty())
            check(db.hikeSegments(live).flatten().size == 1)
            check(db.deleteRoutes(db.routes().map { it.id }.toSet()) == 1)
            check(db.routes().isEmpty())
        } finally {
            db.close()
            isolated.deleteDatabase("trailmind.db")
        }
    }

    private fun preferences() {
        val prefs = Prefs(isolated)
        prefs.menuOpacityPercent = 70
        check(Prefs(isolated).menuOpacityPercent == 70)
        prefs.menuOpacityPercent = 100
        check(Prefs(isolated).menuOpacityPercent == 100)
        try { prefs.menuOpacityPercent = 69; error("Invalid opacity accepted") } catch (_: IllegalArgumentException) {}
        for (id in listOf("gsi_std", "gsi_photo", "gsi_hillshade")) {
            prefs.baseSourceId = id
            check(Prefs(isolated).baseSourceId == "osm")
        }
        prefs.baseSourceId = "os_leisure"
        check(prefs.baseSourceId == "os_leisure")
    }

    private fun mapCamera() {
        var failure: Throwable? = null
        runOnMainSync {
            try {
                val map = TileMapView(targetContext)
                map.layout(0, 0, 1000, 800)
                map.setCenter(51.0, -2.0, 14.0)
                for (covered in listOf(0f, 340f)) {
                    map.coveredLeftPx = covered
                    val x = (1000 + covered) / 2f
                    for (bearing in listOf(0f, 90f, 180f, 270f, 359f)) {
                        map.bearing = bearing
                        val centre = map.screenToLatLon(x, 400f)
                        check(abs(centre.lat - 51.0) < 1e-8 && abs(centre.lon + 2.0) < 1e-8)
                        val point = map.screenToLatLon(x + 40f, 440f)
                        check(point.lat.isFinite() && point.lon.isFinite())
                        map.zoomBy(0.25)
                        val after = map.screenToLatLon(x, 400f)
                        check(abs(after.lat - centre.lat) < 1e-8 && abs(after.lon - centre.lon) < 1e-8)
                    }
                }
            } catch (error: Throwable) { failure = error }
        }
        failure?.let { throw it }
    }

    private fun what3wordsResponse() {
        val fixture = """{"words":"filled.count.soap","coordinates":{"lat":51.5,"lng":-0.2},
            "square":{"southwest":{"lat":51.49999,"lng":-0.20001},"northeast":{"lat":51.50001,"lng":-0.19999}},
            "nearestPlace":"London"}"""
        val address = What3words.parseResponse(fixture)
        check(address.words == "filled.count.soap" && address.contains(address.position))
        check(!address.contains(address.northeast))
        for (bad in listOf("not json", """{"error":{"code":"BadWords"}}""", fixture.replace("\"lat\":51.5,", "\"lat\":95,"))) {
            try { What3words.parseResponse(bad); error("Invalid API response accepted") }
            catch (expected: java.io.IOException) { check(expected.message?.startsWith("what3words:") == true) }
        }
    }

    private fun unfoldingMenu() {
        var failure: Throwable? = null
        runOnMainSync {
            try {
                val mapEvents = ArrayList<Int>()
                val map = android.view.View(targetContext).apply {
                    setOnTouchListener { _, event -> mapEvents.add(event.actionMasked); true }
                }
                var requested: Boolean? = null
                val root = com.trailmind.app.ui.UnfoldingMenuLayout(targetContext, map, {}, { requested = it })
                root.drawerWidthPx = 360
                val slider = android.widget.SeekBar(targetContext)
                root.drawer.addView(slider, android.widget.FrameLayout.LayoutParams(360, 80).apply { topMargin = 80 })
                val input = android.widget.EditText(targetContext)
                root.drawer.addView(input, android.widget.FrameLayout.LayoutParams(360, 80).apply { topMargin = 200 })
                root.measure(android.view.View.MeasureSpec.makeMeasureSpec(800, android.view.View.MeasureSpec.EXACTLY),
                    android.view.View.MeasureSpec.makeMeasureSpec(900, android.view.View.MeasureSpec.EXACTLY))
                root.layout(0, 0, 800, 900)
                val handle = (0 until root.childCount).map { root.getChildAt(it) }
                    .single { it.contentDescription == "Show menu. Swipe right to unfold." } as android.widget.FrameLayout
                val icon = handle.getChildAt(0)
                check(icon.scaleX == 0.55f && icon.scaleY == 0.55f)
                check(handle.width >= (48 * targetContext.resources.displayMetrics.density).toInt())
                check(handle.isClickable && handle.isFocusable && !icon.isClickable)
                var time = android.os.SystemClock.uptimeMillis()
                var down = time
                fun event(action: Int, x: Float, y: Float) {
                    time += 120
                    if (action == android.view.MotionEvent.ACTION_DOWN) down = time
                    android.view.MotionEvent.obtain(down, time, action, x, y, 0).let {
                        root.dispatchTouchEvent(it)
                        it.recycle()
                    }
                }
                val d = android.view.MotionEvent.ACTION_DOWN
                val m = android.view.MotionEvent.ACTION_MOVE
                val u = android.view.MotionEvent.ACTION_UP
                val c = android.view.MotionEvent.ACTION_CANCEL
                root.setOpen(true, animate = false)
                event(d, 330f, 350f); event(m, 250f, 350f); event(m, 50f, 350f)
                check(root.openFraction in 0.2f..0.3f)
                event(u, 50f, 350f)
                check(requested == false && !root.isOpen)
                root.finishMotion()
                check(root.openFraction == 0f && root.drawer.visibility == android.view.View.INVISIBLE)

                mapEvents.clear()
                event(d, 600f, 600f); event(m, 700f, 610f); event(u, 700f, 610f)
                check(!root.isOpen && android.view.MotionEvent.ACTION_MOVE in mapEvents && c !in mapEvents)
                event(d, 10f, 350f); event(m, 90f, 350f); event(m, 300f, 350f)
                check(root.openFraction > 0.75f)
                event(u, 300f, 350f)
                root.finishMotion()
                check(requested == true && root.openFraction == 1f)

                event(d, 330f, 350f); event(m, 250f, 350f); event(m, 50f, 350f); event(c, 50f, 350f)
                root.finishMotion()
                check(root.isOpen && root.openFraction == 1f)
                event(d, 330f, 500f); event(m, 315f, 350f); event(u, 315f, 350f)
                check(root.openFraction == 1f)
                for (y in listOf(120f, 240f)) {
                    event(d, 300f, y); event(m, 180f, y); event(m, 30f, y); event(u, 30f, y)
                    check(root.isOpen && root.openFraction == 1f) { "Menu stole a slider or text-field gesture" }
                }
                root.setOpen(false, animate = false)
                check(handle.performClick())
                root.finishMotion()
                check(root.openFraction == 1f)
            } catch (error: Throwable) { failure = error }
        }
        failure?.let { throw it }
    }

    private fun narrowRouteCard() {
        var failure: Throwable? = null
        runOnMainSync {
            try {
                val ui = com.trailmind.app.ui.Ui(targetContext)
                val name = "Dan-yr-Ogof Aircraft Crash Site circular walk"
                val detail = "8.10 mi · ↑1706 ft · max 2297 ft · ~3h 46m"
                val card = ui.listItem(name, detail, com.trailmind.app.R.drawable.ic_route, "Following") {}
                val width = ui.dp(260)
                card.measure(android.view.View.MeasureSpec.makeMeasureSpec(width, android.view.View.MeasureSpec.EXACTLY),
                    android.view.View.MeasureSpec.makeMeasureSpec(0, android.view.View.MeasureSpec.UNSPECIFIED))
                card.layout(0, 0, width, card.measuredHeight)
                val textColumn = card.getChildAt(1) as android.widget.LinearLayout
                val title = textColumn.getChildAt(0) as android.widget.TextView
                val subtitle = textColumn.getChildAt(1) as android.widget.TextView
                val badge = textColumn.getChildAt(2) as android.widget.TextView
                check(title.width >= ui.dp(180)) { "Following badge squeezed the route name" }
                check(title.layout.lineCount <= 3)
                check((0 until title.layout.lineCount).all { title.layout.getEllipsisCount(it) == 0 })
                check(badge.top >= subtitle.bottom && subtitle.top >= title.bottom)
                check(card.getChildAt(0).width == ui.dp(40))
                check(card.isClickable)
            } catch (error: Throwable) { failure = error }
        }
        failure?.let { throw it }
    }

    private fun adaptiveMenuActions() {
        var failure: Throwable? = null
        runOnMainSync {
            try {
                for (scale in listOf(1f, 1.3f)) {
                    val configuration = android.content.res.Configuration(targetContext.resources.configuration).apply { fontScale = scale }
                    val ui = com.trailmind.app.ui.Ui(targetContext.createConfigurationContext(configuration))
                    val pairs = listOf(
                        ("Create group" to R.drawable.ic_add) to ("Join with code" to null),
                        ("Follow route" to R.drawable.ic_navigation) to ("Show on map" to R.drawable.ic_map),
                        ("Offline map" to R.drawable.ic_download) to ("Briefing" to R.drawable.ic_sparkle),
                        ("Save GPX" to R.drawable.ic_folder) to ("Share GPX" to R.drawable.ic_share),
                        ("Send invite" to R.drawable.ic_share) to ("Copy code" to null),
                        ("Save & test" to null) to ("Get a key" to null),
                        ("Share log (CSV)" to null) to ("Clear log" to null),
                        ("OS terms" to null) to ("Report an OS map error" to null),
                        ("OpenStreetMap copyright" to null) to ("Report an OpenStreetMap issue" to null),
                    )
                    for ((first, second) in pairs) {
                        val row = ui.actionRow {
                            addView(ui.button(first.first, first.second) {}, ui.lp(0, weight = 1f))
                            addView(ui.button(second.first, second.second) {}, ui.lp(0, weight = 1f))
                        }
                        val widths = if (first.first == "Create group") listOf(164, 196, 228, 328, 196)
                            else listOf(196, 228, 328, 196)
                        for (width in widths) {
                            row.measure(android.view.View.MeasureSpec.makeMeasureSpec(ui.dp(width), android.view.View.MeasureSpec.EXACTLY),
                                android.view.View.MeasureSpec.makeMeasureSpec(0, android.view.View.MeasureSpec.UNSPECIFIED))
                            row.layout(0, 0, row.measuredWidth, row.measuredHeight)
                            for (index in 0 until row.childCount) {
                                val button = row.getChildAt(index) as android.widget.TextView
                                val layout = button.layout
                                val text = layout.text
                                check(button.width <= row.width && button.height >= ui.dp(48))
                                for (line in 0 until layout.lineCount - 1) {
                                    val end = layout.getLineEnd(line)
                                    check(end !in 1 until text.length || !text[end - 1].isLetterOrDigit() || !text[end].isLetterOrDigit()) {
                                        "Split word in ${button.text} at ${width}dp, font scale $scale"
                                    }
                                }
                            }
                            if (first.first == "Create group" && width == 196 && scale == 1f) {
                                check(row.orientation == android.widget.LinearLayout.VERTICAL)
                                check((row.getChildAt(0) as android.widget.TextView).lineCount == 1)
                                check((row.getChildAt(1) as android.widget.TextView).lineCount == 1)
                            }
                        }
                    }
                    val label = "Forest of Dean: hidden places from Lydney"
                    val choices = ui.flow { addView(ui.chip(label, wrap = true) {}) }
                    choices.measure(android.view.View.MeasureSpec.makeMeasureSpec(ui.dp(196), android.view.View.MeasureSpec.EXACTLY),
                        android.view.View.MeasureSpec.makeMeasureSpec(0, android.view.View.MeasureSpec.UNSPECIFIED))
                    choices.layout(0, 0, choices.measuredWidth, choices.measuredHeight)
                    val choice = choices.getChildAt(0) as android.widget.TextView
                    check((0 until choice.layout.lineCount).all { choice.layout.getEllipsisCount(it) == 0 })
                }
            } catch (error: Throwable) { failure = error }
        }
        failure?.let { throw it }
    }
}
