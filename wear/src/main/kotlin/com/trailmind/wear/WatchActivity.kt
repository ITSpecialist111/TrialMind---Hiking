package com.trailmind.wear

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.trailmind.core.format.Units
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.MagneticCheck
import com.trailmind.core.geo.NorthAnchor
import com.trailmind.core.nav.TracBack
import com.trailmind.core.watch.TileReply
import com.trailmind.core.watch.WatchProtocol
import com.trailmind.core.watch.WatchRoute
import com.trailmind.core.watch.WatchState
import com.trailmind.core.watch.WatchTrack
import java.io.IOException
import java.util.Date
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sign

/**
 * TrailMind on the watch: a companion to the phone app, not a standalone one. Four pages, swiped vertically:
 * navigate (compass, pointer and breadcrumbs), map, hike (time, distance, pause/finish/retrace), position.
 */
class WatchActivity : Activity(), PhoneLink.Listener, SensorEventListener {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var sensors: SensorManager
    private lateinit var pager: VerticalPager
    private lateinit var map: WatchMapView
    private lateinit var mapInfo: TextView
    private lateinit var linkOverlay: TextView
    private lateinit var dots: LinearLayout
    private lateinit var hikeTitle: TextView
    private lateinit var hikeTime: TextView
    private lateinit var hikeStats: TextView
    private lateinit var primaryButton: TextView
    private lateinit var finishButton: TextView
    private lateinit var retraceButton: TextView
    private lateinit var dial: NavDialView
    private lateinit var navHeading: TextView
    private lateinit var navTitle: TextView
    private lateinit var navDetail: TextView
    private lateinit var posGrid: TextView
    private lateinit var posDetail: TextView

    private var state = WatchState()
    private var stateAt = 0L
    private var connected = false
    private var trackPoints = 0
    private var headingDeg: Float? = null
    private var declination = 0f
    private var declinationAt = 0L
    // The magnetometer's accuracy is its calibration state; the field check catches what that misses.
    // Sitting on the magnetic charger upsets both.
    private var compassAccuracy = SensorManager.SENSOR_STATUS_ACCURACY_HIGH
    private val field = MagneticCheck()
    private val north = NorthAnchor()
    private var northLogged = false
    private var hasRotation = false
    private var compassHinted = false
    private var finishArmedUntil = 0L
    private var started = false
    private var mapInfoColor = PILL
    private var rotary = 0f
    private val rotation = FloatArray(9)
    private val orientation = FloatArray(3)
    private val tick = object : Runnable {
        override fun run() {
            renderHike()
            main.postDelayed(this, 1000)
        }
    }

    private val density get() = resources.displayMetrics.density
    private fun dp(v: Number) = (v.toFloat() * density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sensors = getSystemService(SensorManager::class.java)
        map = WatchMapView(this) { LinkService.send(WatchProtocol.TILE_REQUEST, it.encode()) }
        map.onTap = {
            if (!map.toggleFollow()) Toast.makeText(this, "Tap the map again to follow you", Toast.LENGTH_SHORT).show()
            renderMap()
        }
        pager = VerticalPager(this).apply {
            addView(navPage())
            addView(mapPage())
            addView(hikePage())
            addView(positionPage())
            onPageChanged = { renderDots() }
        }
        dots = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            repeat(PAGES) { addView(View(context).apply { background = oval(Color.WHITE) }, LinearLayout.LayoutParams(dp(5), dp(5)).apply { setMargins(0, dp(3), 0, dp(3)) }) }
        }
        linkOverlay = text("", 15f, Color.WHITE).apply {
            gravity = Gravity.CENTER
            setBackgroundColor(0xF0000000.toInt())
            val pad = (screenWidth() * 0.14f).toInt()
            setPadding(pad, pad, pad, pad)
            isClickable = true
        }
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(pager, FrameLayout.LayoutParams(-1, -1))
            addView(dots, FrameLayout.LayoutParams(-2, -2, Gravity.END or Gravity.CENTER_VERTICAL).apply { marginEnd = dp(5) })
            addView(linkOverlay, FrameLayout.LayoutParams(-1, -1))
        })
        onLinkStatus(PhoneLink.Status.CONNECTING)
        renderAll()
    }
    override fun onStart() {
        super.onStart()
        started = true
        val missing = buildList {
            if (Build.VERSION.SDK_INT >= 31 && !PhoneLink.hasPermission(this@WatchActivity)) add(Manifest.permission.BLUETOOTH_CONNECT)
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 1)
        // The link runs as a connected-device service, which needs the Bluetooth permission first.
        if (PhoneLink.hasPermission(this)) attachLink() else onLinkStatus(PhoneLink.Status.NO_PERMISSION)
        sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)?.let { sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_UI) }
        compassAccuracy = SensorManager.SENSOR_STATUS_ACCURACY_HIGH
        field.reset()
        north.reset()
        northLogged = false
        hasRotation = false
        // For its accuracy reports and the field check.
        sensors.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)?.let { sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL) }
        main.post(tick)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (PhoneLink.hasPermission(this) && started) attachLink()
    }

    private fun attachLink() {
        LinkService.attach(this, this)
        if (LinkService.takeOffRouteNotice()) pager.show(NAV_PAGE)
    }

    override fun onStop() {
        started = false
        LinkService.detach(this)
        sensors.unregisterListener(this)
        main.removeCallbacks(tick)
        super.onStop()
    }

    override fun onDestroy() {
        // Leaving the app ends the link unless a hike is recording; the screen going off does not.
        if (isFinishing && LinkService.recording == WatchState.IDLE) LinkService.stop(this)
        super.onDestroy()
    }

    // ---------------------------------------------------------------- pages

    private fun screenWidth() = resources.displayMetrics.widthPixels

    private fun text(s: String, sp: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = s
        textSize = sp
        setTextColor(color)
        gravity = Gravity.CENTER
        if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }

    private fun oval(color: Int) = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color) }

    private fun pill(color: Int) = GradientDrawable().apply { cornerRadius = dp(24).toFloat(); setColor(color) }

    private fun button(label: String, bg: Int, onClick: () -> Unit) = text(label, 15f, Color.WHITE, bold = true).apply {
        background = pill(bg)
        minHeight = dp(44)
        setPadding(dp(14), dp(8), dp(14), dp(8))
        isClickable = true
        setOnClickListener { onClick() }
    }

    /** A page's content, padded into the part of a round screen that is actually visible. */
    private fun page(block: LinearLayout.() -> Unit) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        val padH = (screenWidth() * 0.13f).toInt()
        val padV = (screenWidth() * 0.12f).toInt()
        setPadding(padH, padV, padH, padV)
        block()
    }

    private fun mapPage() = FrameLayout(this).apply {
        addView(map, FrameLayout.LayoutParams(-1, -1))
        mapInfo = text("", 13f, Color.WHITE, bold = true).apply {
            background = pill(PILL)
            setPadding(dp(10), dp(4), dp(10), dp(4))
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            maxWidth = (screenWidth() * 0.66f).toInt()
        }
        addView(mapInfo, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = (screenWidth() * 0.1f).toInt() })
        val zoom = LinearLayout(this@WatchActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(zoomButton("\u2212") { map.zoomBy(-1) })
            addView(View(context), LinearLayout.LayoutParams(dp(18), 1))
            addView(zoomButton("+") { map.zoomBy(1) })
        }
        addView(zoom, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = (screenWidth() * 0.19f).toInt() })
    }

    private fun zoomButton(label: String, onClick: () -> Unit) = text(label, 20f, Color.WHITE, bold = true).apply {
        background = oval(0xCC000000.toInt())
        layoutParams = LinearLayout.LayoutParams(dp(38), dp(38))
        contentDescription = if (label == "+") "Zoom in" else "Zoom out"
        isClickable = true
        setOnClickListener { onClick() }
    }

    private fun hikePage() = page {
        hikeTitle = text("Hike", 13f, MUTED, bold = true)
        hikeTime = text("0:00:00", 32f, Color.WHITE, bold = true).apply { fontFeatureSettings = "tnum" }
        hikeStats = text("", 15f, Color.WHITE)
        primaryButton = button("Start", GREEN_DARK) { onPrimary() }
        finishButton = button("Finish", RED_DARK) { onFinish() }
        retraceButton = button("Retrace", TEAL_DARK) { onRetrace() }.apply { textSize = 13f; minHeight = dp(34) }
        addView(hikeTitle)
        // Full width with even-width digits: the ticking clock redraws without a layout pass every second.
        addView(hikeTime, LinearLayout.LayoutParams(-1, -2))
        addView(hikeStats)
        addView(LinearLayout(this@WatchActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            addView(primaryButton)
            addView(View(context), LinearLayout.LayoutParams(dp(8), 1))
            addView(finishButton)
        }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(10) })
        addView(retraceButton, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(6) })
    }

    private fun navPage() = FrameLayout(this).apply {
        dial = NavDialView(this@WatchActivity).apply {
            onTap = {
                headingUp = !headingUp
                Toast.makeText(this@WatchActivity, if (headingUp) "Heading up" else "North up", Toast.LENGTH_SHORT).show()
                renderNav()
            }
        }
        addView(dial, FrameLayout.LayoutParams(-1, -1))
        navHeading = text("", 13f, Color.WHITE, bold = true).apply {
            background = pill(0x99000000.toInt())
            setPadding(dp(8), dp(2), dp(8), dp(2))
        }
        addView(navHeading, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = (screenWidth() * 0.17f).toInt() })
        navTitle = text("", 14f, Color.WHITE, bold = true).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END; maxWidth = (screenWidth() * 0.62f).toInt() }
        navDetail = text("", 13f, MUTED).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END; maxWidth = (screenWidth() * 0.62f).toInt() }
        addView(LinearLayout(this@WatchActivity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            background = pill(0xB3000000.toInt())
            setPadding(dp(10), dp(3), dp(10), dp(4))
            addView(navTitle)
            addView(navDetail)
        }, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = (screenWidth() * 0.13f).toInt() })
    }

    private fun positionPage() = page {
        addView(text("Grid reference", 13f, MUTED, bold = true))
        posGrid = text("\u2014", 21f, Color.WHITE, bold = true)
        posDetail = text("", 13f, MUTED)
        addView(posGrid)
        addView(posDetail)
        addView(text("Emergency: 999 or 112, ask for Police, then Mountain Rescue.", 12f, ORANGE).apply { setPadding(0, dp(6), 0, 0) })
    }

    // ---------------------------------------------------------------- phone link (called on the link thread)

    override fun onLinkStatus(status: PhoneLink.Status) {
        main.post { showLinkStatus(status) }
    }

    private fun showLinkStatus(status: PhoneLink.Status) {
        val was = connected
        connected = status == PhoneLink.Status.CONNECTED
        if (was != connected) map.linkChanged()
        linkOverlay.visibility = if (connected) View.GONE else View.VISIBLE
        linkOverlay.text = when (status) {
            PhoneLink.Status.NO_BLUETOOTH -> "This watch has no Bluetooth."
            PhoneLink.Status.NO_PERMISSION -> "Allow \u201cNearby devices\u201d so TrailMind can reach your phone."
            PhoneLink.Status.BLUETOOTH_OFF -> "Turn on Bluetooth."
            PhoneLink.Status.CONNECTING -> "Connecting to your phone\u2026"
            PhoneLink.Status.NO_PHONE -> "Can't reach TrailMind on your phone.\n\nOpen it and turn on Settings \u2192 Watch companion."
            PhoneLink.Status.CONNECTED -> ""
        }
    }

    override fun onFrame(frame: WatchProtocol.Frame) {
        try {
            when (frame.type) {
                WatchProtocol.STATE -> WatchState.decode(frame.payload).let { s -> main.post { onState(s) } }
                WatchProtocol.ROUTE -> WatchRoute.decode(frame.payload).let { r ->
                    main.post { map.setRoute(r.points, r.waypoints.map { it.position }); dial.route = r.points; renderAll() }
                }
                WatchProtocol.TRACK -> WatchTrack.decode(frame.payload).let { t ->
                    main.post { map.setTrack(t.segments); dial.track = t.segments; trackPoints = t.segments.sumOf { it.size }; renderHike() }
                }
                WatchProtocol.TILE -> TileReply.decode(frame.payload).let { t ->
                    val bmp = t.bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                    main.post { map.onTile(t.request, bmp) }
                }
                WatchProtocol.ALERT -> WatchProtocol.reader(frame.payload).let { r ->
                    val kind = r.readUnsignedByte()
                    val msg = r.readUTF()
                    main.post { onAlert(kind, msg) }
                }
            }
        } catch (e: IOException) {
            Log.w(TAG, "ignored a malformed frame of type ${frame.type}", e)
        }
    }

    private fun onState(s: WatchState) {
        state = s
        stateAt = SystemClock.elapsedRealtime()
        map.setSource(s.mapKey, s.attribution, s.mapMinZoom, s.mapMaxZoom)
        map.setPosition(if (s.hasFix) LatLon(s.lat, s.lon) else null, s.accuracyM)
        map.setMarkers(latLonOrNull(s.nextLat, s.nextLon), latLonOrNull(s.targetLat, s.targetLon))
        if (s.hasFix && SystemClock.elapsedRealtime() - declinationAt > 60_000) {
            val g = GeomagneticField(s.lat.toFloat(), s.lon.toFloat(), s.altitudeM.takeIf { !it.isNaN() }?.toFloat() ?: 0f, System.currentTimeMillis())
            declination = g.declination
            field.expect(g.fieldStrength / 1000.0, g.inclination.toDouble())
            declinationAt = SystemClock.elapsedRealtime()
        }
        renderAll()
    }

    private fun onAlert(kind: Int, msg: String) {
        Alerts.pattern(kind)?.let { vibrate(it) }
        when (kind) {
            WatchProtocol.ALERT_OFF_ROUTE -> pager.show(NAV_PAGE)
            WatchProtocol.ALERT_BACK_ON_ROUTE -> Unit
            else -> Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
        }
    }

    // ---------------------------------------------------------------- actions

    private fun onPrimary() {
        val code = when (state.recording) {
            WatchState.RECORDING -> WatchProtocol.CMD_PAUSE
            WatchState.PAUSED -> WatchProtocol.CMD_RESUME
            else -> WatchProtocol.CMD_START
        }
        LinkService.send(WatchProtocol.COMMAND, WatchProtocol.command(code))
        vibrate(longArrayOf(0, 30))
    }

    /** Finishing ends the recording, so it takes a second tap within three seconds. */
    private fun onFinish() {
        val now = SystemClock.elapsedRealtime()
        if (now < finishArmedUntil) {
            finishArmedUntil = 0
            LinkService.send(WatchProtocol.COMMAND, WatchProtocol.command(WatchProtocol.CMD_FINISH))
            vibrate(longArrayOf(0, 60, 80, 60))
        } else {
            finishArmedUntil = now + 3_000
            main.postDelayed({ renderHike() }, 3_100)
        }
        renderHike()
    }

    /** Guidance back along the breadcrumb to the start; the phone replies with the reversed track as the route. */
    private fun onRetrace() {
        LinkService.send(WatchProtocol.COMMAND, WatchProtocol.command(WatchProtocol.CMD_TRACBACK))
        vibrate(longArrayOf(0, 30))
        pager.show(NAV_PAGE)
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_SCROLL && event.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER)) {
            rotary += -event.getAxisValue(MotionEvent.AXIS_SCROLL)
            if (abs(rotary) >= 1f) {
                val step = sign(rotary).toInt()
                rotary = 0f
                when (pager.page) {
                    MAP_PAGE -> { map.zoomBy(step); renderMap() }
                    NAV_PAGE -> { dial.zoomBy(step); renderNav() }
                    else -> pager.show(pager.page + step)
                }
            }
            return true
        }
        return super.onGenericMotionEvent(event)
    }

    // ---------------------------------------------------------------- compass

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type == Sensor.TYPE_MAGNETIC_FIELD) {
            val v = event.values
            updateCompassProblem {
                compassAccuracy = event.accuracy
                if (hasRotation) field.add(v[0].toDouble(), v[1].toDouble(), v[2].toDouble(), rotation[6].toDouble(), rotation[7].toDouble(), rotation[8].toDouble())
            }
            if (hasRotation) {
                north.add(rotation, v[0].toDouble(), v[1].toDouble(), v[2].toDouble())
                if (!northLogged) { northLogged = true; Log.i(TAG, "rotation vector north is %.0f° from magnetic north".format(north.offsetDeg)) }
            }
            return
        }
        SensorManager.getRotationMatrixFromVector(rotation, event.values)
        hasRotation = true
        SensorManager.getOrientation(rotation, orientation)
        val deg = Geo.normalizeDeg(Math.toDegrees(orientation[0].toDouble()) - north.offsetDeg + declination).toFloat()
        val prev = headingDeg
        if (prev != null && abs(Geo.angleDiffDeg(prev.toDouble(), deg.toDouble())) < 3) return
        headingDeg = deg
        map.headingDeg = deg
        renderNav()
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {
        if (sensor.type == Sensor.TYPE_MAGNETIC_FIELD) updateCompassProblem { compassAccuracy = accuracy }
    }

    /** Why the heading can't be trusted right now, or null. */
    private fun compassProblem() = when {
        compassAccuracy <= SensorManager.SENSOR_STATUS_ACCURACY_LOW -> "Calibrate compass"
        field.disturbed -> "Compass disturbed"
        else -> null
    }

    private fun updateCompassProblem(change: () -> Unit) {
        val before = compassProblem()
        change()
        val now = compassProblem()
        if (now == before) return
        Log.i(TAG, "compass ${now ?: "ok"}: accuracy $compassAccuracy, %.1f µT dipping %.1f°".format(field.strengthUt, field.dipDeg))
        if (now != null && !compassHinted) {
            compassHinted = true
            val tip = if (field.disturbed && compassAccuracy > SensorManager.SENSOR_STATUS_ACCURACY_LOW) "Magnetic interference: keep the watch away from metal, magnets and its charger"
            else "Compass needs calibrating: move the watch in a figure-of-eight"
            Toast.makeText(this, tip, Toast.LENGTH_LONG).show()
        }
        renderNav()
    }

    // ---------------------------------------------------------------- rendering

    private fun renderAll() {
        renderMap()
        renderHike()
        renderNav()
        renderPosition()
        renderDots()
    }

    /** Sets text only when it changes, so nothing is redrawn or re-announced needlessly. */
    private fun TextView.show(s: CharSequence) {
        if (!TextUtils.equals(text, s)) text = s
    }

    private fun dist(m: Double) = Units.distance(m, state.imperial)
    private fun ele(m: Double) = Units.elevation(m, state.imperial)

    private fun renderDots() {
        for (i in 0 until dots.childCount) dots.getChildAt(i).alpha = if (i == pager.page) 1f else 0.35f
    }

    private fun renderMap() {
        val s = state
        val info = when {
            !s.hasFix -> "Waiting for GPS"
            s.offRoute -> "Off route \u00b7 ${dist(s.offRouteM)}"
            s.following && !s.toGoM.isNaN() -> "${dist(s.toGoM)} to go"
            s.recording != WatchState.IDLE -> "${dist(s.distanceM)} \u00b7 ${Units.duration(activeMs())}"
            else -> s.grid
        }
        mapInfo.show(if (map.follow) info else "Overview")
        val bg = if (s.offRoute) RED_DARK else PILL
        if (bg != mapInfoColor) { mapInfoColor = bg; mapInfo.background = pill(bg) }
    }

    private fun activeMs() = state.activeMs + if (state.recording == WatchState.RECORDING) SystemClock.elapsedRealtime() - stateAt else 0L

    private fun renderHike() {
        val s = state
        val ms = activeMs()
        hikeTitle.show(when (s.recording) { WatchState.RECORDING -> "Recording"; WatchState.PAUSED -> "Paused"; else -> "Hike" })
        hikeTitle.setTextColor(when (s.recording) { WatchState.RECORDING -> GREEN; WatchState.PAUSED -> ORANGE; else -> MUTED })
        hikeTime.show(String.format(java.util.Locale.ROOT, "%d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60))
        hikeStats.show(if (s.recording == WatchState.IDLE) "Start here or on your phone" else "${dist(s.distanceM)} \u00b7 \u2191${ele(s.ascentM)}")
        primaryButton.show(when (s.recording) { WatchState.RECORDING -> "Pause"; WatchState.PAUSED -> "Resume"; else -> "Start hike" })
        finishButton.visibility = if (s.recording == WatchState.IDLE) View.GONE else View.VISIBLE
        finishButton.show(if (SystemClock.elapsedRealtime() < finishArmedUntil) "Confirm" else "Finish")
        val canRetrace = s.recording != WatchState.IDLE && trackPoints >= 2 && s.routeName != TracBack.ROUTE_NAME
        retraceButton.visibility = if (canRetrace) View.VISIBLE else View.GONE
        if (s.recording == WatchState.RECORDING) renderMap()
    }

    private fun renderNav() {
        val s = state
        val here = if (s.hasFix) LatLon(s.lat, s.lon) else null
        val heading = headingDeg
        dial.headingDeg = heading
        dial.position = here
        dial.imperial = s.imperial
        val next = latLonOrNull(s.nextLat, s.nextLon)
        val ahead = latLonOrNull(s.aheadLat, s.aheadLon)
        val target = latLonOrNull(s.targetLat, s.targetLon)
        var bearing: Double? = null
        var color = GREEN
        val title: String
        val detail: String
        when {
            here == null -> { title = "Waiting for GPS"; detail = "" }
            s.following && s.offRoute -> {
                bearing = s.backBearingDeg.takeIf { !it.isNaN() }
                color = RED
                title = "Off route"
                detail = dist(s.offRouteM) + (bearing?.let { " \u00b7 back ${Units.bearing(it)}" } ?: "")
            }
            s.following -> {
                // The pointer follows the line a little way ahead, so it tracks bends in the path.
                bearing = (ahead ?: next)?.let { Geo.bearingDeg(here, it) }
                title = if (next != null) s.nextName else s.routeName
                detail = when {
                    next != null -> dist(s.nextAlongM)
                    !s.toGoM.isNaN() -> "${dist(s.toGoM)} to go"
                    else -> ""
                }
            }
            target != null -> {
                val b = Geo.bearingDeg(here, target)
                bearing = b
                color = ORANGE
                title = "Go to"
                detail = "${dist(Geo.distanceM(here, target))} \u00b7 ${Units.bearing(b)}"
            }
            s.recording != WatchState.IDLE -> { title = "${dist(s.distanceM)} walked"; detail = "Hike page \u2192 Retrace to go back" }
            else -> { title = "No route"; detail = "Follow one on your phone" }
        }
        dial.setPointer(bearing, color)
        navTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, if (title.length > 14) 12f else 14f)
        navTitle.show(title)
        navDetail.show(detail)
        navDetail.visibility = if (detail.isEmpty()) View.GONE else View.VISIBLE
        val scale = dist(dial.radiusM)
        val problem = if (heading != null) compassProblem() else null
        navHeading.setTextColor(if (problem != null) ORANGE else Color.WHITE)
        navHeading.show(
            when {
                problem != null -> problem
                heading != null && dial.headingUp -> "${Units.bearing(heading.toDouble())} ${Geo.cardinal(heading.toDouble())} \u00b7 $scale"
                else -> "North up \u00b7 $scale"
            },
        )
    }

    private fun renderPosition() {
        val s = state
        posGrid.show(s.grid.ifBlank { "\u2014" })
        posDetail.show(if (!s.hasFix) "Waiting for GPS" else buildString {
            append(Units.latLon(s.lat, s.lon).replace(" ", "\n"))
            append("\n")
            if (!s.altitudeM.isNaN()) append(ele(s.altitudeM)).append(" \u00b7 ")
            append("\u00b1").append(dist(s.accuracyM.toDouble()))
            if (s.sunsetMs > 0) append("\nSunset ").append(android.text.format.DateFormat.getTimeFormat(this@WatchActivity).format(Date(s.sunsetMs)))
            if (!s.pressureHpa.isNaN()) {
                append("\n").append(s.pressureHpa.roundToInt()).append(" hPa")
                if (!s.pressureChangeHpa.isNaN()) append(String.format(java.util.Locale.ROOT, " \u00b7 %+.1f in 3 h", s.pressureChangeHpa))
                if (s.pressureChangeHpa <= -STORM_DROP_HPA) append("\nWeather may be turning")
            }
        })
    }

    private fun latLonOrNull(lat: Double, lon: Double) = if (lat.isNaN() || lon.isNaN()) null else LatLon(lat, lon)

    companion object {
        private const val TAG = "TrailMindWatch"
        private const val PAGES = 4
        private const val NAV_PAGE = 0
        private const val MAP_PAGE = 1
        private const val STORM_DROP_HPA = 4.0
        private val MUTED = Color.rgb(170, 184, 176)
        private val GREEN = Color.rgb(127, 209, 174)
        private val GREEN_DARK = Color.rgb(31, 91, 69)
        private val TEAL_DARK = Color.rgb(20, 78, 94)
        private val ORANGE = Color.rgb(255, 176, 102)
        private val RED = Color.rgb(255, 138, 128)
        private val RED_DARK = Color.rgb(183, 28, 28)
        private const val PILL = 0xCC000000.toInt()
    }
}
