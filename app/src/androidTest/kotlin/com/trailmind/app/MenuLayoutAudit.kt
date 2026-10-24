package com.trailmind.app

import android.app.Instrumentation
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.TextView
import com.trailmind.app.ui.*

/** Measures complete scrolling pages without invoking their actions or network-loading onShow callbacks. */
internal object MenuLayoutAudit {
    fun run(runner: Instrumentation): String {
        val host = runner.startActivitySync(Intent(runner.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        val routes = host.app.db.routes()
        val route = routes.firstOrNull()?.let { host.app.db.routeData(it.id) }
        val hikes = host.app.db.hikes()
        val hike = hikes.firstOrNull()
        val segments = hike?.let { host.app.db.hikeSegments(it.id) }
        val packs = host.app.db.packs()
        val report = StringBuilder()
        var failure: Throwable? = null
        runner.runOnMainSync {
            try {
                fun <T : Page> T.seed(name: String, value: Any?): T = apply {
                    javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
                }
                val pages = listOf(
                    DashboardPage(host),
                    RoutesPage(host).seed("routes", routes),
                    HikesPage(host).seed("hikes", hikes),
                    CompassPage(host),
                    OfflinePage(host).seed("packs", packs).seed("routes", routes),
                    AssistantPage(host, route?.meta?.id).seed("routes", routes).seed("data", route),
                    SafetyPage(host),
                    SettingsPage(host),
                    MorePage(host),
                    SearchPage(host),
                    RouteFinderPage(host),
                    StravaPage(host),
                    GroupPage(host),
                    GroupDiagnosticsPage(host),
                    GroupFindPage(host, -1),
                    SatellitePage(host),
                    OnboardingPage(host),
                ) + listOfNotNull(
                    route?.let { RouteDetailPage(host, it.meta.id).seed("data", it) },
                    hike?.let { HikeDetailPage(host, it.id).seed("meta", it).seed("segments", segments) },
                )
                for (page in pages) {
                    page.ensureRendered()
                    for (width in listOf(260, 340, 360)) {
                        measure(page.root, host.dp(width), host.dp(800))
                        inspect(page.root, page.javaClass.simpleName, width, report)
                    }
                    page.dispose()
                    report.append("AUDITED ").append(page.javaClass.simpleName).append('\n')
                }
            } catch (error: Throwable) { failure = error }
        }
        failure?.let { throw it }
        return report.toString()
    }

    private fun measure(view: View, width: Int, height: Int) {
        view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, width, height)
    }

    private fun inspect(view: View, page: String, width: Int, report: StringBuilder) {
        if (view.visibility == View.GONE) return
        if (view is TextView && view !is EditText && view.text.isNotBlank()) {
            val layout = view.layout
            if (layout != null) {
                val text = view.text.toString()
                val split = (0 until layout.lineCount - 1).any { line ->
                    val end = layout.getLineEnd(line)
                    end in 1 until text.length && text[end - 1].isLetterOrDigit() && text[end].isLetterOrDigit()
                }
                val clipped = (0 until layout.lineCount).any { layout.getEllipsisCount(it) > 0 }
                val button = view.isClickable && !view.isTextSelectable && view.gravity == android.view.Gravity.CENTER
                if (split || clipped && view.isClickable && !view.isTextSelectable || button && layout.lineCount > 2) {
                    val kind = if (view is android.widget.Switch) "switch" else if (view.isClickable) "action" else "text"
                    report.append("$page ${width}dp $kind lines=${layout.lineCount} split=$split clipped=$clipped: ")
                        .append(text.replace('\n', ' ').take(150)).append('\n')
                }
            }
        }
        if (view is ViewGroup) for (i in 0 until view.childCount) inspect(view.getChildAt(i), page, width, report)
    }
}
