package com.trailmind.app.ui

import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import com.trailmind.app.R
import com.trailmind.app.location.Fix
import com.trailmind.core.format.Units
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.Sun
import java.text.DateFormat
import java.util.Date

private fun timeOf(ms: Long?): String = ms?.let { DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(it)) } ?: "—"

// ====================================================================== compass

class CompassPage(host: MainActivity) : Page(host) {
    private var dial: CompassView? = null
    private var headingText: TextView? = null
    private var targetText: TextView? = null
    private var posText: TextView? = null
    private var gridText: TextView? = null
    private var sunText: TextView? = null
    private var calibrate: View? = null

    private val onHeading: () -> Unit = { update() }
    private val onFix: (Fix) -> Unit = { update() }
    private val onNav: () -> Unit = { update() }

    override fun onShow() {
        host.addHeadingListener(onHeading)
        app.location.addListener(onFix)
        app.nav.addListener(onNav)
        update()
    }

    override fun onHide() {
        host.removeHeadingListener(onHeading)
        app.location.removeListener(onFix)
        app.nav.removeListener(onNav)
    }

    override fun render(): View = scaffold("Compass") {
        if (!host.compass.available) addView(ui.banner("This device has no magnetometer, so the compass is unavailable. Use GPS bearing while moving.", danger = true))
        calibrate = ui.banner("Compass accuracy is low. Move the phone in a figure-of-eight away from metal, magnets and the phone case clasp.").also {
            it.visibility = View.GONE; addView(it)
        }
        addView(ui.card(padding = 12) {
            gravity = Gravity.CENTER_HORIZONTAL
            addView(CompassView(host).also { dial = it })
            headingText = ui.text("", Ui.T.CAPTION).apply { gravity = Gravity.CENTER }
            addView(headingText, ui.lp())
        })
        targetText = ui.text("", Ui.T.BODY)
        addView(ui.card(spacing = 4) {
            addView(ui.text("Bearing to", Ui.T.LABEL))
            addView(targetText)
        })
        addView(ui.card(spacing = 4) {
            addView(ui.text("Your position", Ui.T.LABEL))
            gridText = ui.text("", Ui.T.HEADLINE).also { addView(it) }
            posText = ui.text("", Ui.T.CAPTION).also { addView(it) }
        })
        sunText = ui.text("", Ui.T.BODY)
        addView(ui.card(spacing = 4) {
            addView(ui.text("Daylight", Ui.T.LABEL))
            addView(sunText)
        })
        addView(ui.text("Hold the phone flat. Headings are true north (magnetic declination from your GPS position is applied). Grid references are OSGB36 (±5 m conversion) and only valid in Great Britain.", Ui.T.CAPTION))
    }

    private fun update() {
        val d = dial ?: return
        val heading = host.headingDeg
        d.headingDeg = heading
        d.unreliable = host.compassUnreliable
        calibrate?.visibility = if (host.compassUnreliable && heading != null) View.VISIBLE else View.GONE
        headingText?.text = heading?.let {
            "True ${Units.bearing(it)} · magnetic ${Units.bearing(Geo.normalizeDeg(it - host.compass.declinationDeg))} · declination ${"%.1f".format(host.compass.declinationDeg)}°"
        } ?: "Waiting for compass…"

        val f = app.location.latest
        val imperial = app.prefs.imperial
        if (f == null) {
            gridText?.text = "No GPS fix"
            posText?.text = if (host.hasLocationPermission()) "Go outside with a clear view of the sky." else "Location permission is off."
        } else {
            val here = LatLon(f.lat, f.lon)
            gridText?.text = OsGrid.fromWgs84(here)?.format(10) ?: Units.latLon(f.lat, f.lon)
            posText?.text = buildString {
                append(Units.latLon(f.lat, f.lon)).append(" · ±${f.accuracyM.toInt()} m")
                f.altitudeMslM?.let { append(" · alt ${Units.elevation(it, imperial)}") ; if (!f.altitudeIsMsl) append(" (GPS ellipsoid, ~50 m high)") }
                append(" · fix ${timeOf(f.location.time)}")
            }
            val sun = Sun.today(here)
            sunText?.text = when {
                sun.polarDay -> "Sun up all day"
                sun.polarNight -> "Sun down all day"
                else -> {
                    val left = sun.sunsetMs?.let { it - System.currentTimeMillis() }
                    "Sunrise ${timeOf(sun.sunriseMs)} · sunset ${timeOf(sun.sunsetMs)}" +
                        (left?.let { if (it > 0) " · ${Units.duration(it)} of daylight left" else " · after sunset" } ?: "")
                }
            }
        }

        val target = app.nav.target
        val next = app.nav.fix?.nextWaypoint
        val route = app.nav.active
        targetText?.text = when {
            f == null -> "Needs a GPS fix."
            target != null -> {
                val b = Geo.bearingDeg(LatLon(f.lat, f.lon), target)
                d.targetBearingDeg = b
                "Map target: ${Units.bearing(b)} ${Geo.cardinal(b)} · ${Units.distance(Geo.distanceM(LatLon(f.lat, f.lon), target), imperial)} (straight line)"
            }
            next != null -> {
                d.targetBearingDeg = next.bearingDeg
                "${next.waypoint.name}: ${Units.bearing(next.bearingDeg)} ${Geo.cardinal(next.bearingDeg)} · ${Units.distance(next.directM, imperial)} direct"
            }
            route != null && app.nav.fix != null -> {
                val fx = app.nav.fix!!
                d.targetBearingDeg = fx.routeBearingDeg
                "Route heads ${Units.bearing(fx.routeBearingDeg)} ${Geo.cardinal(fx.routeBearingDeg)} here" +
                    if (app.nav.offRoute) " · you are ${Units.distance(fx.offRouteM, imperial)} off route" else ""
            }
            else -> { d.targetBearingDeg = null; "Long-press the map to set a target, or follow a route." }
        }
        if (target == null && next == null && (route == null || app.nav.fix == null)) d.targetBearingDeg = null
    }
}

// ====================================================================== more (cover screen)

class MorePage(host: MainActivity) : Page(host) {
    override fun render(): View = scaffold("More") {
        addView(ui.listItem("Offline maps", "Download OS map areas along routes, or import MBTiles", R.drawable.ic_download) { host.push(OfflinePage(host)) })
        addView(ui.listItem("Hike assistant", "Offline briefing, and a prompt for Gemma in AI Edge Gallery", R.drawable.ic_sparkle) { host.push(AssistantPage(host)) })
        addView(ui.listItem("Safety & location", "Grid reference, share location, emergency numbers", R.drawable.ic_sos) { host.push(SafetyPage(host)) })
        addView(ui.listItem("Settings", "OS API key, units, pace, alerts, map sources", R.drawable.ic_tune) { host.push(SettingsPage(host)) })
        addView(ui.text("Unfold your phone for a side-by-side map and panel layout.", Ui.T.CAPTION))
    }
}

// ====================================================================== dashboard (wide layout, map tab)

class DashboardPage(host: MainActivity) : Page(host) {
    private val onNav: () -> Unit = { refresh() }
    override fun onShow() { app.nav.addListener(onNav) }
    override fun onHide() { app.nav.removeListener(onNav) }

    override fun render(): View = scaffold("TrailMind", back = false) {
        val imperial = app.prefs.imperial
        val route = app.nav.active
        val f = app.location.latest
        addView(ui.card(spacing = 6) {
            addView(ui.text("Now", Ui.T.LABEL))
            if (f != null) {
                val here = LatLon(f.lat, f.lon)
                addView(ui.text(OsGrid.fromWgs84(here)?.format(8) ?: Units.latLon(f.lat, f.lon), Ui.T.TITLE))
                val sun = Sun.today(here)
                addView(ui.text("±${f.accuracyM.toInt()} m" + (f.altitudeMslM?.let { " · ${Units.elevation(it, imperial)}" } ?: "") +
                    " · sunset ${timeOf(sun.sunsetMs)}", Ui.T.CAPTION))
            } else addView(ui.text("Waiting for GPS…", Ui.T.CAPTION))
        })
        if (route != null) {
            addView(ui.card(spacing = 8) {
                addView(ui.text("Following", Ui.T.LABEL))
                addView(ui.text(route.data.meta.name, Ui.T.TITLE))
                addView(ui.statGrid(listOf(
                    "Distance" to Units.distance(route.guide.totalM, imperial),
                    "Ascent" to "↑" + Units.elevation(route.estimate.ascentM, imperial),
                    "Plan" to Units.minutes(route.estimate.planningMinutes),
                )))
                addView(ElevationProfileView(host, imperial).also { it.setPoints(route.data.points); it.cursorM = app.nav.fix?.alongM })
                addView(ui.button("Route details", R.drawable.ic_route, Ui.B.TONAL) { host.push(RouteDetailPage(host, route.data.meta.id)) })
            })
        } else {
            addView(ui.card(spacing = 10) {
                addView(ui.text("No route loaded", Ui.T.TITLE))
                addView(ui.text("Import a GPX to follow it, or just start recording.", Ui.T.CAPTION))
                addView(ui.button("Import GPX", R.drawable.ic_upload) { host.pickGpx() })
            })
        }
        addView(ui.row {
            addView(ui.button("Offline maps", R.drawable.ic_download, Ui.B.OUTLINED) { host.push(OfflinePage(host)) }, ui.lp(0, weight = 1f))
            addView(ui.button("Briefing", R.drawable.ic_sparkle, Ui.B.OUTLINED) { host.push(AssistantPage(host)) }, ui.lp(0, weight = 1f))
        })
        addView(ui.text("Long-press the map to set a go-to point. Tap the GPS chip for your grid reference and safety tools.", Ui.T.CAPTION))
    }
}

// ====================================================================== onboarding

class OnboardingPage(host: MainActivity) : Page(host) {
    override fun render(): View = scaffold("Welcome to TrailMind", back = false) {
        addView(ui.text("A personal, offline-first hiking companion.", Ui.T.TITLE))
        addView(ui.card(spacing = 10) {
            listOf(
                R.drawable.ic_map to "Maps: OpenStreetMap for browsing, Ordnance Survey maps with your own free OS Data Hub key, and offline map packs.",
                R.drawable.ic_route to "Import GPX routes, see time and climb estimates, and get off-route alerts while following them.",
                R.drawable.ic_walk to "Record hikes with GPS (works with the screen off), then export GPX for Strava or anything else.",
                R.drawable.ic_compass to "Compass, OS grid references and sunset times — all on-device.",
            ).forEach { (icon, text) ->
                addView(ui.row(spacing = 12, gravity = Gravity.TOP) {
                    addView(android.widget.ImageView(host).apply { setImageDrawable(host.getDrawable(icon)?.mutate()?.apply { setTint(p.primary) }) },
                        LinearLayout.LayoutParams(host.dp(24), host.dp(24)))
                    addView(ui.text(text), ui.lp(0, weight = 1f))
                })
            }
        })
        addView(ui.banner("Safety: TrailMind is an aid, not a replacement for a paper map, compass and the skills to use them. GPS, batteries and phone signal fail. " +
            "Check the weather, tell someone your plans, and in the UK call 999 or 112 and ask for Police, then Mountain Rescue.", danger = true))
        addView(ui.text("Privacy: your location, routes and hikes stay on this phone. Nothing is uploaded unless you export or share it. Map tiles are fetched from the provider you choose.", Ui.T.CAPTION))
        addView(ui.button("I understand – continue", R.drawable.ic_play) {
            app.prefs.onboardingAccepted = true
            host.pop()
            host.handlePendingIntent()
            host.withLocationPermission { host.map.locate() }
        })
    }
}
