package com.trailmind.app.ui

import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.SystemClock
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import com.trailmind.app.R
import com.trailmind.app.frontier.group.GroupFinder
import com.trailmind.app.frontier.group.GroupRadio
import com.trailmind.app.frontier.group.GroupSharing
import com.trailmind.app.frontier.group.UwbRadio
import com.trailmind.app.location.TrackingService
import com.trailmind.core.format.Units
import com.trailmind.core.frontier.EmergencyStatus
import com.trailmind.core.frontier.group.GroupCode
import com.trailmind.core.frontier.group.GroupFrames
import com.trailmind.core.frontier.group.PeerTable
import com.trailmind.core.frontier.group.needsHelp
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import java.text.DateFormat
import java.util.Date
import kotlin.math.abs

private const val DISCLOSURE = "TrailMind will share your precise location, battery level and safety status with everyone who " +
    "has this group's code, directly between phones over Bluetooth. This happens while TrailMind is open and while you record " +
    "a hike, even with the screen off; a notification shows while a hike records.\n\nMembers' phones may pass your position " +
    "on to others in the group who are out of range. Nothing goes to TrailMind or any server. Group positions are deleted " +
    "when the trip ends or you leave.\n\nAndroid will now ask to allow Nearby devices."

/** "45 s", "12 min", "3 h 5 min". */
fun groupAge(seconds: Long): String {
    val s = seconds.coerceAtLeast(0)
    return when {
        s < 90 -> "$s s"
        s < 3_600 -> "${s / 60} min"
        else -> "${s / 3_600} h ${(s % 3_600) / 60} min"
    }
}

/** "just now" under a minute, then "12 min ago": coarse, so pages needn't redraw every second. */
fun groupAgo(seconds: Long): String = if (seconds < 60) "just now" else "${groupAge(seconds)} ago"

/** Up to two letters for a map marker: "Sam Jones" is "SJ". */
fun groupInitials(name: String): String = name.split(' ', '-', '_').filter { it.isNotBlank() }.take(2)
    .joinToString("") { it.substring(0, it.offsetByCodePoints(0, 1)) }.uppercase().ifBlank { "?" }

private fun helpText(status: EmergencyStatus) = when (status) {
    EmergencyStatus.FALL_DETECTED -> "May have fallen"
    EmergencyStatus.CRITICAL_SOS -> "Needs help"
    EmergencyStatus.INJURED_STATIONARY -> "Hurt and can't move"
    EmergencyStatus.INJURED_MOVING -> "Hurt but moving"
    else -> ""
}

private fun inviteLink(name: String, code: GroupCode): String = Uri.Builder().scheme(MainActivity.GROUP_LINK_SCHEME).authority("group")
    .appendPath("join").appendQueryParameter("code", code.text).appendQueryParameter("name", name).build().toString()

private fun inviteText(name: String, code: GroupCode) = "Join my TrailMind trip group \"$name\".\n\nCode: ${code.formatted}\n\n" +
    "In TrailMind: Safety > Trip group > Join with code, or open ${inviteLink(name, code)}\n\n" +
    "Our phones then show each other on the map over Bluetooth, with no signal needed."

/** Explains what a trip group shares (Google Play's prominent disclosure), then asks for location and Nearby devices. */
private fun ensureGroupReady(host: MainActivity, then: () -> Unit) {
    val go = {
        host.withNearbyPermission {
            host.requestNotificationPermissionIfNeeded()
            then()
        }
    }
    if (host.app.prefs.groupDisclosureAccepted) {
        go()
        return
    }
    host.ui.dialog().setTitle("Share your location with your group")
        .setMessage(DISCLOSURE)
        .setPositiveButton("Continue") { _, _ ->
            host.app.prefs.groupDisclosureAccepted = true
            go()
        }
        .setNegativeButton("Not now", null)
        .show()
}

private fun askDisplayName(host: MainActivity, then: (String) -> Unit) {
    host.ui.prompt("Your name in the group", host.app.prefs.groupDisplayName, "Shown on the others' maps",
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS) { then(it.ifBlank { "Hiker" }) }
}

/** A group joined while a hike records also needs the recording's connected-device foreground-service type. */
private fun afterJoin(host: MainActivity) = TrackingService.send(host, TrackingService.ACTION_REFRESH_FRONTIER)

private fun confirmLeaving(host: MainActivity, action: String, then: () -> Unit) {
    val current = host.app.group.group ?: return then()
    host.ui.confirm("Leave ${current.name}?",
        "TrailMind is in one trip group at a time. $action leaves ${current.name} and deletes what this phone knows about its members.",
        "Continue") { then() }
}

fun startGroupCreate(host: MainActivity, then: () -> Unit) {
    if (!GroupRadio.supported()) { host.toast("Trip groups need Android 12 or newer."); return }
    confirmLeaving(host, "A new group") {
        host.ui.prompt("Name this trip", "Trip " + DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date()), "Trip name",
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES) { tripName ->
            askDisplayName(host) { me ->
                ensureGroupReady(host) {
                    host.app.group.create(tripName, me) {
                        afterJoin(host)
                        then()
                    }
                }
            }
        }
    }
}

fun startGroupJoin(host: MainActivity, code: GroupCode? = null, name: String? = null, then: () -> Unit) {
    if (!GroupRadio.supported()) { host.toast("Trip groups need Android 12 or newer."); return }
    if (code == null) {
        host.ui.prompt("Join a trip group", "", "Code, e.g. K7QM-2XRA-9PTW-4HNE",
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS) { text ->
            val parsed = GroupCode.parse(text)
            if (parsed != null) startGroupJoin(host, parsed, name, then)
            else host.ui.dialog().setTitle("That code isn't right")
                .setMessage("Check it with whoever made the group: 16 letters and numbers, like K7QM-2XRA-9PTW-4HNE. Case and dashes don't matter.")
                .setPositiveButton("Try again") { _, _ -> startGroupJoin(host, null, name, then) }
                .setNegativeButton("Cancel", null)
                .show()
        }
        return
    }
    if (host.app.group.group?.code == code) { then(); return }
    confirmLeaving(host, "Joining this one") {
        askDisplayName(host) { me ->
            ensureGroupReady(host) {
                host.app.group.join(code, name ?: "Trip group", me) {
                    afterJoin(host)
                    then()
                }
            }
        }
    }
}

/** Handles trailmind://group/join?code=…&name=… from an invite. */
fun joinGroupFromLink(host: MainActivity, link: Uri) {
    if (link.host != "group") return
    val code = link.getQueryParameter("code")?.let(GroupCode::parse)
    val name = link.getQueryParameter("name")?.trim()?.take(40)?.ifBlank { null }
    if (code == null) { host.toast("This trip group invite isn't complete. Ask for the code instead."); return }
    host.showTab(MainActivity.Tab.SAFETY)
    host.ui.confirm("Join ${name ?: "this trip group"}?", "Phones in a trip group show each other on the map over Bluetooth.", "Join") {
        startGroupJoin(host, code, name) { host.push(GroupPage(host)) }
    }
}

/** A member's details, with Go to (bearing and distance) and Show on map. */
fun showGroupMember(host: MainActivity, peer: PeerTable.Peer) {
    val app = host.app
    val sharing = app.group
    val imperial = app.prefs.imperial
    val pos = peer.position
    val nowS = sharing.nowS()
    val lines = ArrayList<String>()
    if (pos == null) lines += "No position from them yet."
    else {
        if (pos.status.needsHelp) lines += "⚠ ${helpText(pos.status)}"
        lines += "Position ${groupAge(nowS - pos.originTimeS)} old, " +
            if (pos.hops == 0) "straight from their phone" else "passed on by ${pos.hops} phone${if (pos.hops > 1) "s" else ""}"
        app.location.latest?.let { f ->
            val here = LatLon(f.lat, f.lon)
            val there = LatLon(pos.lat, pos.lon)
            val b = Geo.bearingDeg(here, there)
            lines += "${Units.distance(Geo.distanceM(here, there), imperial)} at ${Units.bearing(b)} ${Geo.cardinal(b)} from you (straight line)"
        }
        OsGrid.fromWgs84(LatLon(pos.lat, pos.lon))?.format(8)?.let { lines += "Grid ref $it" }
        pos.altitudeM?.let { lines += "Height about ${Units.elevation(it.toDouble(), imperial)}" }
        lines += "Accuracy ±${pos.accuracyM} m · battery ${pos.batteryPercent}%"
        when {
            pos.flags and GroupFrames.FLAG_PAUSED != 0 -> lines += "Hike paused"
            pos.flags and GroupFrames.FLAG_RECORDING != 0 -> lines += "Recording a hike"
        }
    }
    val now = System.currentTimeMillis()
    lines += when {
        sharing.inRange(peer) -> "In range now" + (peer.rssi?.let { " · $it dBm" } ?: "") + if (peer.coded) " · long range" else ""
        peer.lastDirectMs > 0 -> "Last heard directly ${groupAge((now - peer.lastDirectMs) / 1_000)} ago"
        else -> "Only heard through other phones"
    }
    val dialog = host.ui.dialog().setTitle(sharing.nameOf(peer)).setMessage(lines.joinToString("\n")).setNegativeButton("Close", null)
    if (pos != null) {
        val there = LatLon(pos.lat, pos.lon)
        dialog.setPositiveButton("Go to") { _, _ ->
            app.nav.setTarget(there)
            host.map.centerOn(there, maxOf(host.map.mapView.zoom, 14.0))
        }
        dialog.setNeutralButton("Show on map") { _, _ -> host.map.centerOn(there, maxOf(host.map.mapView.zoom, 15.0)) }
    }
    dialog.show()
}

// ====================================================================== trip group page

class GroupPage(host: MainActivity) : Page(host) {
    // Members report every few seconds; redraw only when what the page shows changes, so TalkBack keeps its place.
    private var shown: String? = null
    private val onGroup: () -> Unit = { if (signature() != shown) refresh() }

    override fun onShow() {
        app.group.addListener(onGroup)
        app.group.finder.addListener(onGroup)
        refresh()
    }

    override fun onHide() {
        app.group.removeListener(onGroup)
        app.group.finder.removeListener(onGroup)
    }

    override fun refresh() {
        shown = signature()
        super.refresh()
    }

    private fun signature(): String {
        val s = app.group
        val nowS = s.nowS()
        fun age(originS: Long) = (nowS - originS).let { if (it < 60) 0 else it / 60 + 1 }
        return buildString {
            val g = s.group
            append(g?.id).append(g?.displayName).append(g?.expiresMs).append('|').append(s.statusLine())
            append('|').append((s.boostUntilMs - System.currentTimeMillis()).coerceAtLeast(0) / 60_000)
            append('|').append(app.prefs.frontierHeartbeatsEnabled).append(s.plan == null)
            append('|').append(app.prefs.groupUwbFindable).append(s.finder.uwb.capabilities.state)
            s.finder.state?.let { f -> append('|').append(f.role).append(f.memberId).append(f.phase).append(f.nonce) }
            s.ownFrame?.let { append('|').append(age(it.originTimeS)).append(it.status) }
            app.location.latest?.let { append('|').append(Math.round(it.lat * 5_000)).append(',').append(Math.round(it.lon * 5_000)) }
            s.members.forEach { p ->
                append('|').append(p.memberId).append(p.name).append(p.colour).append(s.inRange(p)).append(p.coded).append(s.finder.canFind(p))
                p.position?.let { pos ->
                    append(pos.status).append(pos.hops > 0).append(pos.batteryPercent / 5).append(age(pos.originTimeS))
                    append(Math.round(pos.lat * 5_000)).append(',').append(Math.round(pos.lon * 5_000))
                }
            }
        }
    }

    override fun render(): View = scaffold("Trip group") {
        val sharing = app.group
        val g = sharing.group
        if (g == null) {
            addView(introCard { refresh() })
            return@scaffold
        }
        val prefs = app.prefs
        val now = System.currentTimeMillis()
        sharing.finder.state?.takeIf { it.active }?.let { f ->
            val who = sharing.members.firstOrNull { it.memberId == f.memberId }?.let(sharing::nameOf) ?: "A member"
            addView(ui.card(color = p.primaryContainer, spacing = 8) {
                addView(ui.text(if (f.role == GroupFinder.Role.FOUND) "$who is finding you with UWB" else "Finding $who with UWB", Ui.T.TITLE))
                addView(ui.row {
                    addView(ui.button("Open", null, Ui.B.TONAL) { host.push(GroupFindPage(host, f.memberId)) }, ui.lp(0, weight = 1f))
                    addView(ui.button("Stop", null, Ui.B.TEXT) { sharing.finder.stop() }, ui.lp(0, weight = 1f))
                })
            })
        }
        addView(ui.card(spacing = 8) {
            addView(ui.text(g.name, Ui.T.TITLE))
            val readiness = sharing.readiness()
            addView(ui.text(sharing.statusLine(), Ui.T.BODY, if (readiness == GroupSharing.Readiness.READY) p.primary else p.danger))
            when (readiness) {
                GroupSharing.Readiness.PERMISSIONS -> addView(ui.button("Allow Nearby devices", null, Ui.B.TONAL) {
                    ensureGroupReady(host) { sharing.settingsChanged(); refresh() }
                })
                GroupSharing.Readiness.BLUETOOTH_OFF -> addView(ui.button("Turn on Bluetooth", null, Ui.B.TONAL) {
                    try {
                        host.startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
                    } catch (e: SecurityException) {
                        host.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    } catch (e: android.content.ActivityNotFoundException) {
                        host.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    }
                })
                GroupSharing.Readiness.OFF -> addView(ui.text("Frontier safety features are off on the Safety page.", Ui.T.CAPTION))
                else -> Unit
            }
            if (abs(sharing.clockSkewMs) > 5 * 60_000L) addView(ui.banner("This phone's clock is ${groupAge(abs(sharing.clockSkewMs) / 1_000)} " +
                "out from GPS time. TrailMind allows for it, but set Date and time to automatic."))
            val boostLeft = (sharing.boostUntilMs - now) / 60_000
            addView(ui.button(if (boostLeft > 0) "Finding the group · ${boostLeft + 1} min left" else "Find my group", R.drawable.ic_my_location,
                if (boostLeft > 0) Ui.B.TONAL else Ui.B.FILLED) {
                sharing.boost()
                host.toast("Listening hard for 30 minutes. This uses more battery.")
            })
            addView(ui.text("Find my group listens and broadcasts flat out for 30 minutes. A call for help from anyone in the group does the same.", Ui.T.CAPTION))
        })

        addView(ui.card(spacing = 6) {
            addView(ui.text("Members", Ui.T.TITLE))
            addView(memberRow(groupInitials(g.displayName), sharing.ownColour(), "You · ${g.displayName}",
                if (prefs.frontierHeartbeatsEnabled) ownSubtitle() else "Your position isn't shared", false) { renameMe() })
            val peers = sharing.members.sortedWith(
                compareByDescending<PeerTable.Peer> { it.position?.status?.needsHelp == true }
                    .thenBy { if (sharing.inRange(it)) 0 else 1 }
                    .thenBy { sharing.nameOf(it).lowercase() },
            )
            if (peers.isEmpty()) addView(ui.text("No one heard yet. Others appear when their phone is in Bluetooth range with TrailMind open or a hike recording.", Ui.T.CAPTION))
            peers.forEach { peer ->
                val find = if (sharing.finder.canFind(peer)) ui.button("Find", null, Ui.B.TONAL) { startFind(peer) } else null
                addView(memberRow(groupInitials(sharing.nameOf(peer)), sharing.colourOf(peer), sharing.nameOf(peer), subtitle(peer),
                    peer.position?.status?.needsHelp == true, find) { showGroupMember(host, peer) })
            }
        })

        addView(ui.card(spacing = 8) {
            addView(ui.text("Invite", Ui.T.TITLE))
            addView(ui.text("Read the code out to the others, or send it. Anyone with it can see the group while in Bluetooth range, so share it only with your party.", Ui.T.CAPTION))
            addView(ui.text(g.code.formatted, Ui.T.MONO).apply {
                textSize = 22f
                letterSpacing = 0.08f
                setTextIsSelectable(true)
            })
            addView(ui.row {
                addView(ui.button("Send invite", R.drawable.ic_share, Ui.B.TONAL) { host.shareText("TrailMind trip group", inviteText(g.name, g.code)) }, ui.lp(0, weight = 1f))
                addView(ui.button("Copy code", null, Ui.B.TEXT) { host.copy("Trip group code", g.code.formatted) }, ui.lp(0, weight = 1f))
            })
        })

        addView(ui.card(spacing = 6) {
            addView(ui.text("Trip ends " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(g.expiresMs)), Ui.T.BODY))
            addView(ui.text("Then this phone stops sharing and deletes the group. A hike that's still recording keeps it going.", Ui.T.CAPTION))
            addView(ui.button("Add a day", R.drawable.ic_add, Ui.B.TONAL) { sharing.extend(); host.toast("The trip now ends a day later.") })
        })

        addView(ui.card(spacing = 4) {
            addView(ui.text("Sharing", Ui.T.TITLE))
            addView(ui.switch("Share my position with the group", prefs.frontierHeartbeatsEnabled) {
                prefs.frontierHeartbeatsEnabled = it; app.frontier.applySettings(); sharing.settingsChanged()
            })
            addView(ui.switch("Pass on other members' positions", prefs.groupRelayEnabled) { prefs.groupRelayEnabled = it; sharing.settingsChanged() })
            addView(ui.switch("Show the group on the map", prefs.groupShowOnMap) { prefs.groupShowOnMap = it; sharing.settingsChanged() })
            addView(ui.switch("Long range when the phone supports it", prefs.groupLongRange) { prefs.groupLongRange = it; sharing.settingsChanged() })
            addView(ui.switch("Alert me if someone needs help", prefs.groupHelpAlerts) { prefs.groupHelpAlerts = it })
            if (UwbRadio.supported(host)) {
                addView(ui.switch("Let the group find me up close with UWB", prefs.groupUwbFindable) {
                    prefs.groupUwbFindable = it
                    if (it) host.withRangingPermission { sharing.settingsChanged() } else sharing.settingsChanged()
                })
                val uwb = sharing.finder.uwb.capabilities.state
                addView(ui.text(when (uwb) {
                    UwbRadio.State.READY -> "UWB is on. Members close by with UWB show a Find button for distance and direction."
                    UwbRadio.State.NO_PERMISSION -> "UWB needs the Nearby devices permission."
                    UwbRadio.State.OFF -> "UWB is off. Turn on Ultra-wideband (UWB) in Settings to find members up close."
                    UwbRadio.State.BLOCKED -> "UWB isn't available now, for example in flight mode."
                    UwbRadio.State.CHECKING -> "Checking this phone's UWB…"
                    UwbRadio.State.UNSUPPORTED -> "This phone's UWB can't be used by apps."
                }, Ui.T.CAPTION))
                if (uwb == UwbRadio.State.NO_PERMISSION) addView(ui.button("Allow UWB", null, Ui.B.TONAL) {
                    host.withRangingPermission { sharing.settingsChanged() }
                })
            }
            addView(ui.text("Passing on positions lets the group reach further than one phone: each phone between two hikers adds a hop. " +
                "Range depends on phones, pockets and ground, from tens of metres in woods to more in the open. Carry the phone high on your body.", Ui.T.CAPTION))
        })

        addView(ui.button("Leave ${g.name}", R.drawable.ic_close, Ui.B.OUTLINED) {
            ui.confirm("Leave ${g.name}?", "This phone stops sharing and deletes the group's code and what it knows about the members.", "Leave", danger = true) {
                sharing.leave()
                host.toast("Left ${g.name}")
            }
        })
        addView(ui.listItem("Bluetooth diagnostics", "What the radio is doing, and a reception log for range tests", R.drawable.ic_tune) {
            host.push(GroupDiagnosticsPage(host))
        })
    }

    private fun introCard(done: () -> Unit): View = groupIntroCard(host, done)

    private fun renameMe() {
        askDisplayName(host) { name -> app.group.rename(name) }
    }

    private fun startFind(peer: PeerTable.Peer) {
        host.withRangingPermission {
            app.group.finder.find(peer.memberId)
            host.push(GroupFindPage(host, peer.memberId))
        }
    }

    private fun ownSubtitle(): String {
        val own = app.group.ownFrame ?: return "Waiting for a GPS fix"
        val parts = arrayListOf("Shared ${groupAgo(app.group.nowS() - own.originTimeS)}")
        if (own.status.needsHelp) parts += helpText(own.status)
        if (app.group.plan == null) parts += "sharing paused until TrailMind is open or a hike records"
        return parts.joinToString(" · ")
    }

    private fun subtitle(peer: PeerTable.Peer): String {
        val sharing = app.group
        val pos = peer.position
        val parts = ArrayList<String>()
        if (pos != null && pos.status.needsHelp) parts += helpText(pos.status)
        if (pos == null) parts += "no position yet"
        else {
            parts += groupAgo(sharing.nowS() - pos.originTimeS)
            app.location.latest?.let { f ->
                val here = LatLon(f.lat, f.lon)
                val there = LatLon(pos.lat, pos.lon)
                parts += "${Units.distance(Geo.distanceM(here, there), app.prefs.imperial)} ${Geo.cardinal(Geo.bearingDeg(here, there))}"
            }
            parts += "${pos.batteryPercent}%"
        }
        parts += when {
            sharing.inRange(peer) -> if (peer.coded) "in range (long range)" else "in range"
            pos != null && pos.hops > 0 -> "passed on"
            else -> "out of range"
        }
        return parts.joinToString(" · ")
    }

    private fun memberRow(initials: String, colour: Int, title: String, subtitle: String, help: Boolean, action: View? = null, onClick: () -> Unit): View =
        ui.row(spacing = 12) {
            setPadding(0, ui.dp(6), 0, ui.dp(6))
            isClickable = true
            setOnClickListener { onClick() }
            addView(TextView(host).apply {
                text = initials
                gravity = Gravity.CENTER
                setTextColor(android.graphics.Color.WHITE)
                textSize = 13f
                typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
                background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(if (help) p.danger else colour) }
                contentDescription = title
            }, LinearLayout.LayoutParams(ui.dp(36), ui.dp(36)))
            addView(ui.column {
                addView(ui.text(title, Ui.T.BODY))
                addView(ui.text(subtitle, Ui.T.CAPTION, if (help) p.danger else p.muted))
            }, ui.lp(0, weight = 1f))
            action?.let { addView(it, ui.lp(ViewGroup.LayoutParams.WRAP_CONTENT)) }
        }
}

/** Explains trip groups and offers Create and Join; on the Safety page and the empty Trip group page. */
fun groupIntroCard(host: MainActivity, done: () -> Unit): View = host.ui.card(spacing = 8) {
    val ui = host.ui
    addView(ui.text("See your party on the map, with no signal", Ui.T.TITLE))
    addView(ui.text("Each phone in the group shares its position straight to the others over Bluetooth, sealed with the group's code, " +
        "and passes on the others' positions so the group reaches further than one phone can. It works while TrailMind is open " +
        "or a hike is recording, with no mobile signal.", Ui.T.BODY))
    addView(ui.text("Range depends on phones, pockets and ground: tens of metres in woods, more in the open, and further along " +
        "a strung-out group.", Ui.T.CAPTION))
    if (!GroupRadio.supported()) {
        addView(ui.banner("Trip groups need Android 12 or newer."))
        return@card
    }
    addView(ui.row {
        addView(ui.button("Create group", R.drawable.ic_add, Ui.B.FILLED) { startGroupCreate(host, done) }, ui.lp(0, weight = 1f))
        addView(ui.button("Join with code", null, Ui.B.TONAL) { startGroupJoin(host, then = done) }, ui.lp(0, weight = 1f))
    })
}
