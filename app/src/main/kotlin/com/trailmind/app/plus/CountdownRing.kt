package com.trailmind.app.plus

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.view.View
import com.trailmind.app.ui.Palette
import kotlin.math.min

/** The fall alarm's countdown as a ring that empties, with the time left inside it. */
class CountdownRing(context: Context, private val totalMs: Long) : View(context) {
    private val p = Palette.of(context)
    private val d = resources.displayMetrics.density
    private var leftMs = totalMs
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 8 * d; color = p.outline }
    private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 8 * d; strokeCap = Paint.Cap.ROUND; color = p.danger }
    private val big = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.onSurface; textAlign = Paint.Align.CENTER; textSize = 64 * d; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL) }
    private val small = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.muted; textAlign = Paint.Align.CENTER; textSize = 12 * d; letterSpacing = 0.1f }
    private val rect = RectF()

    fun update(left: Long) { leftMs = left.coerceIn(0, totalMs); invalidate() }

    override fun onDraw(c: Canvas) {
        val cx = width / 2f; val cy = height / 2f; val r = min(width, height) / 2f - 10 * d
        rect.set(cx - r, cy - r, cx + r, cy + r)
        c.drawCircle(cx, cy, r, track)
        c.drawArc(rect, -90f, 360f * leftMs / totalMs, false, arc)
        val s = leftMs / 1000
        c.drawText("%d:%02d".format(s / 60, s % 60), cx, cy + 20 * d, big)
        c.drawText("TO ANSWER", cx, cy + 46 * d, small)
    }
}
