package com.trailmind.app.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.widget.TextView
import com.trailmind.app.Async
import com.trailmind.app.frontier.group.GroupFinder
import com.trailmind.app.frontier.group.UwbRadio
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/** Distance and direction to one member over UWB, or who is finding this phone. */
class GroupFindPage(host: MainActivity, private val memberId: Int) : Page(host) {
    private var shown: Any? = null
    private var status: TextView? = null
    private var distance: TextView? = null
    private var direction: TextView? = null
    private var arrow: UwbArrowView? = null
    private val onChange: () -> Unit = { if (structure() != shown) refresh() else bind() }
    // Marks a measurement stale when results stop, which no callback reports.
    private val tick = object : Runnable {
        override fun run() {
            bind()
            Async.main.postDelayed(this, 1_000)
        }
    }

    override fun onShow() {
        app.group.finder.addListener(onChange)
        app.group.addListener(onChange)
        refresh()
        Async.main.postDelayed(tick, 1_000)
    }

    override fun onHide() {
        app.group.finder.removeListener(onChange)
        app.group.removeListener(onChange)
        Async.main.removeCallbacks(tick)
    }

    private fun mine(): GroupFinder.State? = app.group.finder.state?.takeIf { it.memberId == memberId }

    private fun name(): String = app.group.members.firstOrNull { it.memberId == memberId }?.let(app.group::nameOf) ?: "your group member"

    private fun structure(): Any {
        val s = mine()
        val peer = app.group.members.firstOrNull { it.memberId == memberId }
        return listOf(s?.role, s?.phase, s?.note, s?.nonce, peer?.let { app.group.finder.canFind(it) }, name())
    }

    override fun refresh() {
        shown = structure()
        super.refresh()
        bind()
    }

    override fun render(): View {
        val finder = app.group.finder
        val s = mine()
        val name = name()
        val found = s?.role == GroupFinder.Role.FOUND
        status = null; distance = null; direction = null; arrow = null
        return scaffold(if (found) "$name is finding you" else "Find $name") {
            addView(ui.card(spacing = 12) {
                status = ui.text("", Ui.T.BODY).also { addView(it) }
                if (s != null && s.active) {
                    if (!found && finder.uwb.capabilities.azimuth) arrow = UwbArrowView(host).also { addView(it, ui.lp(h = ui.dp(220))) }
                    distance = ui.text("—", Ui.T.DISPLAY).apply { gravity = Gravity.CENTER }.also { addView(it) }
                    if (!found && finder.uwb.capabilities.azimuth) direction = ui.text("", Ui.T.BODY).apply { gravity = Gravity.CENTER }.also { addView(it) }
                    addView(ui.button("Stop", null, Ui.B.OUTLINED) { finder.stop() })
                } else {
                    val peer = app.group.members.firstOrNull { it.memberId == memberId }
                    if (peer != null && finder.canFind(peer)) addView(ui.button(if (s == null) "Find $name" else "Try again", null, Ui.B.FILLED) {
                        host.withRangingPermission { finder.find(memberId) }
                    })
                }
            })
            addView(ui.card(spacing = 6) {
                addView(ui.text("How it works", Ui.T.TITLE))
                addView(ui.text("Ultra-wideband (UWB) measures the distance between two phones to within about 10 cm, up to about " +
                    "50 m when nothing is between them. Bodies, rock and trees shorten that. Both phones need TrailMind open or a hike " +
                    "recording, and UWB on. Flight mode turns UWB off.", Ui.T.CAPTION))
                if (!found) addView(ui.text(if (finder.uwb.capabilities.azimuth) "Hold the phone upright in front of you and turn slowly until the arrow points up."
                    else "This phone measures distance only: walk and watch the number fall.", Ui.T.CAPTION))
            })
        }
    }

    private fun bind() {
        val s = mine()
        val name = name()
        val m = s?.measurement
        val fresh = s != null && s.measuredAt > 0 && SystemClock.elapsedRealtime() - s.measuredAt < STALE_MS
        status?.text = when {
            s == null -> app.group.members.firstOrNull { it.memberId == memberId }?.let { peer ->
                if (app.group.finder.canFind(peer)) "Both phones have UWB. Find them to see how far away they are."
                else "$name's phone needs to be in Bluetooth range, with UWB, TrailMind open or a hike recording."
            } ?: "$name isn't in your group any more."
            !s.active -> s.note ?: "Stopped."
            s.role == GroupFinder.Role.FOUND -> if (fresh) "$name is finding you with UWB." else "$name is finding you with UWB. Waiting for their phone."
            s.phase == GroupFinder.Phase.ASKING -> "Asking $name's phone to answer…"
            s.phase == GroupFinder.Phase.STARTING -> s.note ?: "Starting UWB…"
            !fresh -> "Lost the UWB signal. Move closer, or somewhere nothing is between you."
            m?.distanceConfidence == 0 -> "Weak UWB signal: the distance may jump."
            else -> "Measuring with UWB."
        }
        distance?.text = m?.distanceM?.let { GroupFinder.uwbDistance(it, app.prefs.imperial) } ?: "—"
        distance?.alpha = if (fresh) 1f else 0.4f
        val azimuth = m?.azimuthDeg?.takeIf { fresh }
        arrow?.azimuthDeg = azimuth
        direction?.text = when {
            m == null || !fresh -> ""
            azimuth == null -> "Hold the phone upright in front of you to see which way."
            abs(azimuth) <= 10 -> "Straight ahead"
            azimuth > 0 -> "${azimuth.roundToInt()}° to your right"
            else -> "${(-azimuth).roundToInt()}° to your left"
        } + (m?.elevationDeg?.takeIf { fresh && abs(it) >= 20 }?.let { if (it > 0) " · above you" else " · below you" } ?: "")
    }

    companion object {
        private const val STALE_MS = 3_000L
    }
}

/** An arrow that points at the member: up is straight ahead, turned by the UWB azimuth. */
class UwbArrowView(context: Context) : View(context) {
    private val p = Palette.of(context)
    private val d = resources.displayMetrics.density
    var azimuthDeg: Double? = null
        set(v) { if (field != v) { field = v; invalidate() } }

    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = p.outline; strokeWidth = 2 * d }
    private val arrowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.primary }
    private val waiting = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.muted; alpha = 90 }
    private val shape = Path()

    override fun onDraw(c: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = min(width, height) / 2f - 8 * d
        c.drawCircle(cx, cy, r, ring)
        val az = azimuthDeg
        if (az == null) {
            c.drawCircle(cx, cy, r * 0.18f, waiting)
            return
        }
        c.save()
        c.rotate(az.toFloat(), cx, cy)
        shape.reset()
        shape.moveTo(cx, cy - r * 0.85f)
        shape.lineTo(cx + r * 0.32f, cy - r * 0.2f)
        shape.lineTo(cx + r * 0.11f, cy - r * 0.2f)
        shape.lineTo(cx + r * 0.11f, cy + r * 0.6f)
        shape.lineTo(cx - r * 0.11f, cy + r * 0.6f)
        shape.lineTo(cx - r * 0.11f, cy - r * 0.2f)
        shape.lineTo(cx - r * 0.32f, cy - r * 0.2f)
        shape.close()
        c.drawPath(shape, arrowPaint)
        c.restore()
    }
}
