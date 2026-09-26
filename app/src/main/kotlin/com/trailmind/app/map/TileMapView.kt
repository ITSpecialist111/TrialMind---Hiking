package com.trailmind.app.map

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import com.trailmind.app.TrailMindApp
import com.trailmind.core.format.Units
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.TileKey
import com.trailmind.core.geo.WebMercator
import com.trailmind.core.nav.DistanceMarks
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.pow

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

/**
 * Framework-only slippy map: raster tiles, pinch/drag/double-tap, route + breadcrumb overlays,
 * position with accuracy and heading, scale bar and attribution. North-up.
 */
@SuppressLint("ViewConstructor")
class TileMapView(context: Context) : View(context) {

    interface Listener {
        fun onCameraChanged() {}
        fun onLongPress(at: LatLon) {}
        fun onFollowChanged(follow: Boolean) {}
    }

    private val provider = TrailMindApp.instance.tiles
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
    val maxZoom get() = (source.maxZoom + 2).toDouble().coerceAtMost(21.0)

    var route: MercatorLine? = null
        set(v) { field = v; invalidate() }
    /** Points along [route] every [distanceStepM]; element i is labelled i + 1. */
    var distanceMarks: List<LatLon> = emptyList()
        set(v) { field = v; invalidate() }
    var distanceStepM = 1000.0
    var track: MercatorLine? = null
        set(v) { field = v; invalidate() }
    var waypoints: List<MapMarker> = emptyList()
        set(v) { field = v; invalidate() }
    var target: LatLon? = null
        set(v) { field = v; invalidate() }

    var position: LatLon? = null; private set
    private var accuracyM = 0f
    var headingDeg: Float? = null
        set(v) { field = v; if (position != null) invalidate() }

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
        set(v) { field = v; invalidate() }

    private val tileListener: () -> Unit = { invalidate() }

    // --- paints (allocated once)
    private val tilePaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val gridPaint = Paint().apply { color = Color.rgb(226, 230, 222); strokeWidth = 1f }
    private val bgColor = Color.rgb(238, 241, 234)
    private val routeCasing = strokePaint(Color.WHITE, 8f)
    private val routePaint = strokePaint(Color.rgb(142, 36, 170), 5f)
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
    private val markRing = strokePaint(Color.rgb(142, 36, 170), 1.5f)
    private val markText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(142, 36, 170); textSize = 10 * density; isFakeBoldText = true; textAlign = Paint.Align.CENTER
    }
    private val targetFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(211, 47, 47) }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(30, 30, 30); textSize = 12 * density; isFakeBoldText = true
    }
    private val labelHalo = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textSize = 12 * density; isFakeBoldText = true; style = Paint.Style.STROKE; strokeWidth = 3 * density
    }
    private val attrPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(40, 40, 40); textSize = 10.5f * density }
    private val attrBg = Paint().apply { color = Color.argb(200, 255, 255, 255) }
    private val scalePaint = strokePaint(Color.rgb(30, 30, 30), 2f).apply { strokeCap = Paint.Cap.SQUARE }
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(60, 60, 60); textSize = 14 * density; textAlign = Paint.Align.CENTER
    }

    private fun strokePaint(c: Int, widthDp: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = c; style = Paint.Style.STROKE; strokeWidth = widthDp * density
        strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND
    }

    private val dst = RectF()
    private val src = Rect()
    private val path = Path()
    private val labelBoxes = ArrayList<RectF>()
    private val labelTry = RectF()

    // --- camera

    fun setCenter(lat: Double, lon: Double, newZoom: Double = zoom) {
        centerLat = lat.coerceIn(-WebMercator.MAX_LAT, WebMercator.MAX_LAT)
        centerLon = com.trailmind.core.geo.Geo.normalizeLon(lon)
        zoom = newZoom.coerceIn(minZoom, maxZoom)
        invalidate()
        listener?.onCameraChanged()
    }

    fun zoomBy(dz: Double) = zoomAround(width / 2f, height / 2f, dz)

    fun fitBounds(b: BoundingBox, paddingPx: Float = 48 * density) {
        if (width == 0 || height == 0) {
            post { fitBounds(b, paddingPx) }
            return
        }
        val c = b.center
        var z = maxZoom.coerceAtMost(17.0)
        while (z > minZoom) {
            val w = WebMercator.lonToX(b.maxLon, z) - WebMercator.lonToX(b.minLon, z)
            val h = WebMercator.latToY(b.minLat, z) - WebMercator.latToY(b.maxLat, z)
            if (w <= width - 2 * paddingPx && h <= height - 2 * paddingPx) break
            z -= 0.25
        }
        follow = false
        setCenter(c.lat, c.lon, z)
    }

    fun visibleBounds(): BoundingBox {
        val nw = screenToLatLon(0f, 0f)
        val se = screenToLatLon(width.toFloat(), height.toFloat())
        return BoundingBox(se.lat, nw.lon, nw.lat, se.lon)
    }

    fun setPosition(p: LatLon?, accuracy: Float) {
        position = p
        accuracyM = accuracy
        if (follow && p != null) setCenter(p.lat, p.lon) else invalidate()
    }

    fun screenToLatLon(sx: Float, sy: Float): LatLon {
        val wx = WebMercator.lonToX(centerLon, zoom) + (sx - width / 2.0)
        val wy = WebMercator.latToY(centerLat, zoom) + (sy - height / 2.0)
        return LatLon(WebMercator.yToLat(wy, zoom), WebMercator.xToLon(wx, zoom))
    }

    private fun zoomAround(fx: Float, fy: Float, dz: Double) {
        val anchor = screenToLatLon(fx, fy)
        val nz = (zoom + dz).coerceIn(minZoom, maxZoom)
        val ax = WebMercator.lonToX(anchor.lon, nz)
        val ay = WebMercator.latToY(anchor.lat, nz)
        val cx = ax - (fx - width / 2.0)
        val cy = ay - (fy - height / 2.0)
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
        val cx = WebMercator.lonToX(centerLon, zoom) + dx
        val cy = (WebMercator.latToY(centerLat, zoom) + dy).coerceIn(0.0, WebMercator.mapSize(zoom))
        setCenter(WebMercator.yToLat(cy, zoom), WebMercator.xToLon(cx, zoom))
    }

    // --- gestures

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
            zoomAround(e.x, e.y, 1.0)
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
    }

    override fun onDetachedFromWindow() {
        provider.removeListener(tileListener)
        super.onDetachedFromWindow()
    }

    // --- drawing

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(bgColor)
        val w = width.toFloat()
        val h = height.toFloat()
        drawTiles(canvas, w, h)
        route?.let { drawLine(canvas, it, routeCasing, w, h); drawLine(canvas, it, routePaint, w, h) }
        track?.let { drawLine(canvas, it, trackPaint, w, h) }
        drawDistanceMarks(canvas, w, h)
        drawWaypoints(canvas, w, h)
        drawTarget(canvas, w, h)
        drawPosition(canvas, w, h)
        drawScaleAndAttribution(canvas, w, h)
        hint?.let { drawHint(canvas, it, w, h) }
    }

    private fun drawTiles(canvas: Canvas, w: Float, h: Float) {
        val src0 = source
        val zf = floor(zoom).toInt()
        if (zf < src0.minZoom) {
            drawGrid(canvas, w, h)
            drawHint(canvas, "Zoom in to show ${src0.name}", w, h)
            return
        }
        val zi = zf.coerceAtMost(src0.maxZoom)
        val scale = 2.0.pow(zoom - zi)
        val ts = WebMercator.TILE_SIZE
        val size = (ts * scale).toFloat()
        val cx = WebMercator.lonToX(centerLon, zi.toDouble())
        val cy = WebMercator.latToY(centerLat, zi.toDouble())
        val x0 = floor((cx - w / 2 / scale) / ts).toInt()
        val x1 = floor((cx + w / 2 / scale) / ts).toInt()
        val y0 = floor((cy - h / 2 / scale) / ts).toInt()
        val y1 = floor((cy + h / 2 / scale) / ts).toInt()
        val n = 1 shl zi
        for (tx in x0..x1) for (ty in y0..y1) {
            if (ty < 0 || ty >= n) continue
            val wx = Math.floorMod(tx, n)
            val left = ((tx * ts - cx) * scale + w / 2).toFloat()
            val top = ((ty * ts - cy) * scale + h / 2).toFloat()
            dst.set(left, top, left + size + 0.5f, top + size + 0.5f)
            val key = TileKey(zi, wx, ty)
            val bmp = provider.cached(src0, key)
            if (bmp != null) {
                canvas.drawBitmap(bmp, null, dst, tilePaint)
                if (provider.isApproximate(src0, key)) provider.request(src0, key)
            } else {
                provider.request(src0, key)
                if (!drawFallback(canvas, src0, key)) {
                    canvas.drawLine(dst.left, dst.top, dst.right, dst.top, gridPaint)
                    canvas.drawLine(dst.left, dst.top, dst.left, dst.bottom, gridPaint)
                }
            }
        }
    }

    private fun drawFallback(canvas: Canvas, s: TileSource, key: TileKey): Boolean {
        for (d in 1..4) {
            val pz = key.z - d
            if (pz < s.minZoom || pz < 0) return false
            val pk = TileKey(pz, key.x shr d, key.y shr d)
            val pb = provider.cached(s, pk) ?: continue
            val f = pb.width / WebMercator.TILE_SIZE.toFloat()
            val sub = WebMercator.TILE_SIZE shr d
            val sx = (key.x - (pk.x shl d)) * sub
            val sy = (key.y - (pk.y shl d)) * sub
            src.set((sx * f).toInt(), (sy * f).toInt(), ((sx + sub) * f).toInt(), ((sy + sub) * f).toInt())
            canvas.drawBitmap(pb, src, dst, tilePaint)
            return true
        }
        return false
    }

    private fun drawGrid(canvas: Canvas, w: Float, h: Float) {
        val step = 64 * density
        var x = 0f
        while (x < w) { canvas.drawLine(x, 0f, x, h, gridPaint); x += step }
        var y = 0f
        while (y < h) { canvas.drawLine(0f, y, w, y, gridPaint); y += step }
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
            val sx = (line.nx[i] * ms - cx + w / 2).toFloat()
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

    private fun toScreenX(lon: Double, w: Float) = (WebMercator.lonToX(lon, zoom) - WebMercator.lonToX(centerLon, zoom) + w / 2).toFloat()
    private fun toScreenY(lat: Double, h: Float) = (WebMercator.latToY(lat, zoom) - WebMercator.latToY(centerLat, zoom) + h / 2).toFloat()

    private fun drawDistanceMarks(canvas: Canvas, w: Float, h: Float) {
        if (distanceMarks.isEmpty()) return
        val every = DistanceMarks.every(distanceStepM / WebMercator.metresPerPixel(centerLat, zoom), 56.0 * density)
        val r = 8 * density
        for (k in every..distanceMarks.size step every) {
            val m = distanceMarks[k - 1]
            val x = toScreenX(m.lon, w)
            val y = toScreenY(m.lat, h)
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
            val x = toScreenX(m.position.lon, w)
            val y = toScreenY(m.position.lat, h)
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

    private fun drawTarget(canvas: Canvas, w: Float, h: Float) {
        val t = target ?: return
        val x = toScreenX(t.lon, w)
        val y = toScreenY(t.lat, h)
        position?.let { p -> canvas.drawLine(toScreenX(p.lon, w), toScreenY(p.lat, h), x, y, targetLine) }
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

    private fun drawPosition(canvas: Canvas, w: Float, h: Float) {
        val p = position ?: return
        val x = toScreenX(p.lon, w)
        val y = toScreenY(p.lat, h)
        val accPx = (accuracyM / WebMercator.metresPerPixel(p.lat, zoom)).toFloat()
        if (accPx > 8 * density) {
            canvas.drawCircle(x, y, accPx, accuracyFill)
            canvas.drawCircle(x, y, accPx, accuracyStroke)
        }
        headingDeg?.let { hd ->
            canvas.save()
            canvas.rotate(hd, x, y)
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
        val attr = source.attribution
        val pad = 6 * density
        attrPaint.textSize = 10.5f * density
        var tw = attrPaint.measureText(attr)
        if (tw > w - 2 * pad) { attrPaint.textSize *= (w - 2 * pad) / tw; tw = attrPaint.measureText(attr) }
        val th = attrPaint.textSize
        canvas.drawRect(0f, h - th - 2 * pad, tw + 2 * pad, h, attrBg)
        canvas.drawText(attr, pad, h - pad - 1 * density, attrPaint)
        attrPaint.textSize = 10.5f * density

        val mpp = WebMercator.metresPerPixel(centerLat, zoom)
        val maxPx = 110 * density
        val imperial = TrailMindApp.instance.prefs.imperial
        val nice = if (imperial) NICE_FEET.map { it * 0.3048 } else NICE_METRES
        val metres = nice.lastOrNull { it / mpp <= maxPx } ?: nice.first()
        val px = (metres / mpp).toFloat()
        val by = h - th - 2 * pad - 10 * density
        val bx = 12 * density
        canvas.drawRect(bx - 4 * density, by - 16 * density, bx + px + 4 * density, by + 5 * density, attrBg)
        canvas.drawLine(bx, by, bx + px, by, scalePaint)
        canvas.drawLine(bx, by - 5 * density, bx, by, scalePaint)
        canvas.drawLine(bx + px, by - 5 * density, bx + px, by, scalePaint)
        canvas.drawText(Units.distance(metres, imperial), bx + 2 * density, by - 5 * density, attrPaint)
    }

    private fun drawHint(canvas: Canvas, text: String, w: Float, h: Float) {
        val lines = wrap(text, w * 0.8f)
        val lh = hintPaint.textSize * 1.3f
        val boxH = lines.size * lh + 20 * density
        val top = h / 2 - boxH / 2
        canvas.drawRect(w * 0.08f, top, w * 0.92f, top + boxH, attrBg)
        lines.forEachIndexed { i, l -> canvas.drawText(l, w / 2, top + 10 * density + lh * (i + 0.8f), hintPaint) }
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
        private val NICE_METRES = listOf(5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10_000.0, 20_000.0, 50_000.0, 100_000.0, 200_000.0, 500_000.0)
        private val NICE_FEET = listOf(20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2640.0, 5280.0, 10560.0, 26400.0, 52800.0, 105600.0, 264000.0, 528000.0)
    }
}
