package com.trailmind.app.ui

import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import com.trailmind.app.TrailMindApp

/** A screen shown in the content area (full-screen on the cover display, side pane when unfolded). */
abstract class Page(val host: MainActivity) {
    val ui: Ui get() = host.ui
    val p: Palette get() = host.ui.p
    val app: TrailMindApp get() = host.app
    val root = FrameLayout(host)
    private var rendered = false

    protected abstract fun render(): View

    fun ensureRendered() { if (!rendered) refresh() }

    open fun refresh() {
        rendered = true
        root.removeAllViews()
        root.addView(render(), FrameLayout.LayoutParams(-1, -1))
    }

    fun setBottomInset(px: Int) = root.setPadding(0, 0, 0, px)

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
