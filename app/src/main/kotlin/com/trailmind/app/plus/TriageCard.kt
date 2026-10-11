package com.trailmind.app.plus

import android.content.Intent
import android.net.Uri
import android.view.View
import com.trailmind.app.R
import com.trailmind.app.frontier.FallAlert
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Ui
import com.trailmind.app.ui.toast
import com.trailmind.core.frontier.Bleeding
import com.trailmind.core.frontier.InjuryType
import com.trailmind.core.frontier.Mobility
import com.trailmind.core.frontier.SosText
import com.trailmind.core.frontier.TriageCode
import com.trailmind.core.frontier.TriageText
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import java.text.DateFormat
import java.util.Date

/**
 * "Three taps" for an emergency: injury, movement, bleeding. It writes the sentence a 999 call handler wants, a one-byte
 * code your trip group's phones receive with your position, and a text for your contact. Nothing is sent by itself:
 * the text opens in your messages app, and 999 is dialled by you.
 */
fun triageCard(host: MainActivity, refresh: () -> Unit): View {
    val ui = host.ui
    val app = host.app
    val p = ui.p
    var (injury, mobility, bleeding) = TriageCode.decode(app.prefs.triageCode)
    val sharing = app.prefs.triageCode != 0

    fun situation() = TriageText.situation(injury, mobility, bleeding)
    fun code() = TriageCode.encode(injury, mobility, bleeding)
    fun fix() = app.location.latest
    fun where(): String {
        val f = fix() ?: return "location unknown"
        val grid = OsGrid.fromWgs84(LatLon(f.lat, f.lon))?.format(10)
        return (grid?.let { "grid $it, " } ?: "") + "%.5f, %.5f".format(java.util.Locale.ROOT, f.lat, f.lon)
    }

    return ui.card(spacing = 8) {
        addView(ui.text("Emergency triage", Ui.T.TITLE))
        addView(ui.text("Three taps to describe what has happened. It builds what to say to 999 and a text for your contact. " +
            "Nothing is sent until you choose.", Ui.T.CAPTION))
        val summary = ui.text("", Ui.T.BODY, p.primary)
        val codeText = ui.text("", Ui.T.CAPTION)
        fun update() {
            summary.text = situation() + if (TriageText.isUrgent(injury, mobility, bleeding)) "  ·  URGENT" else ""
            codeText.text = "Triage code ${TriageText.hex(code())}" + if (app.prefs.triageCode != 0) " · shared with your trip group while you need help" else ""
        }
        fun <T> group(title: String, items: List<Pair<String, T>>, current: T, set: (T) -> Unit) {
            addView(ui.text(title, Ui.T.LABEL))
            val flow = ui.flow()
            val chips = items.map { (label, v) -> v to ui.chip(label, v == current) }
            chips.forEach { (v, chip) ->
                chip.setOnClickListener {
                    set(v)
                    chips.forEach { (v2, c2) -> c2.setTextColor(if (v2 == v) p.onPrimaryContainer else p.onSurface); c2.background = com.trailmind.app.ui.rounded(if (v2 == v) p.primaryContainer else p.surface, ui.dp(16).toFloat(), p.outline, ui.dp(1)) }
                    update()
                }
                chip.isClickable = true
                flow.addView(chip)
            }
            addView(flow)
        }
        group("Injury", listOf("None" to InjuryType.NONE, "Leg" to InjuryType.LEG, "Arm" to InjuryType.ARM, "Head" to InjuryType.HEAD,
            "Back / chest" to InjuryType.TORSO, "Several" to InjuryType.MULTIPLE, "Ill / exhausted" to InjuryType.OTHER), injury) { injury = it }
        group("Movement", listOf("Can walk" to Mobility.MOBILE, "Limping" to Mobility.LIMITED, "Can't move" to Mobility.STATIONARY,
            "Not responding" to Mobility.UNCONSCIOUS), mobility) { mobility = it }
        group("Bleeding", listOf("None" to Bleeding.NONE, "Controlled" to Bleeding.CONTROLLED, "Not controlled" to Bleeding.UNCONTROLLED,
            "Don't know" to Bleeding.UNKNOWN), bleeding) { bleeding = it }
        addView(summary)
        addView(codeText)
        update()

        addView(ui.button("What to say to 999", R.drawable.ic_sos, Ui.B.TONAL) {
            val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date())
            ui.dialog().setTitle("Say this to 999")
                .setMessage("Call 999, ask for Police, then Mountain Rescue.\n\n" + SosText.emergency(situation(), fix()?.let { LatLon(it.lat, it.lon) }, time) +
                    "\n\nGive the number of people and keep the line open. On satellite, calls don't work: text 999 if you registered for emergencySMS.")
                .setPositiveButton("Call 999") { _, _ -> host.startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:999"))) }
                .setNeutralButton("Copy") { _, _ -> host.copy("999", SosText.emergency(situation(), fix()?.let { LatLon(it.lat, it.lon) }, time)) }
                .setNegativeButton("Close", null).show()
        })
        val contact = app.prefs.emergencyContact
        if (contact.isNotBlank()) addView(ui.button("Text this to ${FallAlert.contactName(host).ifBlank { contact }}", null, Ui.B.OUTLINED) {
            val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date())
            val body = SosText.contact(situation(), fix()?.let { LatLon(it.lat, it.lon) }, fix()?.altitudeM?.toInt(), time, app.getSystemService(android.os.BatteryManager::class.java)?.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1)
            runCatching { host.startActivity(FallAlert.composeIntent(contact, body)) }.onFailure { host.toast("No SMS app available") }
        })
        addView(ui.row {
            addView(ui.button(if (sharing) "Update what my group sees" else "Share with my trip group", null, Ui.B.TONAL) {
                app.prefs.triageCode = code().takeIf { it != 0 } ?: 0
                host.toast("Your group sees this with your position while you need help.")
                refresh()
            }, ui.lp(0, weight = 1f))
            if (sharing) addView(ui.button("Clear", null, Ui.B.TEXT) { app.prefs.triageCode = 0; refresh() }, ui.lp(0, weight = 1f))
        })
    }
}
