package com.trailmind.app.frontier

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.TextView
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.ui.Ui
import com.trailmind.app.ui.clockTime
import com.trailmind.app.ui.toast
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid

/**
 * The fall alarm screen. It shows over the lock screen, so it offers only the alarm's own actions:
 * I'm OK (which needs the phone unlocked), the SOS text and 999. Opening TrailMind itself still needs the phone unlocked.
 */
class FallAlertActivity : Activity() {
    private val app get() = TrailMindApp.instance
    private lateinit var ui: Ui
    private var countdown: TextView? = null
    private var okRequested = false
    private val onChange: () -> Unit = { render() }
    private val tick = object : Runnable {
        override fun run() {
            updateCountdown()
            Async.main.postDelayed(this, 1_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT < 27) window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    override fun onResume() {
        super.onResume()
        FallAlert.addListener(onChange)
        render()
        Async.main.post(tick)
        // The unlock prompt needs the screen in front, so a notification's I'm OK waits until now.
        if (okRequested) { okRequested = false; imOk() }
    }

    override fun onPause() {
        FallAlert.removeListener(onChange)
        Async.main.removeCallbacks(tick)
        super.onPause()
    }

    private fun handle(intent: Intent?) {
        when (intent?.action) {
            ACTION_SEND -> { intent.action = null; sendNow() }
            ACTION_OK -> { intent.action = null; okRequested = true }
        }
    }

    private fun sendNow() {
        FallAlert.sendNow(this)
        if (FallAlert.stage(this) == FallAlert.Stage.TEXT_READY) compose(FallAlert.recipientNumber(this), FallAlert.message(this))
    }

    /** Anyone may send the SOS text from the lock screen, but only the owner may cancel the alarm. */
    private fun imOk() {
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard?.isKeyguardLocked != true) { FallAlert.ok(this); return }
        keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
            override fun onDismissSucceeded() = FallAlert.ok(this@FallAlertActivity)
        })
    }

    private fun compose(number: String, body: String) {
        runCatching { startActivity(FallAlert.composeIntent(number, body)) }.onFailure { toast("No SMS app available") }
    }

    private fun updateCountdown() {
        val left = ((FallAlert.deadlineMs(this) - System.currentTimeMillis()) / 1_000).coerceAtLeast(0)
        countdown?.text = "%d:%02d".format(left / 60, left % 60)
    }

    private fun render() {
        val stage = FallAlert.stage(this)
        if (stage == FallAlert.Stage.NONE) { finish(); return }
        val p = ui.p
        val prefs = app.prefs
        val name = FallAlert.contactName(this).ifBlank { "your emergency contact" }
        val sat = app.frontier.satelliteState
        countdown = null
        val body = ui.column(padding = 24, spacing = 14) {
            when (stage) {
                FallAlert.Stage.COUNTDOWN -> {
                    addView(ui.text("Possible fall detected", Ui.T.LABEL, p.danger))
                    addView(ui.text("Are you OK?", Ui.T.DISPLAY))
                    countdown = ui.text("", Ui.T.DISPLAY, p.danger).also { addView(it) }
                    addView(ui.text(if (FallAlert.canSendItself(this@FallAlertActivity)) "If you don't answer, TrailMind texts $name your location."
                        else "If you don't answer, TrailMind gets a text to $name ready for you to send.", Ui.T.BODY))
                }
                FallAlert.Stage.TEXT_READY -> {
                    addView(ui.text(when {
                        FallAlert.attempts(this@FallAlertActivity) >= FallAlert.MAX_ATTEMPTS -> "Your SOS text didn't send"
                        prefs.sosSituation == FallAlert.NO_RESPONSE -> "No answer to the fall alarm"
                        else -> "Send your SOS text"
                    }, Ui.T.HEADLINE))
                    addView(ui.text("Your text to $name is ready with your location. Check it, then send it.", Ui.T.BODY))
                }
                FallAlert.Stage.SENDING -> {
                    addView(ui.text("Sending SOS text to $name", Ui.T.HEADLINE))
                    val attempts = FallAlert.attempts(this@FallAlertActivity)
                    addView(ui.text(if (FallAlert.notSentYet(this@FallAlertActivity)) "Not sent yet. TrailMind tries every 2 minutes (attempt $attempts of ${FallAlert.MAX_ATTEMPTS})."
                        else "Sending your location now.", Ui.T.BODY))
                }
                FallAlert.Stage.SENT -> {
                    addView(ui.text("SOS text sent to $name", Ui.T.HEADLINE))
                    addView(ui.text("Sent at ${clockTime(this@FallAlertActivity, FallAlert.sentMs(this@FallAlertActivity))} with your location.", Ui.T.BODY))
                }
                FallAlert.Stage.NONE -> Unit
            }
            val tellContact = stage == FallAlert.Stage.SENT && FallAlert.canTellRecipient(this@FallAlertActivity)
            addView(ui.button(if (tellContact) "I'm OK: tell $name" else "I'm OK", null, Ui.B.FILLED) { imOk() })
            when (stage) {
                FallAlert.Stage.COUNTDOWN -> addView(ui.button("Send SOS text now", R.drawable.ic_sos, Ui.B.DANGER) { sendNow() })
                FallAlert.Stage.TEXT_READY -> addView(ui.button("Text $name", R.drawable.ic_sos, Ui.B.DANGER) {
                    compose(FallAlert.recipientNumber(this@FallAlertActivity), FallAlert.message(this@FallAlertActivity))
                })
                else -> Unit
            }
            if (prefs.emergencySmsRegistered) addView(ui.button("Text 999", null, Ui.B.OUTLINED) {
                compose("999", FallAlert.emergencyMessage(this@FallAlertActivity))
            })
            addView(ui.button("Call 999", null, Ui.B.OUTLINED) {
                runCatching { startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:999"))) }
            })
            addView(ui.text(when {
                sat.textsOverSatellite -> "You're on ${sat.operatorName ?: "satellite"}: texts work but calls don't, including 999 calls. A text can take a few minutes."
                else -> "999 calls need mobile signal. Where only satellite reaches, texts still work."
            }, Ui.T.CAPTION))
            app.location.latest?.let { OsGrid.fromWgs84(LatLon(it.lat, it.lon))?.format(10) }?.let {
                addView(ui.text("Your grid reference: $it", Ui.T.TITLE).apply { setTextIsSelectable(true) })
            }
        }
        val root = ui.scroll(body).apply { setBackgroundColor(p.bg) }
        if (Build.VERSION.SDK_INT >= 30) root.setOnApplyWindowInsetsListener { v, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        setContentView(root)
        updateCountdown()
    }

    companion object {
        const val ACTION_SEND = "com.trailmind.app.fall.OPEN_SEND"
        const val ACTION_OK = "com.trailmind.app.fall.OPEN_OK"
    }
}
