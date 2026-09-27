package com.trailmind.app.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.graphics.Typeface
import android.view.View
import com.trailmind.core.format.Units
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.TrackPoint
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Distance/elevation profile with optional "you are here" cursor. */
@SuppressLint("ViewConstructor")
class ElevationProfileView(context: Context, private val imperial: Boolean) : View(context) {
    private val p = Palette.of(context)
    private val d = resources.displayMetrics.density
    private var dist = DoubleArray(0)
    private var ele = DoubleArray(0)
    var cursorM: Double? = null
        set(v) { field = v; invalidate() }

    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 2.5f * d; color = p.primary; strokeJoin = Paint.Join.ROUND
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val grid = Paint().apply { color = p.outline; strokeWidth = 1f }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.muted; textSize = 11 * d }
    private val cursor = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.accent; strokeWidth = 2 * d }
    private val path = Path()
    private val fillPath = Path()
    private var shaderSpan = Float.NaN

    val hasData get() = ele.size >= 2

    fun setPoints(points: List<TrackPoint>) {
        val withEle = points.filter { it.ele != null }
        if (withEle.size < 2) { dist = DoubleArray(0); ele = DoubleArray(0); invalidate(); return }
        // Downsample to at most ~600 samples for drawing.
        val step = max(1, withEle.size / 600)
        val cum = Geo.cumulativeDistances(points)
        val idx = points.indices.filter { points[it].ele != null }.filterIndexed { i, _ -> i % step == 0 }
        dist = DoubleArray(idx.size) { cum[idx[it]] }
        ele = DoubleArray(idx.size) { points[idx[it]].ele!! }
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        setMeasuredDimension(w, (140 * d).toInt())
    }

    override fun onDraw(c: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        if (ele.size < 2) {
            label.textAlign = Paint.Align.CENTER
            c.drawText("No elevation data in this GPX", w / 2, h / 2, label)
            label.textAlign = Paint.Align.LEFT
            return
        }
        val left = 44 * d
        val bottom = h - 18 * d
        val top = 8 * d
        val right = w - 8 * d
        var lo = ele.min()
        var hi = ele.max()
        if (hi - lo < 50) { val mid = (hi + lo) / 2; lo = mid - 25; hi = mid + 25 }
        val total = dist.last().coerceAtLeast(1.0)
        fun x(m: Double) = (left + (right - left) * (m / total)).toFloat()
        fun y(e: Double) = (bottom - (bottom - top) * ((e - lo) / (hi - lo))).toFloat()

        for (i in 0..2) {
            val e = lo + (hi - lo) * i / 2
            val yy = y(e)
            c.drawLine(left, yy, right, yy, grid)
            c.drawText(Units.elevation(e, imperial), 2 * d, yy + 4 * d, label)
        }
        path.reset()
        path.moveTo(x(dist[0]), y(ele[0]))
        for (i in 1 until ele.size) path.lineTo(x(dist[i]), y(ele[i]))
        fillPath.set(path)
        fillPath.lineTo(x(dist.last()), bottom); fillPath.lineTo(x(dist[0]), bottom); fillPath.close()
        if (shaderSpan != bottom - top) {
            shaderSpan = bottom - top
            fill.shader = LinearGradient(0f, top, 0f, bottom, (p.primary and 0x00FFFFFF) or 0x66000000, (p.primary and 0x00FFFFFF) or 0x08000000, Shader.TileMode.CLAMP)
        }
        c.drawPath(fillPath, fill)
        c.drawPath(path, line)
        label.textAlign = Paint.Align.RIGHT
        c.drawText(Units.distance(total, imperial), right, h - 3 * d, label)
        label.textAlign = Paint.Align.LEFT
        c.drawText("0", left, h - 3 * d, label)
        cursorM?.let { m ->
            val cx = x(m.coerceIn(0.0, total))
            c.drawLine(cx, top, cx, bottom, cursor)
            var i = dist.indexOfFirst { it >= m }
            if (i < 0) i = ele.lastIndex
            c.drawCircle(cx, y(ele[i]), 5 * d, cursor)
        }
    }
}

/** Compass rose that rotates so north points north; optional bearing marker to a target. */
class CompassView(context: Context) : View(context) {
    private val p = Palette.of(context)
    private val d = resources.displayMetrics.density
    var headingDeg: Double? = null
        set(v) { if (field != v) { field = v; invalidate() } }
    var targetBearingDeg: Double? = null
        set(v) { if (field != v) { field = v; invalidate() } }
    var unreliable = false
        set(v) { if (field != v) { field = v; invalidate() } }

    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = p.outline; strokeWidth = 2 * d }
    private val face = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.surface }
    private val tick = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.muted; strokeWidth = 1.5f * d; strokeCap = Paint.Cap.ROUND }
    private val tickMajor = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.onSurface; strokeWidth = 3 * d; strokeCap = Paint.Cap.ROUND }
    private val letters = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = p.onSurface; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD
    }
    private val north = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.danger }
    private val lubber = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.primary }
    private val targetPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.accent }
    private val centre = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = p.onSurface; textAlign = Paint.Align.CENTER; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
    private val sub = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.muted; textAlign = Paint.Align.CENTER }
    private val tri = Path()

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val hMode = MeasureSpec.getMode(heightMeasureSpec)
        val hSize = MeasureSpec.getSize(heightMeasureSpec)
        var s = min(w, (360 * d).toInt())
        if (hMode != MeasureSpec.UNSPECIFIED) s = min(s, hSize)
        setMeasuredDimension(w, s)
    }

    override fun onDraw(c: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = min(width, height) / 2f - 16 * d
        c.drawCircle(cx, cy, r, face)
        c.drawCircle(cx, cy, r, ring)
        // Lubber line (direction the phone points).
        tri.reset(); tri.moveTo(cx, cy - r - 12 * d); tri.lineTo(cx - 9 * d, cy - r + 4 * d); tri.lineTo(cx + 9 * d, cy - r + 4 * d); tri.close()
        c.drawPath(tri, lubber)

        val heading = headingDeg ?: 0.0
        c.save()
        c.rotate(-heading.toFloat(), cx, cy)
        for (deg in 0 until 360 step 5) {
            val major = deg % 30 == 0
            val len = if (major) 14 * d else 7 * d
            val a = Math.toRadians(deg.toDouble())
            val sx = cx + (r - 4 * d) * sin(a).toFloat()
            val sy = cy - (r - 4 * d) * cos(a).toFloat()
            val ex = cx + (r - 4 * d - len) * sin(a).toFloat()
            val ey = cy - (r - 4 * d - len) * cos(a).toFloat()
            c.drawLine(sx, sy, ex, ey, if (major) tickMajor else tick)
        }
        letters.textSize = r * 0.16f
        for ((i, l) in listOf("N", "E", "S", "W").withIndex()) {
            c.save()
            c.rotate(i * 90f, cx, cy)
            letters.color = if (i == 0) p.danger else p.onSurface
            c.drawText(l, cx, cy - r + 30 * d + letters.textSize * 0.5f, letters)
            c.restore()
        }
        letters.textSize = r * 0.08f
        letters.color = p.muted
        for (deg in listOf(30, 60, 120, 150, 210, 240, 300, 330)) {
            c.save(); c.rotate(deg.toFloat(), cx, cy)
            c.drawText(deg.toString(), cx, cy - r + 30 * d + letters.textSize * 0.4f, letters)
            c.restore()
        }
        // North needle.
        tri.reset(); tri.moveTo(cx, cy - r * 0.55f); tri.lineTo(cx - 10 * d, cy); tri.lineTo(cx + 10 * d, cy); tri.close()
        c.drawPath(tri, north)
        targetBearingDeg?.let { b ->
            c.save(); c.rotate(b.toFloat(), cx, cy)
            tri.reset(); tri.moveTo(cx, cy - r + 2 * d); tri.lineTo(cx - 11 * d, cy - r + 22 * d); tri.lineTo(cx + 11 * d, cy - r + 22 * d); tri.close()
            c.drawPath(tri, targetPaint)
            c.restore()
        }
        c.restore()

        c.drawCircle(cx, cy, r * 0.30f, face)
        centre.textSize = r * 0.2f
        c.drawText(headingDeg?.let { Units.bearing(it) } ?: "—", cx, cy + centre.textSize * 0.2f, centre)
        sub.textSize = r * 0.09f
        c.drawText(headingDeg?.let { Geo.cardinal(it) + if (unreliable) " · calibrate" else "" } ?: "No compass", cx, cy + r * 0.17f, sub)
    }
}
