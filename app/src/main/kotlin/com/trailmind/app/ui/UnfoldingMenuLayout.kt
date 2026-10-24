package com.trailmind.app.ui

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Rect
import android.os.Build
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.animation.DecelerateInterpolator
import android.widget.AbsSeekBar
import android.widget.EditText
import android.widget.FrameLayout
import com.trailmind.app.R
import com.trailmind.core.geo.MenuMotion
import kotlin.math.abs
import kotlin.math.roundToInt

/** A non-modal wide-screen drawer; gestures outside its edge leave the map alone. */
@SuppressLint("ViewConstructor")
class UnfoldingMenuLayout(
    context: Context,
    map: View,
    private val onPosition: (Float) -> Unit,
    private val onOpenRequested: (Boolean) -> Unit,
) : FrameLayout(context) {
    val drawer = FrameLayout(context).apply {
        isClickable = true
        pivotX = 0f
        cameraDistance = dp(1600).toFloat()
    }
    private val handle = FrameLayout(context).apply {
        contentDescription = "Show menu. Swipe right to unfold."
        isClickable = true
        isFocusable = true
        addView(Ui(context).fab(R.drawable.ic_menu, "", bg = Palette.of(context).glass) {}.apply {
            scaleX = 0.55f
            scaleY = 0.55f
            isClickable = false
            isFocusable = false
            isDuplicateParentStateEnabled = true
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LayoutParams(dp(48), dp(64), Gravity.CENTER))
        setOnClickListener { requestOpen(true) }
    }
    var gesturesEnabled = true
    var drawerWidthPx: Int = 1
        set(value) {
            require(value > 0)
            if (field == value) return
            field = value
            drawer.layoutParams = (drawer.layoutParams as LayoutParams).apply { width = value }
            applyPosition()
        }
    var openFraction = 1f
        private set
    var isOpen = true
        private set
    private var motion: ValueAnimator? = null
    private var tracker: VelocityTracker? = null
    private val config = ViewConfiguration.get(context)
    private val slop = config.scaledTouchSlop.toFloat()
    private val fling = maxOf(config.scaledMinimumFlingVelocity * 8f, dp(400).toFloat())
    private var edgeLeft = 0
    private var downX = 0f
    private var downY = 0f
    private var downFraction = 1f
    private var downOpen = true
    private var candidate = false
    private var dragging = false
    private var aborted = false

    init {
        addView(map, LayoutParams(-1, -1))
        addView(drawer, LayoutParams(1, -1))
        addView(handle, LayoutParams(dp(48), dp(64), Gravity.LEFT or Gravity.CENTER_VERTICAL))
        applyPosition()
    }

    fun setHandleInsets(left: Int, top: Int, bottom: Int) {
        edgeLeft = left
        val lp = handle.layoutParams as LayoutParams
        if (lp.leftMargin != left || lp.topMargin != top || lp.bottomMargin != bottom) {
            lp.leftMargin = left; lp.topMargin = top; lp.bottomMargin = bottom
            handle.layoutParams = lp
        }
    }

    fun setOpen(open: Boolean, animate: Boolean = true) {
        if (animate && isOpen == open && motion?.isRunning == true) return
        isOpen = open
        motion?.cancel()
        motion = null
        val target = if (open) 1f else 0f
        if (!animate || !isLaidOut || !ValueAnimator.areAnimatorsEnabled() || openFraction == target) {
            openFraction = target
            applyPosition()
            return
        }
        motion = ValueAnimator.ofFloat(openFraction, target).apply {
            duration = (260 * abs(target - openFraction)).roundToInt().coerceAtLeast(100).toLong()
            interpolator = DecelerateInterpolator(1.5f)
            addUpdateListener {
                openFraction = it.animatedValue as Float
                applyPosition()
            }
            start()
        }
    }

    fun finishMotion() {
        dragging = false
        candidate = false
        tracker?.recycle()
        tracker = null
        setOpen(isOpen, animate = false)
    }

    private fun requestOpen(open: Boolean) {
        setOpen(open)
        onOpenRequested(open)
    }

    private fun applyPosition() {
        drawer.translationX = -drawerWidthPx * (1f - openFraction)
        drawer.rotationY = -10f * (1f - openFraction)
        drawer.visibility = if (openFraction == 0f) INVISIBLE else VISIBLE
        drawer.importantForAccessibility = if (openFraction == 1f) IMPORTANT_FOR_ACCESSIBILITY_AUTO else IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        handle.visibility = if (openFraction == 0f && gesturesEnabled) VISIBLE else INVISIBLE
        updateGestureExclusion()
        onPosition(openFraction)
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        drawer.pivotY = height / 2f
        updateGestureExclusion()
    }

    private fun updateGestureExclusion() {
        if (Build.VERSION.SDK_INT >= 29) {
            // Reserve only the handle, not the whole edge: Android's Back gesture remains available elsewhere.
            systemGestureExclusionRects = if (handle.visibility == VISIBLE) listOf(
                Rect(0, (handle.top - dp(16)).coerceAtLeast(0), handle.right, (handle.bottom + dp(16)).coerceAtMost(height)),
            ) else emptyList()
        }
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                tracker?.recycle()
                tracker = null
                dragging = false
                aborted = false
                downX = event.x; downY = event.y
                downFraction = openFraction
                downOpen = isOpen
                candidate = gesturesEnabled && (
                    if (openFraction == 0f) event.x <= edgeLeft + dp(48)
                    else event.x <= drawerWidthPx * openFraction && !horizontalControlAt(drawer, event.rawX, event.rawY)
                )
                if (candidate) tracker = VelocityTracker.obtain().also { it.addMovement(event) }
            }
            MotionEvent.ACTION_POINTER_DOWN -> candidate = false
            MotionEvent.ACTION_MOVE -> {
                if (!candidate || event.pointerCount != 1) return false
                tracker?.addMovement(event)
                val dx = event.x - downX
                val dy = event.y - downY
                if (abs(dy) > slop && abs(dy) >= abs(dx)) candidate = false
                else if (MenuMotion.shouldDrag(dx, dy, slop, downFraction)) {
                    motion?.cancel()
                    motion = null
                    downFraction = openFraction
                    dragging = true
                    parent?.requestDisallowInterceptTouchEvent(true)
                    return true
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                tracker?.recycle()
                tracker = null
                candidate = false
            }
        }
        return false
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!dragging) return super.onTouchEvent(event)
        tracker?.addMovement(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN -> {
                aborted = true
                setOpen(downOpen)
            }
            MotionEvent.ACTION_MOVE -> if (!aborted && event.pointerCount == 1) {
                openFraction = MenuMotion.fraction(downFraction, event.x - downX, drawerWidthPx.toFloat())
                applyPosition()
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                tracker?.computeCurrentVelocity(1000, config.scaledMaximumFlingVelocity.toFloat())
                val open = if (aborted || event.actionMasked == MotionEvent.ACTION_CANCEL) downOpen
                    else MenuMotion.settleOpen(openFraction, tracker?.xVelocity ?: 0f, fling)
                dragging = false
                candidate = false
                tracker?.recycle()
                tracker = null
                requestOpen(open)
            }
        }
        return true
    }

    private fun horizontalControlAt(view: View, x: Float, y: Float): Boolean {
        val bounds = Rect()
        if (view.visibility != VISIBLE || !view.getGlobalVisibleRect(bounds) || !bounds.contains(x.toInt(), y.toInt())) return false
        if (view is AbsSeekBar || view is EditText || view.canScrollHorizontally(-1) || view.canScrollHorizontally(1)) return true
        return view is ViewGroup && (0 until view.childCount).any { horizontalControlAt(view.getChildAt(it), x, y) }
    }

    override fun onDetachedFromWindow() {
        finishMotion()
        super.onDetachedFromWindow()
    }
}
