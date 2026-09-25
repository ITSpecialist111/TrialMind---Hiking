package com.trailmind.wear

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.view.ViewGroup
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Full-screen pages stacked vertically; swipe up/down (or turn the bezel) to move between them.
 * Horizontal swipes are left alone so Wear OS swipe-to-dismiss keeps working.
 */
class VerticalPager(ctx: Context) : ViewGroup(ctx) {
    var page = 0; private set
    var onPageChanged: (() -> Unit)? = null
    private val slop = ViewConfiguration.get(ctx).scaledTouchSlop
    private val minFling = ViewConfiguration.get(ctx).scaledMinimumFlingVelocity
    private var downX = 0f
    private var downY = 0f
    private var lastY = 0f
    private var dragging = false
    private var tracker: VelocityTracker? = null
    private var anim: ValueAnimator? = null

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        val cw = MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY)
        val ch = MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY)
        for (i in 0 until childCount) getChildAt(i).measure(cw, ch)
        setMeasuredDimension(w, h)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val h = b - t
        for (i in 0 until childCount) getChildAt(i).layout(0, i * h, r - l, (i + 1) * h)
        if (anim?.isRunning != true) scrollTo(0, page * h)
    }

    override fun onInterceptTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.x; downY = e.y; lastY = e.y; dragging = false
                anim?.cancel()
                tracker?.recycle()
                tracker = VelocityTracker.obtain().apply { addMovement(e) }
            }
            MotionEvent.ACTION_MOVE -> {
                tracker?.addMovement(e)
                val dy = abs(e.y - downY)
                if (!dragging && dy > slop && dy > abs(e.x - downX)) {
                    dragging = true
                    lastY = e.y
                    parent?.requestDisallowInterceptTouchEvent(true)
                }
            }
        }
        return dragging
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        val vt = tracker ?: VelocityTracker.obtain().also { tracker = it }
        vt.addMovement(e)
        when (e.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                if (!dragging && abs(e.y - downY) > slop) dragging = true
                if (dragging) {
                    val maxY = (childCount - 1) * height
                    scrollTo(0, (scrollY + (lastY - e.y).roundToInt()).coerceIn(0, maxY))
                }
                lastY = e.y
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                vt.computeCurrentVelocity(1000)
                val vy = vt.yVelocity
                val dragged = scrollY - page * height
                val target = when {
                    vy < -minFling || dragged > height / 4 -> page + 1
                    vy > minFling || dragged < -height / 4 -> page - 1
                    else -> page
                }
                show(target)
                vt.recycle()
                tracker = null
                dragging = false
            }
        }
        return true
    }

    fun show(target: Int) {
        val p = target.coerceIn(0, childCount - 1)
        anim?.cancel()
        anim = ValueAnimator.ofInt(scrollY, p * height).apply {
            duration = 220
            addUpdateListener { scrollTo(0, it.animatedValue as Int) }
            start()
        }
        if (p != page) {
            page = p
            onPageChanged?.invoke()
        }
    }
}
