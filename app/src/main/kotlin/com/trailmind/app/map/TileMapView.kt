package com.trailmind.app.map

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BlendMode
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.core.format.Units
import com.trailmind.core.geo.Facility
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.WebMercator
import com.trailmind.core.map.BngTiles
import com.trailmind.core.map.Lidar
import com.trailmind.core.map.TileFootprint
import com.trailmind.core.nav.DistanceMarks
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt

/** Growable polyline stored in normalised Web Mercator coordinates (0..1) for fast drawing. */
class MercatorLine(capacity: Int = 256) {
    var nx = DoubleArray(capacity); private set
    var ny = DoubleArray(capacity); private set
    var size = 0; private set
    /** Index where a new recorded segment starts (breaks the drawn line after a pause). */
    val breaks = ArrayList<Int>()

    fun add(p: LatLon) {
        if (size == nx.size) {
            nx = nx.copyOf(size * 2)
            ny = ny.copyOf(size * 2)
        }
        nx[size] = (p.lon + 180.0) / 360.0
        ny[size] = WebMercator.latToY(p.lat, 0.0) / WebMercator.TILE_SIZE
        size++
    }

    fun breakHere() {
        if (size > 0) breaks.add(size)
    }

    fun clear() {
        size = 0
        breaks.clear()
    }

    companion object {
        fun of(points: List<LatLon>) = MercatorLine(points.size.coerceAtLeast(2)).apply { points.forEach { add(it) } }
    }
}

data class MapMarker(val position: LatLon, val label: String)

/** A trip-group member. [age] and [relayed] show how far to trust the position; [help] turns the marker red. */
data class HikerMarker(
    val memberId: Int,
    val position: LatLon,
    val initials: String,
    val label: String,
    val colour: Int,
    val age: Age,
    val relayed: Boolean,
    val help: Boolean,
) {
    enum class Age { FRESH, STALE, LAST_SEEN }
}

/**
 * Framework-only slippy map: raster tiles, pinch/drag/double-tap, route + breadcrumb overlays,
 * position with accuracy and heading, scale bar and attribution. North up, or turned by [bearing] with TrailMind's own
 * markers and labels kept upright (words printed on the tiles turn with the map).
 */
@SuppressLint("ViewConstructor")
class TileMapView(context: Context) : View(context) {

    interface Listener {
        fun onCameraChanged() {}
        fun onLongPress(at: LatLon) {}
        fun onSingleTap(at: LatLon) {}
        fun onFollowChanged(follow: Boolean) {}
        /** The map credit (or the OS logo) was tapped: licences ask for a way to reach their terms from the map. */
        fun onAttributionTap() {}
    }

    private val provider = TrailMindApp.instance.tiles
    private val terrain = TrailMindApp.instance.terrain
    private val lidar = TrailMindApp.instance.lidar
    private val density = resources.displayMetrics.density
    var listener: Listener? = null

    var source: TileSource = TileSources.builtIns().first()
        set(value) {
            if (field.id != value.id) provider.cancelPending()
            field = value
            invalidate()
        }

    var centerLat = 54.46; private set
    var centerLon = -3.09; private set
    var zoom = 11.0; private set
    val minZoom = 2.0
    // Two zooms of enlargement past the source's most detailed tiles.
    val maxZoom: Double get() = when (source.grid) {
        TileGrid.WEB_MERCATOR -> (source.maxZoom + 2).toDouble()
        TileGrid.BRITISH_NATIONAL_GRID -> ln(WebMercator.metresPerPixel(centerLat, 0.0) * 4 / BngTiles.resolution(source.maxZoom)) / ln(2.0)
    }.coerceAtMost(21.0)

    var route: MercatorLine? = null
        set(v) { if (field != v) { field = v; invalidate() } }
    var plannedLegs: List<Pair<MercatorLine, Boolean>> = emptyList()
        set(v) { field = v; invalidate() }
    var planControls: List<LatLon> = emptyList()
        set(v) { field = v; invalidate() }
    /** Points along [route] every [distanceStepM]; element i is labelled i + 1. */
    var distanceMarks: List<LatLon> = emptyList()
        set(v) { field = v; invalidate() }
    var distanceStepM = 1000.0
    var track: MercatorLine? = null
        set(v) { field = v; invalidate() }
    var waypoints: List<MapMarker> = emptyList()
        set(v) { field = v; invalidate() }
    var facilities: List<Facility> = emptyList()
        set(v) { field = v; invalidate() }
    var target: LatLon? = null
        set(v) { if (field != v) { field = v; invalidate() } }
    var searchPin: MapMarker? = null
        set(v) { field = v; invalidate() }
    /** Trip-group members, drawn above waypoints and below your own position. */
    var hikers: List<HikerMarker> = emptyList()
        set(v) { field = v; invalidate() }
    /** Where the base map is on the phone, tinted and outlined under the route. */
    var offlineAreas: List<TileFootprint> = emptyList()
        set(v) { field = v; bngFootprintVertices.keys.retainAll(v.toSet()); invalidate() }
    var showSteepGround = false
        set(v) { if (field != v) { field = v; invalidate() } }
    /** 1 m LiDAR hill shading and crags, in England, when zoomed in. */
    var showLidar = false
        set(v) { if (field != v) { field = v; invalidate() } }
    private var lidarDrawn = false
    /** A scanned historic map (Great Britain) drawn over the base map, or null when off. */
    var historic: TileSource? = null
        set(v) { if (field?.id != v?.id) { field = v; invalidate() } }
    /** How opaque the historic map is over the base map, 0–1. */
    var historicAlpha = 0.55f
        set(v) { val a = v.coerceIn(0.1f, 1f); if (field != a) { field = a; invalidate() } }
    private var historicDrawn = false
    private val lidarCorners = HashMap<Long, LatLon>()
    private val bngFootprintVertices = HashMap<TileFootprint, MutableMap<Long, LatLon>>()

    var position: LatLon? = null; private set
    private var accuracyM = 0f
    var headingDeg: Float? = null
        set(v) { if (field != v) { field = v; if (position != null) invalidate() } }

    /** Compass bearing at the top of the screen, degrees clockwise from north; 0 is north up. The map turns about its centre. */
    var bearing = 0f
        set(v) {
            val b = ((v % 360f) + 360f) % 360f
            if (field == b) return
            field = b
            val r = Math.toRadians(b.toDouble())
            cosB = kotlin.math.cos(r).toFloat()
            sinB = kotlin.math.sin(r).toFloat()
            invalidate()
        }
    private var cosB = 1f
    private var sinB = 0f

    var follow = false
        set(v) {
            if (field != v) { field = v; listener?.onFollowChanged(v) }
            if (v) position?.let { setCenter(it.lat, it.lon) }
        }

    /** Height covered by UI chrome at the bottom; attribution and scale bar are drawn above it. */
    var bottomChromePx = 0f
        set(v) { if (field != v) { field = v; invalidate() } }

    /** Hint drawn in the middle of the map (e.g. missing API key). */
    var hint: String? = null
        set(v) { if (field != v) { field = v; invalidate() } }

    private val tileListener: () -> Unit = { invalidate() }
    private val terrainListener: () -> Unit = { invalidate() }

    // --- paints (allocated once)
    private val tilePaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val historicPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val gridPaint = Paint().apply { color = Color.rgb(226, 230, 222); strokeWidth = 1f }
    private val bgColor = Color.rgb(238, 241, 234)
    private val routeCasing = strokePaint(Color.WHITE, 8f)
    private val routePaint = strokePaint(Color.rgb(142, 36, 170), 5f)
    private val planCasing = strokePaint(Color.WHITE, 8f)
    private val planPaint = strokePaint(Color.rgb(0, 83, 92), 5f)
    private val straightPaint = strokePaint(Color.rgb(0, 83, 92), 5f).apply {
        pathEffect = DashPathEffect(floatArrayOf(9 * density, 7 * density), 0f)
    }
    private val controlPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(0, 83, 92) }
    private val trackPaint = strokePaint(Color.rgb(240, 110, 20), 4f)
    private val targetLine = strokePaint(Color.rgb(211, 47, 47), 2.5f).apply {
        pathEffect = DashPathEffect(floatArrayOf(10 * density, 8 * density), 0f)
    }
    private val accuracyFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(45, 25, 118, 210) }
    private val accuracyStroke = strokePaint(Color.argb(120, 25, 118, 210), 1f)
    private val dotFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(25, 118, 210) }
    private val white = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val headingPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(110, 25, 118, 210) }
    private val wpFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(142, 36, 170) }
    private val facilityFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(0, 96, 85) }
    private val facilityText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textSize = 9 * density; isFakeBoldText = true; textAlign = Paint.Align.CENTER
    }
    private val facilityBoxes = ArrayList<RectF>()
    private val markRing = strokePaint(Color.rgb(142, 36, 170), 1.5f)
    private val markText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(142, 36, 170); textSize = 10 * density; isFakeBoldText = true; textAlign = Paint.Align.CENTER
    }
    private val targetFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(211, 47, 47) }
    private val hikerFill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val hikerStale = strokePaint(Color.rgb(245, 124, 0), 2.5f)
    private val hikerLost = strokePaint(Color.rgb(117, 117, 117), 2.5f)
    private val hikerRelayed = strokePaint(Color.rgb(55, 55, 55), 1.5f).apply {
        pathEffect = DashPathEffect(floatArrayOf(4 * density, 3 * density), 0f)
    }
    private val hikerHelpHalo = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(85, 211, 47, 47) }
    private val hikerText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textSize = 10 * density; isFakeBoldText = true; textAlign = Paint.Align.CENTER
    }
    private val pinFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(0, 121, 107) }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(30, 30, 30); textSize = 12 * density; isFakeBoldText = true
    }
    private val labelHalo = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textSize = 12 * density; isFakeBoldText = true; style = Paint.Style.STROKE; strokeWidth = 3 * density
    }
    private val attrPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(40, 40, 40); textSize = 10.5f * density }
    private val attrBg = Paint().apply { color = Color.argb(200, 255, 255, 255) }
    private val scalePaint = strokePaint(Color.rgb(30, 30, 30), 2f).apply { strokeCap = Paint.Cap.SQUARE }
    private val osLogo = context.getDrawable(R.drawable.os_logo_maps)
    // Taps on the credit strip or the OS logo open the map's licence links; the map between them stays a map.
    private val creditBox = RectF()
    private val logoBox = RectF()
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(60, 60, 60); textSize = 14 * density; textAlign = Paint.Align.CENTER
    }
    // Not anti-aliased, so the row spans meet without seams.
    private val offlineFill = Paint().apply { color = Color.argb(34, 0, 121, 107) }
    private val offlineEdge = strokePaint(Color.argb(220, 0, 121, 107), 2f).apply {
        strokeCap = Paint.Cap.SQUARE; strokeJoin = Paint.Join.MITER
    }

    private fun strokePaint(c: Int, widthDp: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = c; style = Paint.Style.STROKE; strokeWidth = widthDp * density
        strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND
    }

    private val dst = RectF()
    private val src = Rect()
    private val path = Path()
    private val tileMatrix = Matrix()
    private val quad = FloatArray(8)
    private val tileCorners = floatArrayOf(0f, 0f, 256f, 0f, 256f, 256f, 0f, 256f)
    // Half a pixel of overlap so neighbouring warped tiles leave no hairline seams.
    private val tileRect = RectF(-0.5f, -0.5f, 256.5f, 256.5f)
    // LiDAR corners in mesh order (north-west, north-east, south-west, south-east).
    private val lidarMesh = FloatArray(8)
    private var cornerX = FloatArray(0)
    private var cornerY = FloatArray(0)
    private val labelBoxes = ArrayList<RectF>()
    private val labelTry = RectF()
    // Unturned-map area to draw this frame, a marker's screen position, and a hint from the base map.
    private var viewL = 0f
    private var viewT = 0f
    private var viewR = 0f
    private var viewB = 0f
    private var px = 0f
    private var py = 0f
    private var sourceHint: String? = null

    // --- camera

    fun setCenter(lat: Double, lon: Double, newZoom: Double = zoom) {
        centerLat = lat.coerceIn(-WebMercator.MAX_LAT, WebMercator.MAX_LAT)
        centerLon = com.trailmind.core.geo.Geo.normalizeLon(lon)
        zoom = newZoom.coerceIn(minZoom, maxZoom)
        invalidate()
        listener?.onCameraChanged()
    }

    var coveredLeftPx = 0f
        set(value) { if (field != value) { field = value; invalidate() } }

    private fun focalX(w: Float = width.toFloat()) = (w + coveredLeftPx.coerceIn(0f, w)) / 2f

    fun zoomBy(dz: Double) = zoomAround(focalX(), height / 2f, dz)

    fun fitBounds(b: BoundingBox, paddingPx: Float = 48 * density) {
        if (width == 0 || height == 0) {
            post { fitBounds(b, paddingPx) }
            return
        }
        val c = b.center
        var z = maxZoom.coerceAtMost(17.0)
        val ac = kotlin.math.abs(cosB)
        val asn = kotlin.math.abs(sinB)
        while (z > minZoom) {
            val bw = WebMercator.lonToX(b.maxLon, z) - WebMercator.lonToX(b.minLon, z)
            val bh = WebMercator.latToY(b.minLat, z) - WebMercator.latToY(b.maxLat, z)
            // The box's size on the turned screen.
            val w = bw * ac + bh * asn
            val h = bw * asn + bh * ac
            if (w <= width - coveredLeftPx - 2 * paddingPx && h <= height - 2 * paddingPx) break
            z -= 0.25
        }
        follow = false
        setCenter(c.lat, c.lon, z)
    }

    fun visibleBounds(): BoundingBox {
        val w = width.toFloat()
        val h = height.toFloat()
        val corners = listOf(screenToLatLon(0f, 0f), screenToLatLon(w, 0f), screenToLatLon(0f, h), screenToLatLon(w, h))
        return BoundingBox(corners.minOf { it.lat }, corners.minOf { it.lon }, corners.maxOf { it.lat }, corners.maxOf { it.lon })
    }

    fun setPosition(p: LatLon?, accuracy: Float) {
        if (position == p && accuracyM == accuracy) return
        position = p
        accuracyM = accuracy
        if (follow && p != null) setCenter(p.lat, p.lon) else invalidate()
    }

    fun screenToLatLon(sx: Float, sy: Float): LatLon {
        val dx = sx - focalX()
        val dy = sy - height / 2f
        val wx = WebMercator.lonToX(centerLon, zoom) + (dx * cosB - dy * sinB)
        val wy = WebMercator.latToY(centerLat, zoom) + (dx * sinB + dy * cosB)
        return LatLon(WebMercator.yToLat(wy, zoom), WebMercator.xToLon(wx, zoom))
    }

    private fun zoomAround(fx: Float, fy: Float, dz: Double) {
        val anchor = screenToLatLon(fx, fy)
        val nz = (zoom + dz).coerceIn(minZoom, maxZoom)
        val ax = WebMercator.lonToX(anchor.lon, nz)
        val ay = WebMercator.latToY(anchor.lat, nz)
        val dx = fx - focalX()
        val dy = fy - height / 2f
        val cx = ax - (dx * cosB - dy * sinB)
        val cy = ay - (dx * sinB + dy * cosB)
        val lat = WebMercator.yToLat(cy, nz)
        val lon = WebMercator.xToLon(cx, nz)
        if (follow && position != null) {
            // Keep the walker centred while zooming in follow mode.
            zoom = nz
            invalidate()
            listener?.onCameraChanged()
        } else {
            setCenter(lat, lon, nz)
        }
    }

    private fun panBy(dx: Float, dy: Float) {
        val cx = WebMercator.lonToX(centerLon, zoom) + (dx * cosB - dy * sinB)
        val cy = (WebMercator.latToY(centerLat, zoom) + (dx * sinB + dy * cosB)).coerceIn(0.0, WebMercator.mapSize(zoom))
        setCenter(WebMercator.yToLat(cy, zoom), WebMercator.xToLon(cx, zoom))
    }

    // --- gestures

    private class PendingTap(val point: LatLon) {
        lateinit var delivery: Runnable
    }
    private val pendingTaps = ArrayList<PendingTap>()

    fun flushPendingTaps() {
        pendingTaps.toList().forEach { tap ->
            removeCallbacks(tap.delivery)
            tap.delivery.run()
        }
    }

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(d: ScaleGestureDetector): Boolean {
            zoomAround(d.focusX, d.focusY, ln(d.scaleFactor.toDouble()) / ln(2.0))
            return true
        }
    })

    private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true
        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, dx: Float, dy: Float): Boolean {
            if (scaleDetector.isInProgress) return false
            follow = false
            panBy(dx, dy)
            return true
        }
        override fun onDoubleTap(e: MotionEvent): Boolean {
            pendingTaps.lastOrNull()?.let { pendingTaps.remove(it); removeCallbacks(it.delivery) }
            zoomAround(e.x, e.y, 1.0)
            return true
        }
        override fun onSingleTapUp(e: MotionEvent): Boolean {
            if (creditBox.contains(e.x, e.y) || logoBox.contains(e.x, e.y)) { listener?.onAttributionTap(); return true }
            val tap = PendingTap(screenToLatLon(e.x, e.y))
            tap.delivery = Runnable { if (pendingTaps.remove(tap)) listener?.onSingleTap(tap.point) }
            pendingTaps += tap
            postDelayed(tap.delivery, android.view.ViewConfiguration.getDoubleTapTimeout().toLong())
            return true
        }
        override fun onLongPress(e: MotionEvent) {
            performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            listener?.onLongPress(screenToLatLon(e.x, e.y))
        }
    })

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        gestureDetector.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_POINTER_DOWN) follow = false
        return true
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        provider.addListener(tileListener)
        terrain.addListener(terrainListener)
        lidar.addListener(terrainListener)
    }

    override fun onDetachedFromWindow() {
        pendingTaps.forEach { removeCallbacks(it.delivery) }
        pendingTaps.clear()
        provider.removeListener(tileListener)
        terrain.removeListener(terrainListener)
        lidar.removeListener(terrainListener)
        super.onDetachedFromWindow()
    }

    // --- drawing

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(bgColor)
        val w = width.toFloat()
        val h = height.toFloat()
        // The part of the unturned map that covers the turned screen.
        val x = focalX(w)
        val l = -x
        val r = w - x
        val hh = h / 2
        viewL = x + minOf(l * cosB, r * cosB) - hh * kotlin.math.abs(sinB)
        viewR = x + maxOf(l * cosB, r * cosB) + hh * kotlin.math.abs(sinB)
        viewT = hh + minOf(l * sinB, r * sinB) - hh * kotlin.math.abs(cosB)
        viewB = hh + maxOf(l * sinB, r * sinB) + hh * kotlin.math.abs(cosB)
        sourceHint = null
        canvas.save()
        canvas.rotate(-bearing, x, h / 2)
        drawTiles(canvas, w, h)
        drawHistoric(canvas, w, h)
        drawOfflineAreas(canvas, w, h)
        drawLidar(canvas, w, h)
        drawSteepGround(canvas, w, h)
        route?.let { drawLine(canvas, it, routeCasing, w, h); drawLine(canvas, it, routePaint, w, h) }
        track?.let { drawLine(canvas, it, trackPaint, w, h) }
        plannedLegs.forEach { (line, snapped) ->
            drawLine(canvas, line, planCasing, w, h)
            drawLine(canvas, line, if (snapped) planPaint else straightPaint, w, h)
        }
        canvas.restore()
        planControls.forEach { point ->
            place(point, w, h)
            canvas.drawCircle(px, py, 6 * density, white)
            canvas.drawCircle(px, py, 4 * density, controlPaint)
        }
        drawDistanceMarks(canvas, w, h)
        drawFacilities(canvas, w, h)
        drawWaypoints(canvas, w, h)
        drawHikers(canvas, w, h)
        drawTarget(canvas, w, h)
        drawSearchPin(canvas, w, h)
        drawPosition(canvas, w, h)
        drawScaleAndAttribution(canvas, w, h)
        (hint ?: sourceHint)?.let { drawHint(canvas, it, w, h) }
    }

    /** Screen position of [p] on the turned map, into [px] and [py]. */
    private fun place(p: LatLon, w: Float, h: Float) {
        val ux = toScreenX(p.lon, w) - focalX(w)
        val uy = toScreenY(p.lat, h) - h / 2
        px = focalX(w) + ux * cosB + uy * sinB
        py = h / 2 - ux * sinB + uy * cosB
    }

    /** Whether a rectangle of the unturned map shows on the turned screen (tested by its turned bounding box). */
    private fun onScreen(left: Float, top: Float, right: Float, bottom: Float, w: Float, h: Float): Boolean {
        if (bearing == 0f) return right >= 0 && left <= w && bottom >= 0 && top <= h
        val l = left - focalX(w)
        val r = right - focalX(w)
        val t = top - h / 2
        val b = bottom - h / 2
        val minX = minOf(l * cosB, r * cosB) + minOf(t * sinB, b * sinB)
        val maxX = maxOf(l * cosB, r * cosB) + maxOf(t * sinB, b * sinB)
        val minY = minOf(-l * sinB, -r * sinB) + minOf(t * cosB, b * cosB)
        val maxY = maxOf(-l * sinB, -r * sinB) + maxOf(t * cosB, b * cosB)
        return maxX >= -focalX(w) && minX <= w - focalX(w) && maxY >= -h / 2 && minY <= h / 2
    }

    private fun drawTiles(canvas: Canvas, w: Float, h: Float) {
        val src0 = source
        if (src0.grid == TileGrid.BRITISH_NATIONAL_GRID) return drawNationalGridTiles(canvas, w, h)
        val zf = floor(zoom).toInt()
        if (zf < src0.minZoom) {
            drawGrid(canvas)
            sourceHint = "Zoom in to show ${src0.name}"
            return
        }
        val zi = zf.coerceAtMost(src0.maxZoom)
        drawMercatorTiles(canvas, w, h, src0, zi, tilePaint, gridLines = true)
    }

    /** Web Mercator tiles of [s] at zoom [zi], scaled to the current zoom; missing tiles show an enlarged lower zoom. */
    private fun drawMercatorTiles(canvas: Canvas, w: Float, h: Float, s: TileSource, zi: Int, paint: Paint, gridLines: Boolean): Boolean {
        var drawn = false
        val scale = 2.0.pow(zoom - zi)
        val ts = WebMercator.TILE_SIZE
        val size = (ts * scale).toFloat()
        val cx = WebMercator.lonToX(centerLon, zi.toDouble())
        val cy = WebMercator.latToY(centerLat, zi.toDouble())
        val x0 = floor((cx + (viewL - focalX(w)) / scale) / ts).toInt()
        val x1 = floor((cx + (viewR - focalX(w)) / scale) / ts).toInt()
        val y0 = floor((cy + (viewT - h / 2) / scale) / ts).toInt()
        val y1 = floor((cy + (viewB - h / 2) / scale) / ts).toInt()
        val n = 1 shl zi
        for (tx in x0..x1) for (ty in y0..y1) {
            if (ty < 0 || ty >= n) continue
            val wx = Math.floorMod(tx, n)
            val left = ((tx * ts - cx) * scale + focalX(w)).toFloat()
            val top = ((ty * ts - cy) * scale + h / 2).toFloat()
            if (!onScreen(left, top, left + size, top + size, w, h)) continue
            dst.set(left, top, left + size + 0.5f, top + size + 0.5f)
            val key = TileKey(zi, wx, ty)
            val bmp = provider.cached(s, key)
            if (bmp != null) {
                canvas.drawBitmap(bmp, null, dst, paint)
                drawn = true
                if (provider.isApproximate(s, key)) provider.request(s, key)
            } else {
                provider.request(s, key)
                val pb = fallbackFor(s, key)
                if (pb != null) { canvas.drawBitmap(pb, src, dst, paint); drawn = true }
                else if (gridLines) {
                    canvas.drawLine(dst.left, dst.top, dst.right, dst.top, gridPaint)
                    canvas.drawLine(dst.left, dst.top, dst.left, dst.bottom, gridPaint)
                }
            }
        }
        return drawn
    }

    /** An old Ordnance Survey map faded over the base map, so what has gone shows through what is there now. */
    private fun drawHistoric(canvas: Canvas, w: Float, h: Float) {
        historicDrawn = false
        val s = historic ?: return
        val zf = floor(zoom).toInt()
        if (zf < s.minZoom || !TileSources.overlapsBritain(visibleBounds())) return
        historicPaint.alpha = (historicAlpha * 255).roundToInt()
        historicDrawn = drawMercatorTiles(canvas, w, h, s, zf.coerceAtMost(s.maxZoom), historicPaint, gridLines = false)
    }

    /**
     * British National Grid tiles (OS Leisure), each warped onto this Web Mercator view through its four
     * corners, so routes and the GPS dot still line up.
     */
    private fun drawNationalGridTiles(canvas: Canvas, w: Float, h: Float) {
        val s = source
        val mpp = WebMercator.metresPerPixel(centerLat, zoom)
        if (mpp > BngTiles.resolution(s.minZoom) * 2) {
            drawGrid(canvas)
            sourceHint = "Zoom in to show ${s.name}"
            return
        }
        var z = BngTiles.zoomFor(mpp, s.minZoom, s.maxZoom)
        // Free OS plan: enlarge the last OpenData zoom rather than wait for Premium tiles that never come.
        s.premiumFromZoom?.let { if (z >= it && provider.premiumDenied(s)) z = it - 1 }
        var minE = Double.MAX_VALUE
        var maxE = -Double.MAX_VALUE
        var minN = Double.MAX_VALUE
        var maxN = -Double.MAX_VALUE
        // Corners and edge midpoints: the grid is turned slightly against north.
        for (i in 0..2) for (j in 0..2) {
            val g = OsGrid.project(screenToLatLon(w * i / 2, h * j / 2))
            minE = minOf(minE, g.easting); maxE = maxOf(maxE, g.easting)
            minN = minOf(minN, g.northing); maxN = maxOf(maxN, g.northing)
        }
        if (maxE < 0 || minE > BngTiles.GB_MAX_E || maxN < 0 || minN > BngTiles.GB_MAX_N) {
            drawGrid(canvas)
            sourceHint = "${s.name} covers Great Britain only"
            return
        }
        val x0 = BngTiles.column(minE.coerceAtLeast(0.0), z)
        val x1 = BngTiles.column(maxE.coerceAtMost(BngTiles.GB_MAX_E), z)
        val y0 = BngTiles.row(maxN.coerceAtMost(BngTiles.GB_MAX_N), z)
        val y1 = BngTiles.row(minN.coerceAtLeast(0.0), z)
        val cols = x1 - x0 + 2
        val rows = y1 - y0 + 2
        if (cornerX.size < cols * rows) {
            cornerX = FloatArray(cols * rows)
            cornerY = FloatArray(cols * rows)
        }
        for (r in 0 until rows) for (c in 0 until cols) {
            val p = OsGrid.toWgs84(BngTiles.easting(x0 + c, z), BngTiles.northing(y0 + r, z))
            cornerX[r * cols + c] = toScreenX(p.lon, w)
            cornerY[r * cols + c] = toScreenY(p.lat, h)
        }
        for (ty in y0..y1) for (tx in x0..x1) {
            val nw = (ty - y0) * cols + (tx - x0)
            quad[0] = cornerX[nw]; quad[1] = cornerY[nw]
            quad[2] = cornerX[nw + 1]; quad[3] = cornerY[nw + 1]
            quad[4] = cornerX[nw + cols + 1]; quad[5] = cornerY[nw + cols + 1]
            quad[6] = cornerX[nw + cols]; quad[7] = cornerY[nw + cols]
            val left = minOf(minOf(quad[0], quad[2]), minOf(quad[4], quad[6]))
            val right = maxOf(maxOf(quad[0], quad[2]), maxOf(quad[4], quad[6]))
            val top = minOf(minOf(quad[1], quad[3]), minOf(quad[5], quad[7]))
            val bottom = maxOf(maxOf(quad[1], quad[3]), maxOf(quad[5], quad[7]))
            if (!onScreen(left, top, right, bottom, w, h)) continue
            val key = TileKey(z, tx, ty)
            val bmp = provider.cached(s, key)
            if (bmp != null) {
                drawWarped(canvas, bmp, null)
                if (provider.isApproximate(s, key)) provider.request(s, key)
            } else {
                provider.request(s, key)
                val pb = fallbackFor(s, key)
                if (pb != null) drawWarped(canvas, pb, src)
                else {
                    canvas.drawLine(quad[0], quad[1], quad[2], quad[3], gridPaint)
                    canvas.drawLine(quad[0], quad[1], quad[6], quad[7], gridPaint)
                }
            }
        }
    }

    /** Draws [part] of [bmp] (all of it when null) into the tile outline in [quad]. */
    private fun drawWarped(canvas: Canvas, bmp: Bitmap, part: Rect?) {
        if (!tileMatrix.setPolyToPoly(tileCorners, 0, quad, 0, 4)) return
        canvas.save()
        canvas.concat(tileMatrix)
        canvas.drawBitmap(bmp, part, tileRect, tilePaint)
        canvas.restore()
    }

    /** The nearest cached lower zoom covering [key], with [src] set to the part of it that does. */
    private fun fallbackFor(s: TileSource, key: TileKey): Bitmap? {
        for (d in 1..4) {
            val pz = key.z - d
            if (pz < s.minZoom || pz < 0) return null
            val pk = TileKey(pz, key.x shr d, key.y shr d)
            val pb = provider.cached(s, pk) ?: continue
            val f = pb.width / WebMercator.TILE_SIZE.toFloat()
            val sub = WebMercator.TILE_SIZE shr d
            val sx = (key.x - (pk.x shl d)) * sub
            val sy = (key.y - (pk.y shl d)) * sub
            src.set((sx * f).toInt(), (sy * f).toInt(), ((sx + sub) * f).toInt(), ((sy + sub) * f).toInt())
            return pb
        }
        return null
    }

    private fun drawOfflineAreas(canvas: Canvas, w: Float, h: Float) {
        if (offlineAreas.isEmpty()) return
        if (source.grid == TileGrid.BRITISH_NATIONAL_GRID) {
            for (footprint in offlineAreas) drawBngOfflineArea(canvas, w, h, footprint)
            return
        }
        val ox = focalX(w) - WebMercator.lonToX(centerLon, zoom)
        val oy = h / 2 - WebMercator.latToY(centerLat, zoom)
        for (f in offlineAreas) {
            val cell = WebMercator.TILE_SIZE * 2.0.pow(zoom - f.zoom)
            if (f.maxX * cell + ox < viewL || f.minX * cell + ox > viewR || f.maxY * cell + oy < viewT || f.minY * cell + oy > viewB) continue
            path.reset()
            val s = f.spans
            for (i in s.indices step 3) {
                val top = s[i] * cell + oy
                if (top > viewB || top + cell < viewT) continue
                path.addRect((s[i + 1] * cell + ox).toFloat(), top.toFloat(), (s[i + 2] * cell + ox).toFloat(), (top + cell).toFloat(), Path.Direction.CW)
            }
            canvas.drawPath(path, offlineFill)
            path.reset()
            val e = f.edges
            for (i in e.indices step 4) {
                val x0 = (e[i] * cell + ox).toFloat()
                val y0 = (e[i + 1] * cell + oy).toFloat()
                val x1 = (e[i + 2] * cell + ox).toFloat()
                val y1 = (e[i + 3] * cell + oy).toFloat()
                if (maxOf(x0, x1) < viewL || minOf(x0, x1) > viewR || maxOf(y0, y1) < viewT || minOf(y0, y1) > viewB) continue
                path.moveTo(x0, y0)
                path.lineTo(x1, y1)
            }
            canvas.drawPath(path, offlineEdge)
        }
    }

    private fun drawSteepGround(canvas: Canvas, w: Float, h: Float) {
        if (!showSteepGround || zoom < STEEP_MIN_ZOOM) return
        val z = com.trailmind.core.map.Terrain.ZOOM
        val scale = 2.0.pow(zoom - z)
        val size = (WebMercator.TILE_SIZE * scale).toFloat()
        val cx = WebMercator.lonToX(centerLon, z.toDouble())
        val cy = WebMercator.latToY(centerLat, z.toDouble())
        val x0 = floor((cx + (viewL - focalX(w)) / scale) / WebMercator.TILE_SIZE).toInt()
        val x1 = floor((cx + (viewR - focalX(w)) / scale) / WebMercator.TILE_SIZE).toInt()
        val y0 = floor((cy + (viewT - h / 2) / scale) / WebMercator.TILE_SIZE).toInt()
        val y1 = floor((cy + (viewB - h / 2) / scale) / WebMercator.TILE_SIZE).toInt()
        terrain.keepSlopeTiles((x1 - x0 + 1) * (y1 - y0 + 1))
        val count = 1 shl z
        for (x in x0..x1) for (y in y0..y1) {
            if (y !in 0 until count) continue
            val key = TileKey(z, Math.floorMod(x, count), y)
            val left = ((x * WebMercator.TILE_SIZE - cx) * scale + focalX(w)).toFloat()
            val top = ((y * WebMercator.TILE_SIZE - cy) * scale + h / 2).toFloat()
            if (!onScreen(left, top, left + size, top + size, w, h)) continue
            dst.set(left, top, left + size + 0.5f, top + size + 0.5f)
            val bitmap = terrain.slopeTile(key)
            if (bitmap == null) terrain.requestSlopeTile(key) else canvas.drawBitmap(bitmap, null, dst, tilePaint)
        }
    }

    /**
     * 1 m LiDAR squares on the National Grid, each drawn through its exact corners. The shading is translucent, so squares
     * must not overlap like opaque map tiles do: shared edges would be shaded twice and show as dark grid lines.
     */
    private fun drawLidar(canvas: Canvas, w: Float, h: Float) {
        lidarDrawn = false
        // Every frame, even with the layer off: squares asked for before it are no longer wanted, so none are downloaded.
        lidar.beginFrame()
        if (!showLidar || zoom < LIDAR_MIN_ZOOM) return
        var minE = Double.MAX_VALUE
        var maxE = -Double.MAX_VALUE
        var minN = Double.MAX_VALUE
        var maxN = -Double.MAX_VALUE
        for (i in 0..2) for (j in 0..2) {
            val g = OsGrid.project(screenToLatLon(w * i / 2, h * j / 2))
            minE = minOf(minE, g.easting); maxE = maxOf(maxE, g.easting)
            minN = minOf(minN, g.northing); maxN = maxOf(maxN, g.northing)
        }
        val squares = Lidar.box(minE, minN, maxE, maxN, LidarProvider.MAX_VISIBLE) ?: return
        if (squares.isEmpty()) return
        lidar.keepOverlays(squares.size)
        if (lidarCorners.size > 20_000) lidarCorners.clear()
        fun corner(col: Int, row: Int, index: Int) {
            val key = (col.toLong() shl 32) or (row.toLong() and 0xFFFF_FFFFL)
            val p = lidarCorners.getOrPut(key) { OsGrid.toWgs84(col * Lidar.SIZE.toDouble(), row * Lidar.SIZE.toDouble()) }
            lidarMesh[index] = toScreenX(p.lon, w)
            lidarMesh[index + 1] = toScreenY(p.lat, h)
        }
        val fetch = zoom >= LIDAR_FETCH_ZOOM
        val m = lidarMesh
        for (square in squares) {
            corner(square.col, square.row + 1, 0)
            corner(square.col + 1, square.row + 1, 2)
            corner(square.col, square.row, 4)
            corner(square.col + 1, square.row, 6)
            val left = minOf(minOf(m[0], m[2]), minOf(m[4], m[6]))
            val right = maxOf(maxOf(m[0], m[2]), maxOf(m[4], m[6]))
            val top = minOf(minOf(m[1], m[3]), minOf(m[5], m[7]))
            val bottom = maxOf(maxOf(m[1], m[3]), maxOf(m[5], m[7]))
            if (!onScreen(left, top, right, bottom, w, h)) continue
            val bitmap = lidar.overlay(square)
            if (bitmap == null || lidar.isStale(square)) lidar.requestOverlay(square, fetch)
            if (bitmap != null && bitmap !== LidarProvider.EMPTY) {
                // Neighbours share the same corner values, so the triangles meet with no gap and no overlap.
                canvas.drawBitmapMesh(bitmap, 1, 1, m, 0, null, 0, tilePaint)
                lidarDrawn = true
            }
        }
    }

    private fun drawBngOfflineArea(canvas: Canvas, w: Float, h: Float, footprint: TileFootprint) {
        val vertices = bngFootprintVertices.getOrPut(footprint) { HashMap() }
        fun corner(x: Int, y: Int): Pair<Float, Float> {
            val key = (y.toLong() shl 32) or (x.toLong() and 0xFFFF_FFFFL)
            val point = vertices.getOrPut(key) {
                OsGrid.toWgs84(BngTiles.easting(x, footprint.zoom), BngTiles.northing(y, footprint.zoom))
            }
            return toScreenX(point.lon, w) to toScreenY(point.lat, h)
        }
        // Rows and edges wholly off the view are skipped; the grid is turned a few degrees from the screen, hence the slack.
        fun outside(a: Pair<Float, Float>, b: Pair<Float, Float>): Boolean {
            val slack = (kotlin.math.abs(b.first - a.first) + kotlin.math.abs(b.second - a.second)) * 0.1f
            return maxOf(a.first, b.first) + slack < viewL || minOf(a.first, b.first) - slack > viewR ||
                maxOf(a.second, b.second) + slack < viewT || minOf(a.second, b.second) - slack > viewB
        }
        val spans = footprint.spans
        path.reset()
        for (i in spans.indices step 3) {
            val y = spans[i]
            if (outside(corner(spans[i + 1], y), corner(spans[i + 2], y + 1))) continue
            for (x in spans[i + 1] until spans[i + 2]) {
                val a = corner(x, y)
                val b = corner(x + 1, y)
                val c = corner(x + 1, y + 1)
                val d = corner(x, y + 1)
                path.moveTo(a.first, a.second)
                path.lineTo(b.first, b.second)
                path.lineTo(c.first, c.second)
                path.lineTo(d.first, d.second)
                path.close()
            }
        }
        canvas.drawPath(path, offlineFill)
        path.reset()
        val edges = footprint.edges
        for (i in edges.indices step 4) {
            if (outside(corner(edges[i], edges[i + 1]), corner(edges[i + 2], edges[i + 3]))) continue
            val dx = (edges[i + 2] - edges[i]).coerceIn(-1, 1)
            val dy = (edges[i + 3] - edges[i + 1]).coerceIn(-1, 1)
            val steps = maxOf(kotlin.math.abs(edges[i + 2] - edges[i]), kotlin.math.abs(edges[i + 3] - edges[i + 1]))
            for (step in 0..steps) {
                val point = corner(edges[i] + step * dx, edges[i + 1] + step * dy)
                if (step == 0) path.moveTo(point.first, point.second) else path.lineTo(point.first, point.second)
            }
        }
        canvas.drawPath(path, offlineEdge)
    }

    private fun drawGrid(canvas: Canvas) {
        val step = 64 * density
        var x = floor(viewL / step) * step
        while (x < viewR) { canvas.drawLine(x, viewT, x, viewB, gridPaint); x += step }
        var y = floor(viewT / step) * step
        while (y < viewB) { canvas.drawLine(viewL, y, viewR, y, gridPaint); y += step }
    }

    private fun drawLine(canvas: Canvas, line: MercatorLine, paint: Paint, w: Float, h: Float) {
        if (line.size < 2) return
        val ms = WebMercator.mapSize(zoom)
        val cx = WebMercator.lonToX(centerLon, zoom)
        val cy = WebMercator.latToY(centerLat, zoom)
        path.reset()
        var lastX = Float.NaN
        var lastY = Float.NaN
        var breakIdx = 0
        for (i in 0 until line.size) {
            val sx = (line.nx[i] * ms - cx + focalX(w)).toFloat()
            val sy = (line.ny[i] * ms - cy + h / 2).toFloat()
            val isBreak = breakIdx < line.breaks.size && line.breaks[breakIdx] == i
            if (isBreak) breakIdx++
            if (i == 0 || isBreak) {
                path.moveTo(sx, sy)
            } else {
                val dx = sx - lastX
                val dy = sy - lastY
                if (dx * dx + dy * dy < 2.25f && i != line.size - 1) continue
                path.lineTo(sx, sy)
            }
            lastX = sx
            lastY = sy
        }
        canvas.drawPath(path, paint)
    }

    private fun toScreenX(lon: Double, w: Float) = (WebMercator.lonToX(lon, zoom) - WebMercator.lonToX(centerLon, zoom) + focalX(w)).toFloat()
    private fun toScreenY(lat: Double, h: Float) = (WebMercator.latToY(lat, zoom) - WebMercator.latToY(centerLat, zoom) + h / 2).toFloat()

    private fun drawFacilities(canvas: Canvas, w: Float, h: Float) {
        if (zoom < 13) return
        var occupied = 0
        val radius = 10 * density
        for (item in facilities) {
            place(item.position, w, h)
            val x = px
            val y = py
            if (x < radius || y < radius || x > w - radius || y > h - radius) continue
            val left = x - 14 * density
            val top = y - 14 * density
            val right = x + 14 * density
            val bottom = y + 14 * density
            if ((0 until occupied).any { facilityBoxes[it].intersects(left, top, right, bottom) }) continue
            val box = if (occupied < facilityBoxes.size) facilityBoxes[occupied] else RectF().also { facilityBoxes.add(it) }
            box.set(left, top, right, bottom)
            occupied++
            canvas.drawCircle(x, y, radius + 2 * density, white)
            canvas.drawCircle(x, y, radius, facilityFill)
            canvas.drawText(item.category.glyph, x, y + facilityText.textSize * 0.35f, facilityText)
            if (zoom >= 16 && item.name.isNotBlank()) {
                val length = minOf(24, item.name.length)
                val labelLeft = x + 13 * density
                val labelTop = y - 9 * density
                val labelRight = labelLeft + labelPaint.measureText(item.name, 0, length)
                val labelBottom = y + 7 * density
                if (labelRight < w && (0 until occupied).none { facilityBoxes[it].intersects(labelLeft, labelTop, labelRight, labelBottom) }) {
                    val labelBox = if (occupied < facilityBoxes.size) facilityBoxes[occupied] else RectF().also { facilityBoxes.add(it) }
                    labelBox.set(labelLeft, labelTop, labelRight, labelBottom)
                    occupied++
                    canvas.drawText(item.name, 0, length, labelLeft, y + 4 * density, labelHalo)
                    canvas.drawText(item.name, 0, length, labelLeft, y + 4 * density, labelPaint)
                }
            }
        }
    }

    private fun drawDistanceMarks(canvas: Canvas, w: Float, h: Float) {
        if (distanceMarks.isEmpty()) return
        val every = DistanceMarks.every(distanceStepM / WebMercator.metresPerPixel(centerLat, zoom), 56.0 * density)
        val r = 8 * density
        for (k in every..distanceMarks.size step every) {
            place(distanceMarks[k - 1], w, h)
            val x = px
            val y = py
            if (x < -r || y < -r || x > w + r || y > h + r) continue
            val label = k.toString()
            val half = maxOf(r, markText.measureText(label) / 2 + 4 * density)
            dst.set(x - half, y - r, x + half, y + r)
            canvas.drawRoundRect(dst, r, r, white)
            canvas.drawRoundRect(dst, r, r, markRing)
            canvas.drawText(label, x, y + markText.textSize * 0.36f, markText)
        }
    }

    private fun drawWaypoints(canvas: Canvas, w: Float, h: Float) {
        var placed = 0
        for (m in waypoints) {
            place(m.position, w, h)
            val x = px
            val y = py
            if (x < -100 || y < -100 || x > w + 100 || y > h + 100) continue
            canvas.drawCircle(x, y, 7 * density, white)
            canvas.drawCircle(x, y, 5 * density, wpFill)
            if (zoom >= 12 && m.label.isNotBlank()) {
                val label = if (m.label.length > 24) m.label.take(23) + "…" else m.label
                val tw = labelPaint.measureText(label)
                val top = y - 8 * density
                val bottom = y + 7 * density
                // Right of the marker first, then left; a label that fits neither side is left out rather than overlapping.
                for (side in 0..1) {
                    val left = if (side == 0) x + 9 * density else x - 9 * density - tw
                    labelTry.set(left - 2 * density, top, left + tw + 2 * density, bottom)
                    var clash = false
                    for (i in 0 until placed) if (RectF.intersects(labelBoxes[i], labelTry)) { clash = true; break }
                    if (clash) continue
                    if (placed == labelBoxes.size) labelBoxes.add(RectF())
                    labelBoxes[placed++].set(labelTry)
                    canvas.drawText(label, left, y + 4 * density, labelHalo)
                    canvas.drawText(label, left, y + 4 * density, labelPaint)
                    break
                }
            }
        }
    }

    private fun drawHikers(canvas: Canvas, w: Float, h: Float) {
        if (hikers.isEmpty()) return
        val r = 11 * density
        for (m in hikers) {
            place(m.position, w, h)
            val x = px
            val y = py
            if (x < -60 || y < -60 || x > w + 60 || y > h + 60) continue
            if (m.help) canvas.drawCircle(x, y, r * 2f, hikerHelpHalo)
            canvas.drawCircle(x, y, r + 2.5f * density, white)
            hikerFill.color = if (m.help) Color.rgb(211, 47, 47) else m.colour
            when (m.age) {
                HikerMarker.Age.FRESH -> canvas.drawCircle(x, y, r, hikerFill)
                HikerMarker.Age.STALE -> {
                    hikerFill.alpha = 150
                    canvas.drawCircle(x, y, r, hikerFill)
                    canvas.drawCircle(x, y, r, hikerStale)
                }
                HikerMarker.Age.LAST_SEEN -> canvas.drawCircle(x, y, r - 1.25f * density, hikerLost)
            }
            if (m.relayed) canvas.drawCircle(x, y, r + 5 * density, hikerRelayed)
            hikerText.color = if (m.age == HikerMarker.Age.LAST_SEEN) Color.rgb(90, 90, 90) else Color.WHITE
            canvas.drawText(m.initials, x, y + hikerText.textSize * 0.36f, hikerText)
            if (zoom >= 11 && m.label.isNotBlank()) {
                val left = x + r + 6 * density
                canvas.drawText(m.label, left, y + 4 * density, labelHalo)
                canvas.drawText(m.label, left, y + 4 * density, labelPaint)
            }
        }
    }

    /** The trip-group member drawn within [radiusDp] of [at], nearest first. */
    fun hikerNear(at: LatLon, radiusDp: Float = 28f): HikerMarker? {
        val w = width.toFloat()
        val h = height.toFloat()
        place(at, w, h)
        val tx = px
        val ty = py
        var best: HikerMarker? = null
        var bestPx = radiusDp * density
        for (m in hikers) {
            place(m.position, w, h)
            val d = kotlin.math.hypot(px - tx, py - ty)
            if (d <= bestPx) {
                best = m
                bestPx = d
            }
        }
        return best
    }

    private fun drawTarget(canvas: Canvas, w: Float, h: Float) {
        val t = target ?: return
        position?.let { p ->
            place(p, w, h)
            val fromX = px
            val fromY = py
            place(t, w, h)
            canvas.drawLine(fromX, fromY, px, py, targetLine)
        }
        place(t, w, h)
        val x = px
        val y = py
        path.reset()
        val r = 9 * density
        path.moveTo(x, y)
        path.lineTo(x - r * 0.75f, y - r * 1.6f)
        path.lineTo(x + r * 0.75f, y - r * 1.6f)
        path.close()
        canvas.drawCircle(x, y - r * 1.9f, r + 2 * density, white)
        canvas.drawPath(path, targetFill)
        canvas.drawCircle(x, y - r * 1.9f, r, targetFill)
        canvas.drawCircle(x, y - r * 1.9f, r * 0.4f, white)
    }

    private fun drawSearchPin(canvas: Canvas, w: Float, h: Float) {
        val pin = searchPin ?: return
        place(pin.position, w, h)
        val x = px
        val y = py
        val r = 10 * density
        path.reset()
        path.moveTo(x, y)
        path.lineTo(x - r * 0.8f, y - r * 1.6f)
        path.lineTo(x + r * 0.8f, y - r * 1.6f)
        path.close()
        canvas.drawPath(path, white)
        canvas.drawCircle(x, y - r * 1.6f, r + 2 * density, white)
        canvas.drawPath(path, pinFill)
        canvas.drawCircle(x, y - r * 1.6f, r, pinFill)
        canvas.drawCircle(x, y - r * 1.6f, r * 0.35f, white)
        val label = pin.label.take(28)
        val left = (x + 14 * density).coerceAtMost(w - labelPaint.measureText(label) - 4 * density).coerceAtLeast(4 * density)
        canvas.drawText(label, left, y - 12 * density, labelHalo)
        canvas.drawText(label, left, y - 12 * density, labelPaint)
    }

    private fun drawPosition(canvas: Canvas, w: Float, h: Float) {
        val p = position ?: return
        place(p, w, h)
        val x = px
        val y = py
        val accPx = (accuracyM / WebMercator.metresPerPixel(p.lat, zoom)).toFloat()
        if (accPx > 8 * density) {
            canvas.drawCircle(x, y, accPx, accuracyFill)
            canvas.drawCircle(x, y, accPx, accuracyStroke)
        }
        headingDeg?.let { hd ->
            canvas.save()
            canvas.rotate(hd - bearing, x, y)
            path.reset()
            val len = 34 * density
            path.moveTo(x, y)
            path.lineTo(x - len * 0.42f, y - len)
            path.quadTo(x, y - len * 1.15f, x + len * 0.42f, y - len)
            path.close()
            canvas.drawPath(path, headingPaint)
            canvas.restore()
        }
        canvas.drawCircle(x, y, 9.5f * density, white)
        canvas.drawCircle(x, y, 7 * density, dotFill)
    }

    private fun drawScaleAndAttribution(canvas: Canvas, w: Float, fullH: Float) {
        val h = fullH - bottomChromePx
        val attr = source.attribution + if (facilities.isNotEmpty() && zoom >= 13) " · Facilities: © OpenStreetMap contributors" else ""
        val pad = 6 * density
        // The credit floats a little in from the corner, so a rounded map edge (the unfolded layout) never clips it.
        val left = coveredLeftPx + 12 * density
        val room = w - 2 * pad - left - 8 * density
        attrPaint.textSize = 10.5f * density
        var tw = attrPaint.measureText(attr)
        if (tw > room) { attrPaint.textSize *= room / tw; tw = attrPaint.measureText(attr) }
        val th = attrPaint.textSize
        val mpp = WebMercator.metresPerPixel(centerLat, zoom)
        val maxPx = 110 * density
        val imperial = TrailMindApp.instance.prefs.imperial
        val nice = if (imperial) NICE_FEET.map { it * 0.3048 } else NICE_METRES
        val metres = nice.lastOrNull { it / mpp <= maxPx } ?: nice.first()
        val px = (metres / mpp).toFloat()
        val credits = listOfNotNull(
            historic?.attribution.takeIf { historicDrawn },
            TerrainProvider.CREDIT.takeIf { showSteepGround && zoom >= STEEP_MIN_ZOOM },
            LidarProvider.CREDIT.takeIf { lidarDrawn },
        )
        val creditSizes = FloatArray(credits.size)
        var creditWidth = 0f
        credits.forEachIndexed { i, credit ->
            attrPaint.textSize = 10.5f * density
            var width = attrPaint.measureText(credit)
            if (width > room) {
                attrPaint.textSize *= room / width
                width = attrPaint.measureText(credit)
            }
            creditSizes[i] = attrPaint.textSize
            creditWidth = maxOf(creditWidth, width)
        }
        val attrHeight = th + creditSizes.sum() + pad * credits.size
        val plate = RectF(left, h - attrHeight - 2 * pad, left + maxOf(tw, creditWidth) + 2 * pad, h)
        canvas.drawRoundRect(plate, 9 * density, 9 * density, attrBg)
        creditBox.set(plate)
        attrPaint.textSize = th
        canvas.drawText(attr, left + pad, h - pad - 1 * density, attrPaint)
        var baseline = h - th - 2 * pad - 1 * density
        credits.forEachIndexed { i, credit ->
            attrPaint.textSize = creditSizes[i]
            canvas.drawText(credit, left + pad, baseline, attrPaint)
            baseline -= creditSizes[i] + pad
        }
        attrPaint.textSize = 10.5f * density
        val by = plate.top - 14 * density
        val bx = left + 6 * density
        canvas.drawRoundRect(bx - 6 * density, by - 16 * density, bx + px + 6 * density, by + 5 * density, 9 * density, 9 * density, attrBg)
        canvas.drawLine(bx, by, bx + px, by, scalePaint)
        canvas.drawLine(bx, by - 5 * density, bx, by, scalePaint)
        canvas.drawLine(bx + px, by - 5 * density, bx + px, by, scalePaint)
        canvas.drawText(Units.distance(metres, imperial), bx + 2 * density, by - 5 * density, attrPaint)
        logoBox.setEmpty()
        if (source.showsOsLogo) osLogo?.let { logo ->
            // OS branding: the logo sits on the map itself, bottom left, at its fixed size with clear space around it.
            val bottom = (by - 28 * density).toInt()
            val logoLeft = left.toInt()
            logo.setBounds(logoLeft, bottom - logo.intrinsicHeight, logoLeft + logo.intrinsicWidth, bottom)
            logo.draw(canvas)
            logoBox.set(logo.bounds)
        }
    }

    private fun drawHint(canvas: Canvas, text: String, w: Float, h: Float) {
        val available = (w - coveredLeftPx).coerceAtLeast(1f)
        val lines = wrap(text, available * 0.8f)
        val lh = hintPaint.textSize * 1.3f
        val boxH = lines.size * lh + 20 * density
        val top = h / 2 - boxH / 2
        canvas.drawRect(coveredLeftPx + available * 0.08f, top, w - available * 0.08f, top + boxH, attrBg)
        lines.forEachIndexed { i, l -> canvas.drawText(l, focalX(w), top + 10 * density + lh * (i + 0.8f), hintPaint) }
    }

    private fun wrap(text: String, maxW: Float): List<String> {
        val out = ArrayList<String>()
        var cur = StringBuilder()
        for (word in text.split(' ')) {
            val candidate = if (cur.isEmpty()) word else "$cur $word"
            if (hintPaint.measureText(candidate) > maxW && cur.isNotEmpty()) {
                out.add(cur.toString()); cur = StringBuilder(word)
            } else {
                cur = StringBuilder(candidate)
            }
        }
        if (cur.isNotEmpty()) out.add(cur.toString())
        return out
    }

    companion object {
        /** Below this the whole screen needs too many terrain tiles to shade steep ground. */
        const val STEEP_MIN_ZOOM = 13.0
        /** LiDAR squares already on the phone show from here, when few enough fill the screen... */
        const val LIDAR_MIN_ZOOM = 14.5
        /** ...and missing ones are downloaded only this close, where a screen needs a few megabytes, not tens. */
        const val LIDAR_FETCH_ZOOM = 16.5
        private val NICE_METRES = listOf(5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10_000.0, 20_000.0, 50_000.0, 100_000.0, 200_000.0, 500_000.0)
        private val NICE_FEET = listOf(20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2640.0, 5280.0, 10560.0, 26400.0, 52800.0, 105600.0, 264000.0, 528000.0)
    }
}
