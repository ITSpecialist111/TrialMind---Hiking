package com.trailmind.app.location

import com.trailmind.app.Async
import com.trailmind.app.map.MercatorLine
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.stats.TrackStats
import java.util.concurrent.CopyOnWriteArraySet

/** In-memory view of the hike being recorded. Mutated on the main thread only. */
object TrackingState {
    enum class Status { IDLE, RECORDING, PAUSED }

    var status = Status.IDLE; private set
    var hikeId: Long? = null; private set
    var hikeName: String = ""; private set
    var startMs = 0L; private set
    private var activeAccumMs = 0L
    private var activeSinceMs: Long? = null

    val line = MercatorLine()
    val points = ArrayList<TrackPoint>()
    var distanceM = 0.0; private set
    var ascentM = 0.0; private set
    var descentM = 0.0; private set
    private var eleRef: Double? = null
    private var needBreak = false

    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    fun addListener(l: () -> Unit) = listeners.add(l)
    fun removeListener(l: () -> Unit) = listeners.remove(l)
    private fun changed() = listeners.forEach { it() }

    fun activeMs(now: Long = System.currentTimeMillis()): Long =
        activeAccumMs + (activeSinceMs?.let { now - it } ?: 0L)

    fun begin(id: Long, name: String, start: Long, restored: List<List<TrackPoint>>, restoredActiveMs: Long) = Async.ui {
        hikeId = id; hikeName = name; startMs = start
        points.clear(); line.clear(); distanceM = 0.0; ascentM = 0.0; descentM = 0.0; eleRef = null
        for (seg in restored) {
            needBreak = true
            seg.forEach { addInternal(it) }
        }
        needBreak = restored.isNotEmpty()
        activeAccumMs = restoredActiveMs
        activeSinceMs = System.currentTimeMillis()
        status = Status.RECORDING
        changed()
    }

    fun add(p: TrackPoint) = Async.ui {
        if (status != Status.RECORDING) return@ui
        addInternal(p)
        changed()
    }

    private fun addInternal(p: TrackPoint) {
        val last = points.lastOrNull()
        if (needBreak) {
            line.breakHere()
            needBreak = false
            eleRef = null
        } else if (last != null) {
            distanceM += Geo.distanceM(last.lat, last.lon, p.lat, p.lon)
        }
        p.ele?.let { e ->
            val ref = eleRef
            if (ref == null) eleRef = e else {
                val d = e - ref
                if (d >= TrackStats.DEFAULT_ELEVATION_THRESHOLD_M) { ascentM += d; eleRef = e }
                else if (-d >= TrackStats.DEFAULT_ELEVATION_THRESHOLD_M) { descentM += -d; eleRef = e }
            }
        }
        points.add(p)
        line.add(p.latLon())
    }

    fun pause() = Async.ui {
        if (status != Status.RECORDING) return@ui
        activeSinceMs?.let { activeAccumMs += System.currentTimeMillis() - it }
        activeSinceMs = null
        status = Status.PAUSED
        changed()
    }

    fun resume() = Async.ui {
        if (status != Status.PAUSED) return@ui
        activeSinceMs = System.currentTimeMillis()
        needBreak = true
        status = Status.RECORDING
        changed()
    }

    fun end() = Async.ui {
        status = Status.IDLE
        hikeId = null
        activeSinceMs = null
        activeAccumMs = 0
        points.clear()
        line.clear()
        distanceM = 0.0; ascentM = 0.0; descentM = 0.0
        changed()
    }
}
