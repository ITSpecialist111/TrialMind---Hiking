package com.trailmind.app.data

import android.content.Context
import com.trailmind.app.Async
import com.trailmind.app.TrailMindApp
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.map.Lidar
import com.trailmind.core.map.LidarRouteCheck
import com.trailmind.core.map.LidarRouteReport
import com.trailmind.core.map.LidarSection
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException

data class SavedLidarCheck(val checkedMs: Long, val report: LidarRouteReport)

/** Route checks against 1 m LiDAR: downloads the squares along a route, finds steep ground and crags, and keeps the result. */
object LidarChecks {
    /** Squares within this of the line are enough for the check: crags are looked for 10 m either side. */
    private const val CORRIDOR_M = 20.0

    class Progress(@Volatile var done: Int = 0, @Volatile var total: Int = 0)

    private val running = HashMap<Long, Progress>()
    private val errors = HashMap<Long, String>()
    private val listeners = HashMap<Long, MutableSet<() -> Unit>>()
    private val lock = Any()
    private val deleted = HashSet<Long>()

    fun progress(routeId: Long): Progress? = running[routeId]
    fun error(routeId: Long): String? = errors[routeId]

    fun addListener(routeId: Long, listener: () -> Unit) {
        listeners.getOrPut(routeId) { LinkedHashSet() }.add(listener)
    }

    fun removeListener(routeId: Long, listener: () -> Unit) {
        listeners[routeId]?.remove(listener)
        if (listeners[routeId]?.isEmpty() == true) listeners.remove(routeId)
    }

    /** The squares a check of [points] needs, and how many of them aren't on the phone yet. */
    fun squares(points: List<LatLon>): List<Lidar.Square> = Lidar.corridor(points.map { OsGrid.project(it) }, CORRIDOR_M)

    fun start(context: Context, routeId: Long, points: List<LatLon>): Boolean {
        if (routeId in running || points.size < 2) return false
        val progress = Progress()
        running[routeId] = progress
        errors.remove(routeId)
        synchronized(lock) { deleted.remove(routeId) }
        val appContext = context.applicationContext
        Async.run({ check(appContext, routeId, points, progress) }) { result ->
            running.remove(routeId)
            result.exceptionOrNull()?.let { errors[routeId] = it.message ?: "LiDAR check failed." }
            notify(routeId)
        }
        return true
    }

    private fun check(context: Context, routeId: Long, points: List<LatLon>, progress: Progress): SavedLidarCheck {
        val lidar = TrailMindApp.instance.lidar
        val squares = squares(points)
        if (squares.isEmpty()) throw IOException("LiDAR covers England only.")
        progress.total = squares.size
        val (_, failed) = lidar.download(squares, cancelled = { synchronized(lock) { routeId in deleted } }) { done ->
            progress.done = done
            if (done % 4 == 0) Async.main.post { notify(routeId) }
        }
        if (synchronized(lock) { routeId in deleted }) throw IOException("Route was deleted.")
        if (failed == squares.size) throw IOException("Couldn't download LiDAR. Check the connection and try again.")
        val report = LidarRouteCheck.check(points, lidar.ground())
        val saved = SavedLidarCheck(System.currentTimeMillis(), report)
        val json = JSONObject().put("checkedMs", saved.checkedMs).put("lengthM", report.lengthM).put("coveredM", report.coveredM)
            .put("steep", sections(report.steep)).put("crags", sections(report.crags)).toString()
        val target = file(context, routeId).apply { parentFile?.mkdirs() }
        val temporary = File(target.parentFile, "$routeId.tmp")
        synchronized(lock) {
            if (routeId in deleted) throw IOException("Route was deleted.")
            try {
                temporary.writeText(json)
                if (!temporary.renameTo(target)) throw IOException("Could not save the LiDAR check.")
            } finally {
                temporary.delete()
            }
        }
        return saved
    }

    fun saved(context: Context, routeId: Long): SavedLidarCheck? = runCatching {
        val json = JSONObject(file(context, routeId).readText())
        SavedLidarCheck(json.getLong("checkedMs"), LidarRouteReport(json.getDouble("lengthM"), json.getDouble("coveredM"),
            sections(json.getJSONArray("steep")), sections(json.getJSONArray("crags"))))
    }.getOrNull()

    fun delete(context: Context, routeId: Long) {
        synchronized(lock) {
            deleted.add(routeId)
            file(context, routeId).delete()
        }
    }

    private fun notify(routeId: Long) = listeners[routeId]?.toList()?.forEach { it() }

    private fun sections(list: List<LidarSection>) = JSONArray().apply {
        list.forEach { put(JSONObject().put("s", it.startM).put("e", it.endM).put("v", it.value).put("lat", it.at.lat).put("lon", it.at.lon)) }
    }

    private fun sections(array: JSONArray) = (0 until array.length()).map { i ->
        val o = array.getJSONObject(i)
        LidarSection(o.getDouble("s"), o.getDouble("e"), o.getDouble("v"), LatLon(o.getDouble("lat"), o.getDouble("lon")))
    }

    private fun file(context: Context, routeId: Long) = File(context.filesDir, "lidar-checks/$routeId.json")
}
