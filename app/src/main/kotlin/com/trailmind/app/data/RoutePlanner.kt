package com.trailmind.app.data

import android.util.Log
import com.trailmind.app.Async
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.PlanLeg
import com.trailmind.core.geo.RoutePlan
import java.util.concurrent.Executors

class RoutePlanner(private val db: Db, private val networkAllowed: () -> Boolean) {
    val plan = RoutePlan()
    var active = false
        private set
    var snap = true
    var notice: String? = null
        private set
    val pending: Boolean get() = requests.isNotEmpty()
    var saving = false
        private set
    private var saveResult: Result<Long>? = null
    private var generation = 0
    val version: Int get() = generation
    private val requests = HashMap<Int, Pair<PlanLeg, BRouter.Request>>()
    private val routeQueue = Executors.newSingleThreadExecutor { task -> Thread(task, "trailmind-routing").apply { isDaemon = true } }
    private val listeners = mutableSetOf<(String?) -> Unit>()

    fun addListener(listener: (String?) -> Unit) { listeners += listener; listener(null) }
    fun removeListener(listener: (String?) -> Unit) { listeners -= listener }
    private fun notify(message: String? = null) { listeners.toList().forEach { it(message) } }

    fun takeSaveResult(): Result<Long>? = saveResult.also { saveResult = null }

    fun save(title: String) {
        if (saving || !active || pending || plan.legs.isEmpty() || title.isBlank()) return
        saving = true
        val line = plan.line.toList()
        val savedVersion = generation
        notify()
        Async.run({ db.insertRoute(title, line, emptyList()) }) { result ->
            saving = false
            if (result.isSuccess && generation == savedVersion) close()
            saveResult = result
            notify()
        }
    }

    fun start(at: LatLon? = null) {
        if (saving) return
        generation++
        plan.clear()
        requests.values.forEach { it.second.cancel() }
        requests.clear()
        notice = null
        snap = true
        active = true
        at?.let { plan.add(it) }
        notify()
    }

    fun add(at: LatLon) {
        if (saving || !active || !plan.add(at)) return
        generation++
        notice = null
        routeLast()
    }

    fun backToStart() {
        if (saving || !active || !plan.backToStart()) return
        generation++
        notice = null
        routeLast()
    }

    private fun routeLast() {
        notify()
        if (!snap || plan.legs.isEmpty()) return
        val legIndex = plan.legs.lastIndex
        val leg = plan.legs[legIndex]
        if (!networkAllowed()) {
            showNotice("Offline: this leg is a straight line")
            return
        }
        val request = BRouter.Request()
        requests[legIndex] = leg to request
        notify()
        routeQueue.execute {
            if (request.isCancelled()) return@execute
            val result = runCatching { BRouter.leg(leg.start, leg.end, request) }
            Async.main.post {
                if (!active || requests[legIndex]?.second !== request) return@post
                requests.remove(legIndex)
                val snapped = result.getOrNull()?.let { plan.replaceLeg(legIndex, it, leg) } == true
                if (snapped) notify() else {
                    result.exceptionOrNull()?.let { Log.w("TrailMind", "routing leg failed", it) }
                    val text = when {
                        !networkAllowed() -> "Offline: this leg is a straight line"
                        result.exceptionOrNull() is BRouter.NoPath -> "No path found here, so this leg is a straight line"
                        else -> "Routing service unavailable, so this leg is a straight line"
                    }
                    showNotice(text)
                }
            }
        }
    }

    private fun showNotice(text: String) {
        notice = text
        notify(text)
        Async.main.postDelayed({
            if (notice == text && active) { notice = null; notify() }
        }, 6_000)
    }

    fun undo() {
        if (saving) return
        generation++
        requests.remove(plan.legs.lastIndex)?.second?.cancel()
        plan.undo()
        notice = null
        notify()
    }

    fun clear() {
        if (saving) return
        generation++
        requests.values.forEach { it.second.cancel() }
        requests.clear()
        plan.clear()
        notice = null
        notify()
    }

    fun cancelPending() {
        if (requests.isEmpty()) return
        requests.values.forEach { it.second.cancel() }
        requests.clear()
        notify()
    }

    fun close() {
        if (saving) return
        clear()
        active = false
        notify()
    }
}