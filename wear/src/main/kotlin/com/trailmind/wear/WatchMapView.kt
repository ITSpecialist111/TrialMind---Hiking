package com.trailmind.wear

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.os.SystemClock
import android.util.LruCache
import android.util.TypedValue
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.WebMercator
import com.trailmind.core.watch.TileRequest
import kotlin.math.floor

/** Normalised Web Mercator (0..1) copy of a line, so drawing needs no trigonometry per frame. */
private class Line(points: List<LatLon>) {
    val nx = DoubleArray(points.size) { (points[it].lon + 180.0) / 360.0 }
    val ny = DoubleArray(points.size) { WebMercator.latToY(points[it].lat, 0.0) / WebMercator.TILE_SIZE }
    val size get() = nx.size
}

/**
 * North-up raster map for the watch. Tiles come from the phone (including its offline packs); zoom is in
 * whole levels from the bezel or the +/- buttons; a tap switches between following you and a route overview.
 */
@SuppressLint("ViewConstructor")
class WatchMapView(ctx: Context, private val requestTile: (TileRequest) -> Unit) : View(ctx) {
    private val density = resources.displayMetrics.density
    // Raster tiles are drawn larger than 1:1 so their labels stay legible on a ~1.4" screen.
    private val tileScale = maxOf(1f, density * 0.7f)
    private val tilePx = WebMercator.TILE_SIZE * tileScale

    var onTap: (() -> Unit)? = null
    var mapKey = ""; private set
    private var attribution = ""
    private var minZoom = 0
    private var maxZoom = 19
    var zoom = 15; private set
    var follow = true; private set
    private var centerLat = 54.5
    private var centerLon = -3.0
    private var position: LatLon? = null
    private var accuracyM = 0f
    var headingDeg: Float? = null
        set(v) { field = v; invalidate() }
    private var route = Line(emptyList())
    private var routeBounds: List<LatLon> = emptyList()
    private var waypoints: List<LatLon> = emptyList()
    private var track: List<Line> = emptyList()
    private var trackBounds: List<LatLon> = emptyList()
    private var next: LatLon? = null
    private var target: LatLon? = null

    private val cache = object : LruCache<String, Bitmap>(12 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }
    // Request time per tile; the phone drops stale requests without replying, so these expire.
    private val pending = HashMap<String, Long>()
    private val retryAt = HashMap<String, Long>()

    private val tilePaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val gridPaint = Paint().apply { color = Color.rgb(48, 54, 51); strokeWidth = 1f }
    private val routeCasing = stroke(Color.WHITE, 6f)
    private val routePaint = stroke(Color.rgb(170, 60, 200), 3.5f)
    private val trackPaint = stroke(Color.rgb(255, 128, 32), 3f)
    private val dotFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(33, 150, 243) }
    private val white = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val headingPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(130, 33, 150, 243) }
    private val accuracyFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(50, 33, 150, 243) }
    private val wpFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(170, 60, 200) }
    private val nextRing = stroke(Color.rgb(255, 176, 102), 3f)
    private val targetFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(229, 57, 53) }
    private val attrPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textAlign = Paint.Align.CENTER }
    private val attrBg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(170, 0, 0, 0) }
    private var attrLines: List<String> = emptyList()
    private var attrHalfWidth = 0f
    private val dst = RectF()
    private val src = Rect()
    private val path = Path()

    private fun stroke(c: Int, widthDp: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = c; style = Paint.Style.STROKE; strokeWidth = widthDp * density
        strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND
    }

    private val gestures = GestureDetector(ctx, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true
        override fun onSingleTapUp(e: MotionEvent): Boolean { onTap?.invoke(); return true }
    })

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent) = gestures.onTouchEvent(event)

    fun setSource(key: String, attribution: String, minZoom: Int, maxZoom: Int) {
        if (key != mapKey) {
            mapKey = key
            cache.evictAll()
            pending.clear()
            retryAt.clear()
        }
        this.attribution = attribution
        this.minZoom = minZoom.coerceAtLeast(MIN_ZOOM)
        this.maxZoom = maxZoom.coerceAtLeast(this.minZoom)
        zoom = zoom.coerceIn(this.minZoom, this.maxZoom)
        layoutAttribution()
        invalidate()
    }

    fun setPosition(p: LatLon?, accuracy: Float) {
        position = p
        accuracyM = accuracy
        invalidate()
    }

    fun setRoute(points: List<LatLon>, wps: List<LatLon>) {
        route = Line(points)
        routeBounds = points
        waypoints = wps
        if (!follow) fitOverview()
        invalidate()
    }

    fun setTrack(segments: List<List<LatLon>>) {
        track = segments.map { Line(it) }
        trackBounds = segments.flatten()
        invalidate()
    }

    fun setMarkers(next: LatLon?, target: LatLon?) {
        this.next = next
        this.target = target
        invalidate()
    }

    fun zoomBy(dz: Int) {
        zoom = (zoom + dz).coerceIn(minZoom, maxZoom)
        invalidate()
    }

    /** Switches between following you and an overview of the route (or the track). Returns true when following. */
    fun toggleFollow(): Boolean {
        follow = !follow
        if (!follow) fitOverview()
        invalidate()
        return follow
    }

    fun onTile(req: TileRequest, bmp: Bitmap?) {
        val id = id(req.z, req.x, req.y)
        pending.remove(id)
        if (req.mapKey != mapKey) return
        if (bmp != null) cache.put(id, bmp) else retryAt[id] = SystemClock.uptimeMillis() + RETRY_MS
        invalidate()
    }

    /** Requests in flight are lost when the Bluetooth link drops; ask again after reconnecting. */
    fun linkChanged() {
        pending.clear()
        invalidate()
    }

    private fun id(z: Int, x: Int, y: Int) = "$z/$x/$y"

    private fun fitOverview() {
        val pts = routeBounds.ifEmpty { trackBounds }.ifEmpty { listOfNotNull(position) }
        if (pts.isEmpty() || width == 0) return
        val minLat = pts.minOf { it.lat }
        val maxLat = pts.maxOf { it.lat }
        val minLon = pts.minOf { it.lon }
        val maxLon = pts.maxOf { it.lon }
        centerLat = (minLat + maxLat) / 2
        centerLon = (minLon + maxLon) / 2
        var z = maxZoom.coerceAtMost(17)
        // The inscribed square of a round screen is ~70% of its width; leave a little margin inside it.
        while (z > minZoom) {
            val w = (WebMercator.lonToX(maxLon, z.toDouble()) - WebMercator.lonToX(minLon, z.toDouble())) * tileScale
            val h = (WebMercator.latToY(minLat, z.toDouble()) - WebMercator.latToY(maxLat, z.toDouble())) * tileScale
            if (w <= width * 0.6 && h <= height * 0.6) break
            z--
        }
        zoom = z
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        layoutAttribution()
        if (!follow) fitOverview()
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Color.rgb(28, 32, 30))
        val w = width.toFloat()
        val h = height.toFloat()
        if (follow) position?.let { centerLat = it.lat; centerLon = it.lon }
        val mapSize = WebMercator.mapSize(zoom.toDouble()) * tileScale
        val cx = WebMercator.lonToX(centerLon, zoom.toDouble()) * tileScale
        val cy = WebMercator.latToY(centerLat, zoom.toDouble()) * tileScale
        drawTiles(canvas, w, h, cx, cy)
        drawLine(canvas, route, routeCasing, mapSize, cx, cy, w, h)
        drawLine(canvas, route, routePaint, mapSize, cx, cy, w, h)
        for (seg in track) drawLine(canvas, seg, trackPaint, mapSize, cx, cy, w, h)
        for (p in waypoints) {
            val x = sx(p, cx, w)
            val y = sy(p, cy, h)
            canvas.drawCircle(x, y, 5 * density, white)
            canvas.drawCircle(x, y, 3.5f * density, wpFill)
        }
        next?.let { canvas.drawCircle(sx(it, cx, w), sy(it, cy, h), 8 * density, nextRing) }
        target?.let { canvas.drawCircle(sx(it, cx, w), sy(it, cy, h), 6 * density, targetFill) }
        drawPosition(canvas, cx, cy, w, h)
        drawAttribution(canvas, w, h)
    }

    private fun sx(p: LatLon, cx: Double, w: Float) = (WebMercator.lonToX(p.lon, zoom.toDouble()) * tileScale - cx + w / 2).toFloat()
    private fun sy(p: LatLon, cy: Double, h: Float) = (WebMercator.latToY(p.lat, zoom.toDouble()) * tileScale - cy + h / 2).toFloat()

    private fun drawTiles(canvas: Canvas, w: Float, h: Float, cx: Double, cy: Double) {
        val n = 1 shl zoom
        val x0 = floor((cx - w / 2) / tilePx).toInt()
        val x1 = floor((cx + w / 2) / tilePx).toInt()
        val y0 = floor((cy - h / 2) / tilePx).toInt()
        val y1 = floor((cy + h / 2) / tilePx).toInt()
        val now = SystemClock.uptimeMillis()
        val expired = pending.entries.iterator()
        while (expired.hasNext()) if (now - expired.next().value > PENDING_TIMEOUT_MS) expired.remove()
        for (ty in y0..y1) for (tx in x0..x1) {
            if (ty < 0 || ty >= n) continue
            val wx = Math.floorMod(tx, n)
            val left = (tx * tilePx - cx + w / 2).toFloat()
            val top = (ty * tilePx - cy + h / 2).toFloat()
            dst.set(left, top, left + tilePx + 0.5f, top + tilePx + 0.5f)
            val id = id(zoom, wx, ty)
            val bmp = cache.get(id)
            if (bmp != null) { canvas.drawBitmap(bmp, null, dst, tilePaint); continue }
            if (!drawParent(canvas, wx, ty)) {
                canvas.drawLine(dst.left, dst.top, dst.right, dst.top, gridPaint)
                canvas.drawLine(dst.left, dst.top, dst.left, dst.bottom, gridPaint)
            }
            if (mapKey.isNotEmpty() && id !in pending && (retryAt[id] ?: 0L) <= now && pending.size < MAX_IN_FLIGHT) {
                pending[id] = now
                requestTile(TileRequest(mapKey, zoom, wx, ty))
            }
        }
    }

    /** Stretches a cached lower-zoom tile into the gap while the sharper one is on its way. */
    private fun drawParent(canvas: Canvas, x: Int, y: Int): Boolean {
        for (d in 1..3) {
            val pz = zoom - d
            if (pz < minZoom) return false
            val px = x shr d
            val py = y shr d
            val pb = cache.get(id(pz, px, py)) ?: continue
            val f = pb.width / WebMercator.TILE_SIZE.toFloat()
            val sub = WebMercator.TILE_SIZE shr d
            val ox = (x - (px shl d)) * sub
            val oy = (y - (py shl d)) * sub
            src.set((ox * f).toInt(), (oy * f).toInt(), ((ox + sub) * f).toInt(), ((oy + sub) * f).toInt())
            canvas.drawBitmap(pb, src, dst, tilePaint)
            return true
        }
        return false
    }

    private fun drawLine(canvas: Canvas, line: Line, paint: Paint, mapSize: Double, cx: Double, cy: Double, w: Float, h: Float) {
        if (line.size < 2) return
        path.reset()
        for (i in 0 until line.size) {
            val x = (line.nx[i] * mapSize - cx + w / 2).toFloat()
            val y = (line.ny[i] * mapSize - cy + h / 2).toFloat()
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        canvas.drawPath(path, paint)
    }

    private fun drawPosition(canvas: Canvas, cx: Double, cy: Double, w: Float, h: Float) {
        val p = position ?: return
        val x = sx(p, cx, w)
        val y = sy(p, cy, h)
        val accPx = (accuracyM / (WebMercator.metresPerPixel(p.lat, zoom.toDouble()) / tileScale)).toFloat()
        if (accPx > 8 * density) canvas.drawCircle(x, y, accPx, accuracyFill)
        headingDeg?.let { hd ->
            canvas.save()
            canvas.rotate(hd, x, y)
            val len = 26 * density
            path.reset()
            path.moveTo(x, y)
            path.lineTo(x - len * 0.42f, y - len)
            path.quadTo(x, y - len * 1.15f, x + len * 0.42f, y - len)
            path.close()
            canvas.drawPath(path, headingPaint)
            canvas.restore()
        }
        canvas.drawCircle(x, y, 7.5f * density, white)
        canvas.drawCircle(x, y, 5.5f * density, dotFill)
    }

    /** Licence attribution, kept inside the round screen's visible chord near the bottom. */
    private fun drawAttribution(canvas: Canvas, w: Float, h: Float) {
        if (attrLines.isEmpty()) return
        val lh = attrPaint.textSize * 1.15f
        val bottom = h * 0.9f
        val top = bottom - lh * attrLines.size - 4 * density
        canvas.drawRoundRect(w / 2 - attrHalfWidth, top, w / 2 + attrHalfWidth, bottom, 6 * density, 6 * density, attrBg)
        for (i in attrLines.indices) canvas.drawText(attrLines[i], w / 2, top + 2 * density + lh * (i + 0.82f), attrPaint)
    }

    private fun layoutAttribution() {
        attrLines = emptyList()
        if (attribution.isBlank() || width == 0) return
        attrPaint.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 9f, resources.displayMetrics)
        val maxW = width * 0.62f
        val lines = if (attrPaint.measureText(attribution) <= maxW) listOf(attribution) else splitInTwo(attribution)
        val widest = lines.maxOf { attrPaint.measureText(it) }
        if (widest > maxW) attrPaint.textSize *= maxW / widest
        attrLines = lines
        attrHalfWidth = lines.maxOf { attrPaint.measureText(it) } / 2 + 6 * density
    }

    private fun splitInTwo(s: String): List<String> {
        val mid = s.length / 2
        val cut = (0 until s.length).filter { s[it] == ' ' }.minByOrNull { kotlin.math.abs(it - mid) } ?: return listOf(s)
        return listOf(s.substring(0, cut), s.substring(cut + 1))
    }

    companion object {
        private const val MIN_ZOOM = 3
        private const val MAX_IN_FLIGHT = 8
        private const val RETRY_MS = 30_000L
        private const val PENDING_TIMEOUT_MS = 8_000L
    }
}
