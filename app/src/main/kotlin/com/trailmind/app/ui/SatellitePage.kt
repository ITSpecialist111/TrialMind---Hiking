package com.trailmind.app.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.location.GnssStatus
import android.location.LocationManager
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.widget.TextView
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.core.format.Units
import com.trailmind.core.geo.SatelliteSky
import java.util.Locale

private data class Satellite(val constellation: Int, val id: Int, val azimuth: Float, val elevation: Float, val cn0: Float, val used: Boolean) {
    val label: String get() = "${when (constellation) {
        GnssStatus.CONSTELLATION_GPS -> "G"
        GnssStatus.CONSTELLATION_GLONASS -> "R"
        GnssStatus.CONSTELLATION_GALILEO -> "E"
        GnssStatus.CONSTELLATION_BEIDOU -> "C"
        GnssStatus.CONSTELLATION_QZSS -> "J"
        GnssStatus.CONSTELLATION_SBAS -> "S"
        GnssStatus.CONSTELLATION_IRNSS -> "I"
        else -> "?"
    }}$id"
}

class SatellitePage(host: MainActivity) : Page(host) {
    private val manager = host.getSystemService(LocationManager::class.java)
    private var registered = false
    private var shown = false
    private var satellites: List<Satellite> = emptyList()
    private var receivedAt: Long? = null
    private var status = "Waiting for satellite reports. Move outdoors with a clear view of the sky."
    private var firstFixMs: Int? = null
    private var summary: TextView? = null
    private var telemetry: TextView? = null
    private var signals: TextView? = null
    private var sky: SkyView? = null
    private val ticker = object : Runnable {
        override fun run() { update(); if (shown) Async.main.postDelayed(this, 1000) }
    }
    private val callback = object : GnssStatus.Callback() {
        override fun onStarted() { status = "GNSS receiver started; waiting for satellite reports."; update() }
        override fun onStopped() {
            satellites = emptyList(); receivedAt = null
            status = "GNSS receiver stopped. Check Location is enabled."; update()
        }
        override fun onFirstFix(ttffMillis: Int) { firstFixMs = ttffMillis; update() }
        override fun onSatelliteStatusChanged(value: GnssStatus) {
            if (!shown) return
            // A multi-frequency receiver can report more than one signal for the same satellite.
            satellites = (0 until value.satelliteCount).map { index ->
                Satellite(value.getConstellationType(index), value.getSvid(index), value.getAzimuthDegrees(index),
                    value.getElevationDegrees(index), value.getCn0DbHz(index), value.usedInFix(index))
            }.groupBy { it.constellation to it.id }.values.map { reports ->
                reports.maxBy { it.cn0 }.copy(used = reports.any { it.used })
            }.sortedWith(compareBy<Satellite> { it.constellation }.thenBy { it.id })
            receivedAt = SystemClock.elapsedRealtime()
            status = if (satellites.isEmpty()) "No satellites reported yet." else "Live GNSS reports"
            update()
        }
    }

    override fun onShow() {
        shown = true
        start()
        Async.main.removeCallbacks(ticker)
        Async.main.post(ticker)
    }

    @SuppressLint("MissingPermission")
    private fun start() {
        if (registered || !host.hasFineLocation()) return
        try {
            registered = manager.registerGnssStatusCallback(callback, Async.main)
            if (!registered) {
                status = "Satellite telemetry is unavailable on this device."
                Log.w("SatellitePage", status)
            }
        } catch (error: SecurityException) {
            status = "Precise location permission is required."
            Log.w("SatellitePage", status, error)
        }
    }

    override fun onHide() {
        shown = false
        Async.main.removeCallbacks(ticker)
        if (registered) manager.unregisterGnssStatusCallback(callback)
        registered = false
        satellites = emptyList()
        receivedAt = null
    }

    override fun render(): View = scaffold("Satellites & telemetry") {
        addView(ui.help("Your live view of the sky.", "North stays at the top; the centre is directly overhead (zenith), the rim is the horizon. Green dots are used in your fix; outlined dots are reported but not used. Counts come from the receiver, not predicted satellite positions. Indoors, on emulators, or on some devices, reports may be unavailable. GNSS reception is not satellite messaging coverage."))
        if (!host.hasFineLocation()) {
            addView(ui.banner("Allow precise location to see satellite telemetry."))
            addView(ui.button("Allow precise location", R.drawable.ic_my_location) {
                host.withLocationPermission { if (shown) { start(); refresh() } }
            })
        }
        addView(ui.button("Check GPS is enabled", R.drawable.ic_my_location, Ui.B.TEXT) { host.ensureGpsEnabled {} })
        addView(ui.card(spacing = 8) {
            summary = ui.text(status, Ui.T.BODY).also { addView(it) }
            sky = SkyView(host).also { addView(it, ui.lp(h = host.dp(260))) }
            addView(ui.text("Centre: you / zenith · edge: horizon\nFilled: used in fix · outline: not used", Ui.T.CAPTION))
        })
        telemetry = ui.text("", Ui.T.BODY).also { addView(it) }
        addView(ui.help("Satellite signal strength (C/N0).", "C/N0 is signal-to-noise density in dB-Hz, not positional accuracy. Larger values usually indicate clearer reception. G GPS, R GLONASS, E Galileo, C BeiDou, J QZSS, S SBAS, I NavIC. Each satellite is counted once across frequencies."))
        signals = ui.text("", Ui.T.MONO).also { addView(it) }
        update()
    }

    private fun update() {
        val now = SystemClock.elapsedRealtime()
        val fresh = receivedAt?.let { now - it in 0..10_000 } == true
        val current = if (fresh) satellites else emptyList()
        val message = if (fresh) "${current.size} reported · ${current.count { it.used }} used in fix"
            else if (receivedAt != null) "Satellite report expired; waiting for updates." else status
        summary?.text = message
        sky?.setSatellites(current, message)
        val fix = app.location.latest
        telemetry?.text = buildString {
            if (fix == null) append("No position fix yet.") else {
                append("Provider: ${fix.location.provider ?: "unknown"}")
                append("\nFix age: ${((now - fix.location.elapsedRealtimeNanos / 1_000_000).coerceAtLeast(0) / 1000)} s")
                append("\nHorizontal accuracy: ±${Units.distance(fix.accuracyM.toDouble(), app.prefs.imperial)}")
                if (fix.location.hasVerticalAccuracy()) append("\nVertical accuracy: ±${Units.elevation(fix.location.verticalAccuracyMeters.toDouble(), app.prefs.imperial)}")
                fix.altitudeM?.let { append("\nAltitude: ${Units.elevation(it, app.prefs.imperial)}") }
                if (fix.location.hasSpeed()) append("\nSpeed: ${Units.speedKmh(fix.location.speed.toDouble(), app.prefs.imperial)}")
                if (fix.location.hasBearing()) append("\nCourse: ${Units.bearing(fix.location.bearing.toDouble())}")
            }
            firstFixMs?.let { append("\nReceiver time to first fix: ${it / 1000.0} s") }
            app.baro.pressureHpa?.let { append(String.format(Locale.ROOT, "\nPressure: %.1f hPa", it)) }
            append("\nCompass: ${if (host.compassDisturbed) "interference" else if (host.headingAtMs < 0 || now - host.headingAtMs > 2000) "no recent reading" else if (host.compassUnreliable) "low accuracy" else "available"}")
        }
        signals?.text = current.joinToString("\n") {
            String.format(Locale.ROOT, "%s  %.0f dB-Hz  %.0f° elev  %s", it.label, it.cn0, it.elevation, if (it.used) "used" else "not used")
        }.ifEmpty { "No live signal measurements." }
    }
}

@SuppressLint("ViewConstructor")
private class SkyView(context: Context) : View(context) {
    private val palette = Palette.of(context)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var satellites: List<Satellite> = emptyList()
    fun setSatellites(value: List<Satellite>, description: String) {
        contentDescription = "North-up sky plot. $description"
        if (satellites != value) { satellites = value; invalidate() }
    }
    override fun onDraw(canvas: Canvas) {
        val x = width / 2f
        val y = height / 2f
        val radius = (minOf(width, height) / 2f - dp(25)).coerceAtLeast(1f)
        paint.color = palette.outline; paint.strokeWidth = dp(1).toFloat(); paint.style = Paint.Style.STROKE
        for (fraction in listOf(1f, 2f / 3f, 1f / 3f)) canvas.drawCircle(x, y, radius * fraction, paint)
        canvas.drawLine(x - radius, y, x + radius, y, paint)
        canvas.drawLine(x, y - radius, x, y + radius, paint)
        paint.style = Paint.Style.FILL; paint.color = palette.onSurface
        paint.textSize = dp(12).toFloat(); paint.textAlign = Paint.Align.CENTER
        canvas.drawText("N", x, y - radius - dp(19), paint)
        canvas.drawText("S", x, y + radius + dp(18), paint)
        canvas.drawText("E", x + radius + dp(14), y + dp(4), paint)
        canvas.drawText("W", x - radius - dp(14), y + dp(4), paint)
        canvas.drawCircle(x, y, dp(3).toFloat(), paint)
        val labels = ArrayList<android.graphics.RectF>()
        satellites.forEach {
            val point = SatelliteSky.project(it.azimuth.toDouble(), it.elevation.toDouble()) ?: return@forEach
            val sx = x + point.x.toFloat() * radius
            val sy = y + point.y.toFloat() * radius
            paint.color = if (it.used) palette.primary else palette.muted
            paint.style = if (it.used) Paint.Style.FILL else Paint.Style.STROKE
            paint.strokeWidth = dp(2).toFloat()
            canvas.drawCircle(sx, sy, dp(5).toFloat(), paint)
            paint.style = Paint.Style.FILL
            val labelWidth = paint.measureText(it.label)
            val bounds = android.graphics.RectF(sx - labelWidth / 2, sy - dp(20), sx + labelWidth / 2, sy - dp(6))
            if (labels.none { previous -> android.graphics.RectF.intersects(previous, bounds) }) {
                canvas.drawText(it.label, sx, sy - dp(8), paint)
                labels.add(bounds)
            }
        }
    }
}
