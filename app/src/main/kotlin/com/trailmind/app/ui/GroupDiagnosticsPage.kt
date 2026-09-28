package com.trailmind.app.ui

import android.content.ClipData
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.view.View
import com.trailmind.app.Async
import com.trailmind.app.frontier.group.GroupRadio
import com.trailmind.app.frontier.group.UwbRadio
import com.trailmind.app.share.ExportProvider
import com.trailmind.core.frontier.group.GroupFrames
import com.trailmind.core.frontier.group.GroupKeys
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** What the trip-group radio is doing, plus the reception log used for range tests in the field. */
class GroupDiagnosticsPage(host: MainActivity) : Page(host) {
    private val tick = object : Runnable {
        override fun run() {
            refresh()
            Async.main.postDelayed(this, 2_000)
        }
    }

    override fun onShow() {
        Async.main.post(tick)
    }

    override fun onHide() {
        Async.main.removeCallbacks(tick)
    }

    override fun render(): View = scaffold("Bluetooth diagnostics") {
        val sharing = app.group
        val radio = sharing.radio
        val caps = radio.capabilities()
        fun yes(b: Boolean) = if (b) "yes" else "no"
        fun block(title: String, lines: List<String>) = addView(ui.card(spacing = 6) {
            addView(ui.text(title, Ui.T.TITLE))
            addView(ui.text(lines.joinToString("\n"), Ui.T.MONO).apply { textSize = 12f; setTextIsSelectable(true) })
        })

        block("This phone", listOf(
            "${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "Bluetooth: ${if (caps.enabled) "on" else if (caps.bluetooth) "off" else "none"}",
            "Extended advertising: ${yes(caps.extended)}",
            "LE Coded (long range): ${yes(caps.coded)}",
            "Several advertising sets: ${yes(caps.multipleAdvertisers)}",
            "Advertising data: ${caps.maxAdvertisingData} bytes, ${caps.maxFrames} frames",
            "Permissions: ${if (GroupRadio.hasPermissions(host)) "granted" else "missing"}",
        ))

        val plan = sharing.plan
        val now = SystemClock.elapsedRealtime()
        block("Radio", buildList {
            add("Profile: ${plan?.mode?.name?.lowercase() ?: "off"}" + (plan?.let { " · every ${it.advertiseInterval * 0.625} ms · scan ${it.scan.name.lowercase()}" } ?: ""))
            if (radio.adverts.isEmpty()) add("Advertising: none")
            radio.adverts.forEach { a ->
                add("Advertising ${if (a.coded) "LE Coded" else "LE 1M"}: " + when {
                    a.running -> "on, ${a.txPower ?: "?"} dBm"
                    a.error != null -> "failed (${a.error})"
                    else -> "starting"
                })
            }
            add("Scan: " + (if (radio.scanning) "on for ${groupAge((now - radio.scanStartedAt) / 1_000)}" else "off") +
                (radio.scanError?.let { " · $it" } ?: ""))
            add("Heard ${radio.received} adverts, ${radio.receivedCoded} on LE Coded")
            add("Opened ${sharing.opened} · not ours or unreadable ${sharing.unreadable}")
            add("Clock offset from GPS: ${sharing.clockSkewMs / 1_000} s · tag epoch ${GroupKeys.epoch(sharing.nowS())}")
        })

        val members = sharing.members
        if (members.isNotEmpty()) block("Members heard", members.map { peer ->
            val direct = if (peer.lastDirectMs > 0) groupAge((System.currentTimeMillis() - peer.lastDirectMs) / 1_000) + " ago" else "never"
            "${sharing.nameOf(peer).take(14).padEnd(14)} ${peer.rssi ?: "?"} dBm ${if (peer.coded) "coded" else "1M   "} direct $direct" +
                (peer.position?.let { " · hops ${it.hops}" } ?: "") +
                (peer.position?.capabilities?.let { if (it and (GroupFrames.CAP_UWB or GroupFrames.CAP_UWB_STATIC) != 0) " · UWB" else "" } ?: "")
        })

        val finder = sharing.finder
        val uwb = finder.uwb.capabilities
        block("UWB", buildList {
            add("State: ${uwb.state.name.lowercase()}" + if (UwbRadio.supported(host)) "" else " (needs Android 16 and UWB)")
            if (uwb.configIds.isNotEmpty()) {
                add("Configs ${uwb.configIds.joinToString()} · channels ${uwb.channels.joinToString()}")
                add("Preambles ${uwb.preambles.joinToString()} · update rates ${uwb.updateRates.joinToString()}")
                add("Distance ${yes(uwb.distance)} · azimuth ${yes(uwb.azimuth)} · elevation ${yes(uwb.elevation)}")
                add("Background ranging ${yes(uwb.background)}" + (uwb.minIntervalMs?.let { " · fastest every $it ms" } ?: ""))
            }
            finder.state?.let { s ->
                val who = members.firstOrNull { it.memberId == s.memberId }?.let(sharing::nameOf) ?: "%08x".format(s.memberId)
                add("Session: ${s.role.name.lowercase()} $who · ${s.phase.name.lowercase()}" + (s.note?.let { " · $it" } ?: ""))
                s.measurement?.let { m ->
                    add("Last: ${m.distanceM?.let { "%.2f m".format(it) } ?: "?"} (confidence ${m.distanceConfidence})" +
                        (m.azimuthDeg?.let { " · azimuth %.0f°".format(it) } ?: "") + (m.elevationDeg?.let { " · elevation %.0f°".format(it) } ?: ""))
                }
            }
            finder.selfTest?.let { add("Test: $it") }
        })
        if (UwbRadio.supported(host)) addView(ui.button("Test UWB on this phone", null, Ui.B.TONAL) {
            host.withRangingPermission { finder.selfTest() }
        })

        addView(ui.row {
            addView(ui.button("Share log (CSV)", null, Ui.B.TONAL) { shareLog() }, ui.lp(0, weight = 1f))
            addView(ui.button("Clear log", null, Ui.B.TEXT) { sharing.clearLog(); host.toast("Log cleared") }, ui.lp(0, weight = 1f))
        })
        addView(ui.text("The log keeps the last 5,000 frames heard, with signal strength, radio and distance from you. It stays on " +
            "this phone unless you share it.", Ui.T.CAPTION))
    }

    private fun shareLog() {
        val name = "trailmind-group-" + SimpleDateFormat("yyyyMMdd-HHmm", Locale.ROOT).format(Date()) + ".csv"
        val uri = ExportProvider.write(host, name, app.group.logCsv())
        val send = Intent(Intent.ACTION_SEND).apply {
            type = ExportProvider.CSV_MIME
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, name)
            clipData = ClipData.newRawUri(name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        host.startActivity(Intent.createChooser(send, "Share reception log"))
    }
}
