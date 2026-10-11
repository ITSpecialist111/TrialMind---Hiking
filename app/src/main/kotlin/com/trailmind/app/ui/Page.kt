package com.trailmind.app.ui

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import com.trailmind.app.TrailMindApp

/** A screen shown in the content area (full-screen on the cover display, side pane when unfolded). */
abstract class Page(val host: MainActivity) {
    val ui: Ui get() = host.ui
    val p: Palette get() = host.ui.p
    val app: TrailMindApp get() = host.app
    val root = FrameLayout(host)
    private var rendered = false
    private var pendingScroll: Pair<ScrollView, Int>? = null

    protected abstract fun render(): View

    fun ensureRendered() { if (!rendered) refresh() }

    open fun refresh() {
        rendered = true
        // A refresh before the previous one's scroll was applied must keep that target, not the new view's 0.
        val scrollY = pendingScroll?.second ?: firstScroll(root)?.scrollY ?: 0
        root.removeAllViews()
        root.addView(render(), FrameLayout.LayoutParams(-1, -1))
        applyBottomInset()
        pendingScroll = null
        if (scrollY > 0) firstScroll(root)?.let { s ->
            pendingScroll = s to scrollY
            s.post { if (pendingScroll?.first === s) { s.scrollTo(0, scrollY); pendingScroll = null } }
        }
    }

    private fun firstScroll(v: View): ScrollView? = when (v) {
        is ScrollView -> v
        is ViewGroup -> (0 until v.childCount).firstNotNullOfOrNull { firstScroll(v.getChildAt(it)) }
        else -> null
    }

    private var bottomInset = 0

    /**
     * Keeps the page's last content clear of the floating navigation. The padding goes on the scrolling list, not the
     * page, so content scrolls under the capsule instead of stopping short of it.
     */
    fun setBottomInset(px: Int) {
        bottomInset = px
        applyBottomInset()
    }

    private fun applyBottomInset() {
        val scroll = firstScroll(root)
        if (scroll != null) {
            root.setPadding(0, 0, 0, 0)
            scroll.clipToPadding = false
            scroll.setPadding(scroll.paddingLeft, scroll.paddingTop, scroll.paddingRight, bottomInset)
        } else root.setPadding(0, 0, 0, bottomInset)
    }

    open fun onShow() {}
    open fun onHide() {}
    open fun dispose() {}

    /** Standard page: header + scrolling column body. */
    protected fun scaffold(title: String, back: Boolean = host.canGoBackWithin(this), actions: List<View> = emptyList(), body: LinearLayout.() -> Unit): View =
        ui.column {
            addView(ui.header(title, if (back) ({ host.goBack() }) else null, *actions.toTypedArray()))
            addView(ui.scroll(ui.column(padding = 16, spacing = 12) {
                body()
                addView(ui.spacer(24))
            }), ui.lp(h = 0, weight = 1f))
        }
}
