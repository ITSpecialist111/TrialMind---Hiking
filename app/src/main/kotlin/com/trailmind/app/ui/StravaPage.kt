package com.trailmind.app.ui

import android.text.InputType
import android.view.View
import com.trailmind.app.R
import com.trailmind.core.strava.StravaActivityKind
import com.trailmind.core.strava.StravaOAuth
import com.trailmind.core.strava.StravaPolicy

/**
 * Links TrailMind to the user's Strava account, and sets whether finished hikes are posted by themselves.
 * Strava's sign-in needs a client secret that mustn't ship inside an app, so each user brings their own Strava
 * application (free, two minutes), the same way they bring their own OS Data Hub and MapTiler keys.
 */
class StravaPage(host: MainActivity) : Page(host) {
    private val strava get() = app.strava
    private val onChange: () -> Unit = { refresh() }
    private var note: String? = null

    private companion object { const val WAITING = "Sign in on Strava" }

    override fun onShow() { strava.addListener(onChange) }
    override fun onHide() { strava.removeListener(onChange) }

    override fun render(): View = scaffold("Strava") {
        when {
            strava.linked -> { if (note?.startsWith(WAITING) == true) note = null; linkedCards() }
            strava.needsReconnect -> {
                addView(ui.banner("Strava stopped accepting TrailMind, so hikes can't be posted. Connect again to carry on. Hikes already on Strava aren't affected.", danger = true))
                setupCard(reconnect = true)
            }
            else -> setupCard(reconnect = false)
        }
    }

    private fun android.widget.LinearLayout.linkedCards() {
        val prefs = app.prefs
        val who = strava.athlete()
        addView(ui.card(spacing = 8) {
            addView(ui.text("Linked to Strava", Ui.T.LABEL))
            addView(ui.text(who?.display ?: "Your Strava account", Ui.T.HEADLINE))
            addView(ui.text("TrailMind posts your hikes to this account. Hikes you've already uploaded stay as they are.", Ui.T.CAPTION))
            note?.let { addView(ui.text(it, Ui.T.CAPTION, p.primary)) }
        })
        val waiting = app.db.stravaWaitingCount()
        if (waiting > 0) addView(ui.banner("$waiting hike${if (waiting > 1) "s are" else " is"} waiting to be posted. They go as soon as the phone has signal.", icon = R.drawable.ic_upload))
        addView(ui.card(spacing = 6) {
            addView(ui.text("Posting", Ui.T.TITLE))
            addView(ui.switch("Post each hike to Strava automatically", prefs.stravaAuto) { prefs.stravaAuto = it })
            addView(ui.text("Post hikes as", Ui.T.LABEL))
            addView(ui.flow {
                StravaActivityKind.entries.forEach { kind ->
                    addView(ui.chip(kind.label, prefs.stravaKind == kind.code) { prefs.stravaKind = kind.code; refresh() })
                }
            })
            addView(ui.text("A hike is posted when you finish it, with its name, track, times and heights, as \"${StravaPolicy.DESCRIPTION}\". " +
                "Recordings under ${StravaPolicy.MIN_DISTANCE_M.toInt()} m are skipped. Your Strava privacy settings decide who sees it. " +
                "Without signal it's posted later. Each hike can be posted by hand from its page too.", Ui.T.CAPTION))
        })
        addView(ui.card(spacing = 8) {
            who?.let { w ->
                addView(ui.button("View my Strava profile", null, Ui.B.TONAL) { host.openUrl("https://www.strava.com/athletes/${w.id}") })
            }
            addView(ui.button("Disconnect from Strava", R.drawable.ic_close, Ui.B.OUTLINED) {
                ui.confirm("Disconnect from Strava?", "TrailMind stops posting your hikes and tells Strava to forget it. Hikes already on Strava stay there. " +
                    "Your application's Client ID and secret stay saved so you can connect again.", "Disconnect", danger = true) {
                    strava.disconnect()
                    note = null
                    host.toast("Disconnected from Strava")
                }
            })
            addView(ui.button("Forget my Strava application", null, Ui.B.TEXT) {
                ui.confirm("Forget the application?", "Disconnects, and deletes the Client ID and secret from this phone.", "Forget", danger = true) {
                    strava.disconnect(forget = true)
                    note = null
                }
            })
        })
    }

    private fun android.widget.LinearLayout.setupCard(reconnect: Boolean) {
        val prefs = app.prefs
        addView(ui.card(spacing = 8) {
            addView(ui.text(if (reconnect) "Connect to Strava again" else "Post your hikes to Strava", Ui.T.TITLE))
            addView(ui.banner("Automatic posting needs a Strava subscription: since June 2026 Strava only lets subscribers create the application it relies on. " +
                "Without one, use Upload to Strava on any hike's page: one tap saves the GPX and opens Strava's upload page.", icon = R.drawable.ic_upload))
            addView(ui.text("Link TrailMind to your Strava account once, and every hike you finish is posted by itself, with no files to save or upload. " +
                "Strava only lets an app post for you if the app is registered with it, and the secret that proves it must stay private, " +
                "so TrailMind uses your own free Strava application. It takes about two minutes:", Ui.T.CAPTION))
            addView(ui.text("1. Open strava.com/settings/api and sign in (Google sign-in works there). It asks for a subscription before you can create an application.\n" +
                "2. Create an application: any name (TrailMind will do), any category, any website (https://localhost is fine), " +
                "and set Authorization Callback Domain to  ${StravaOAuth.CALLBACK_DOMAIN}\n" +
                "3. Copy its Client ID and Client Secret into the boxes below.\n" +
                "4. Tap Connect with Strava, sign in and approve, leaving \"Upload your activities\" ticked.", Ui.T.BODY))
            addView(ui.button("Open Strava API settings", null, Ui.B.TONAL) { host.openUrl("https://www.strava.com/settings/api") })
            val id = ui.input("Client ID (a number)", prefs.stravaClientId, InputType.TYPE_CLASS_NUMBER)
            // The saved secret isn't shown (reading it means waking the keystore); leaving the box blank keeps it.
            val secret = ui.input(if (prefs.hasStravaSecret) "Client Secret (saved: leave blank to keep it)" else "Paste your Client Secret",
                "", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)
            addView(ui.text("Client ID", Ui.T.LABEL))
            addView(id, ui.lp())
            addView(ui.text("Client Secret", Ui.T.LABEL))
            addView(secret, ui.lp())
            addView(ui.button("Connect with Strava", R.drawable.ic_upload) {
                val url = strava.beginConnect(id.text.toString(), secret.text.toString()) { message -> note = message; refresh() }
                if (url != null) {
                    note = "$WAITING and approve. You'll come straight back here."
                    host.openUrl(url)
                    refresh()
                }
            })
            (strava.linkNote ?: note)?.let { addView(ui.text(it, Ui.T.CAPTION, if (it.startsWith(WAITING)) p.primary else p.danger)) }
            addView(ui.text("The secret is kept encrypted on this phone and is only ever sent to Strava. Strava's rules let an application you create " +
                "serve your own account, which is exactly this. Nothing about your hikes goes anywhere but your Strava.", Ui.T.CAPTION))
        })
    }
}
