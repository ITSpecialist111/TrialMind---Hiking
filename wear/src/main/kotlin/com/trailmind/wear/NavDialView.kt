package com.trailmind.wear

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.nav.DistanceMarks
import com.trailmind.core.nav.RouteGuide
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * The navigation face: a compass ring that turns with the watch, a pointer showing which way to go, and
 * your breadcrumb trail and route drawn around you. Heading-up by default, so the top is where you face.
 */
class NavDialView(ctx: Context) : View(ctx) {
    /** True heading of the watch's 12 o'clock; null without a compass (then the dial is north-up). */
    var headingDeg: Float? = null
        set(v) { if (field != v) { field = v; invalidate() } }
    var headingUp = true
        set(v) { if (field != v) { field = v; invalidate() } }
    var position: LatLon? = null
        set(v) { if (field != v) { field = v; invalidate() } }
    var route: List<LatLon> = emptyList()
        set(v) { field = v; updateMarks(); invalidate() }
    /** Distance marks go every mile rather than every kilometre. */
    var imperial = false
        set(v) { if (field != v) { field = v; updateMarks(); invalidate() } }
    var track: List<List<LatLon>> = emptyList()
        set(v) { field = v; invalidate() }
    var onTap: (() -> Unit)? = null

    private var marks: List<LatLon> = emptyList()
    private var pointerDeg: Double? = null
    private var scaleIndex = 2
    /** Metres from the centre to the edge of the breadcrumb plot. */
    val radiusM: Double get() = SCALES[scaleIndex]

    fun setPointer(bearingDeg: Double?, color: Int) {
        if (pointerDeg == bearingDeg && pointerFill.color == color) return
        pointerDeg = bearingDeg
        pointerFill.color = color
        pointerLine.color = color
        invalidate()
    }

    fun zoomBy(step: Int) {
        scaleIndex = (scaleIndex - step).coerceIn(0, SCALES.lastIndex)
        invalidate()
    }

    private fun updateMarks() {
        marks = if (route.size < 2) emptyList() else DistanceMarks.along(RouteGuide(route.map { TrackPoint(it.lat, it.lon) }), DistanceMarks.stepM(imperial))
    }

    private val density = resources.displayMetrics.density
    private fun dp(v: Float) = v * density
    private val bold = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    private val tickPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(120, 134, 126); strokeWidth = dp(2f); strokeCap = Paint.Cap.ROUND }
    private val letterPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textSize = dp(15f); textAlign = Paint.Align.CENTER; typeface = bold }
    private val northPaint = Paint(letterPaint).apply { color = Color.rgb(255, 99, 88) }
    private val routePaint = stroke(Color.argb(210, 199, 125, 219), 4f)
    private val trackPaint = stroke(Color.WHITE, 3f)
    private val pointerFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val pointerLine = stroke(Color.WHITE, 4f)
    private val youPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(255, 205, 64); style = Paint.Style.FILL }
    private val startPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(127, 209, 174); style = Paint.Style.FILL }
    private val markFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; style = Paint.Style.FILL }
    private val markRing = stroke(Color.rgb(199, 125, 219), 1.5f)
    private val markText = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textSize = dp(10f); textAlign = Paint.Align.CENTER; typeface = bold }
    private val rect = RectF()
    private val path = Path()
    private val clip = Path()
    private val pt = FloatArray(2)

    private fun stroke(color: Int, widthDp: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        style = Paint.Style.STROKE
        strokeWidth = dp(widthDp)
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
    }

    private val gestures = GestureDetector(ctx, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true
        override fun onSingleTapUp(e: MotionEvent): Boolean { onTap?.invoke(); return true }
    })

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent) = gestures.onTouchEvent(event)

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val ringR = min(cx, cy) - dp(6f)
        val plotR = ringR - dp(24f)
        val up = if (headingUp) (headingDeg ?: 0f).toDouble() else 0.0
        val upRad = Math.toRadians(up)
        val cu = cos(upRad)
        val su = sin(upRad)

        position?.let { here ->
            val k = plotR / radiusM
            val cosLat = cos(Math.toRadians(here.lat))
            // Local east/north metres, rotated so the bearing [up] points to the top of the screen.
            fun project(p: LatLon) {
                val dx = (p.lon - here.lon) * 111_320.0 * cosLat
                val dy = (p.lat - here.lat) * 110_574.0
                pt[0] = cx + ((dx * cu - dy * su) * k).toFloat()
                pt[1] = cy - ((dx * su + dy * cu) * k).toFloat()
            }
            fun line(points: List<LatLon>, paint: Paint) {
                if (points.size < 2) return
                path.reset()
                points.forEachIndexed { i, p -> project(p); if (i == 0) path.moveTo(pt[0], pt[1]) else path.lineTo(pt[0], pt[1]) }
                canvas.drawPath(path, paint)
            }
            canvas.save()
            clip.reset()
            clip.addCircle(cx, cy, plotR, Path.Direction.CW)
            canvas.clipPath(clip)
            line(route, routePaint)
            track.forEach { line(it, trackPaint) }
            track.firstOrNull()?.firstOrNull()?.let { project(it); canvas.drawCircle(pt[0], pt[1], dp(5f), startPaint) }
            val every = DistanceMarks.every(DistanceMarks.stepM(imperial) * k, dp(28f).toDouble())
            val r = dp(7f)
            for (i in every..marks.size step every) {
                project(marks[i - 1])
                val label = i.toString()
                val half = maxOf(r, markText.measureText(label) / 2 + dp(3f))
                rect.set(pt[0] - half, pt[1] - r, pt[0] + half, pt[1] + r)
                canvas.drawRoundRect(rect, r, r, markFill)
                canvas.drawRoundRect(rect, r, r, markRing)
                canvas.drawText(label, pt[0], pt[1] + markText.textSize * 0.36f, markText)
            }
            canvas.restore()
        }

        for (b in 0 until 360 step 30) {
            val a = Math.toRadians(b - up)
            if (b % 90 == 0) {
                val r = ringR - dp(10f)
                val paint = if (b == 0) northPaint else letterPaint
                canvas.drawText(LETTERS[b / 90], cx + (sin(a) * r).toFloat(), cy - (cos(a) * r).toFloat() - (paint.ascent() + paint.descent()) / 2, paint)
            } else {
                val r0 = ringR - dp(8f)
                canvas.drawLine(cx + (sin(a) * r0).toFloat(), cy - (cos(a) * r0).toFloat(), cx + (sin(a) * ringR).toFloat(), cy - (cos(a) * ringR).toFloat(), tickPaint)
            }
        }

        pointerDeg?.let { b ->
            val a = Math.toRadians(b - up)
            val sa = sin(a).toFloat()
            val ca = cos(a).toFloat()
            canvas.drawLine(cx + sa * dp(16f), cy - ca * dp(16f), cx + sa * (plotR - dp(10f)), cy - ca * (plotR - dp(10f)), pointerLine)
            // Arrowhead at the edge of the plot, pointing outwards along the bearing.
            val tipX = cx + sa * (plotR + dp(4f))
            val tipY = cy - ca * (plotR + dp(4f))
            val baseX = cx + sa * (plotR - dp(18f))
            val baseY = cy - ca * (plotR - dp(18f))
            val w = dp(11f)
            path.reset()
            path.moveTo(tipX, tipY)
            path.lineTo(baseX + ca * w, baseY + sa * w)
            path.lineTo(baseX - ca * w, baseY - sa * w)
            path.close()
            canvas.drawPath(path, pointerFill)
        }

        // You: a chevron pointing the way you face, or a dot when there is no compass.
        val heading = headingDeg
        if (heading == null) {
            canvas.drawCircle(cx, cy, dp(7f), youPaint)
            return
        }
        canvas.save()
        canvas.rotate(if (headingUp) 0f else heading, cx, cy)
        val s = dp(11f)
        path.reset()
        path.moveTo(cx, cy - s)
        path.lineTo(cx + s * 0.75f, cy + s * 0.8f)
        path.lineTo(cx, cy + s * 0.35f)
        path.lineTo(cx - s * 0.75f, cy + s * 0.8f)
        path.close()
        canvas.drawPath(path, youPaint)
        canvas.restore()
    }

    companion object {
        private val LETTERS = arrayOf("N", "E", "S", "W")
        private val SCALES = doubleArrayOf(100.0, 250.0, 500.0, 1_000.0, 2_500.0, 5_000.0)
    }
}
