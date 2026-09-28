package com.trailmind.app.data

import com.trailmind.app.TrailMindApp
import com.trailmind.app.frontier.SatelliteNetworkManager
import com.trailmind.app.map.TileProvider
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.PathJoin
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.WebMercator
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.math.abs

/**
 * Waymarked walking routes from OpenStreetMap, found and downloaded through the Waymarked Trails API.
 * The data is © OpenStreetMap contributors under the ODbL, so [ATTRIBUTION] must be shown with it.
 */
object WaymarkedTrails {
    private const val API = "https://hiking.waymarkedtrails.org/api/v1"
    const val ATTRIBUTION = "Routes © OpenStreetMap contributors (ODbL), found with Waymarked Trails. Heights: ASTER GDEM is a product of METI and NASA."

    /** Height samples come every 2 m (about 30 kB per km), so they are skipped for longer trails. */
    const val ELEVATION_MAX_M = 60_000.0
    private const val SAMPLE_SPACING_M = 10.0
    private const val MAX_BYTES = 12 * 1024 * 1024

    data class Trail(val id: Long, val name: String, val ref: String?, val group: String) {
        val kind: String get() = when (group) {
            "INT" -> "International trail"
            "NAT" -> "National trail"
            "REG" -> "Regional route"
            "LOC" -> "Local walk"
            else -> "Waymarked route"
        }
        val webUrl: String get() = "https://hiking.waymarkedtrails.org/#route?id=$id"
    }

    data class Download(val name: String, val points: List<TrackPoint>, val lengthM: Double, val hasElevation: Boolean)

    fun search(query: String): List<Trail> =
        trails(get("$API/list/search?query=${URLEncoder.encode(query, "UTF-8")}&limit=30"))

    /** Routes crossing [box], most important (international, national) first. */
    fun inArea(box: BoundingBox): List<Trail> {
        val (x1, y1) = WebMercator.toMetres(LatLon(box.minLat, box.minLon))
        val (x2, y2) = WebMercator.toMetres(LatLon(box.maxLat, box.maxLon))
        return trails(get("$API/list/by_area?bbox=${x1.toLong()},${y1.toLong()},${x2.toLong()},${y2.toLong()}&limit=40"))
    }

    fun download(trail: Trail): Download {
        val details = JSONObject(get("$API/details/relation/${trail.id}"))
        val route = details.getJSONObject("route")
        val lengthM = route.optDouble("length", 0.0)
        val heights = if (lengthM > 0 && lengthM <= ELEVATION_MAX_M) runCatching { heights(trail.id) }.getOrNull() else null
        val pieces = ArrayList<List<TrackPoint>>()
        collect(route, heights, pieces)
        val points = PathJoin.join(pieces, ordered = route.optString("linear") != "no")
        require(points.size >= 2) { "OpenStreetMap has no usable line for this route yet." }
        return Download(details.optString("name").ifBlank { trail.name }, points, lengthM, !heights.isNullOrEmpty())
    }

    private fun trails(json: String): List<Trail> {
        val results = JSONObject(json).optJSONArray("results") ?: return emptyList()
        return (0 until results.length()).mapNotNull { i ->
            val r = results.getJSONObject(i)
            if (r.optString("type", "relation") != "relation") return@mapNotNull null
            val name = r.optString("name").ifBlank { r.optString("ref") }.ifBlank { return@mapNotNull null }
            Trail(r.getLong("id"), name, r.optString("ref").ifBlank { null }, r.optString("group"))
        }
    }

    /**
     * Flattens the route tree into lines: "route" and "split" segments hold further segments ("split"
     * has a forward and a backward branch, forward is used), "linear" holds ways that already join up
     * in route order. Appendices (alternatives and detours) are left out.
     */
    private fun collect(seg: JSONObject, heights: Map<Long, List<Sample>>?, out: MutableList<List<TrackPoint>>) {
        when (seg.optString("route_type")) {
            "route" -> seg.optJSONArray("main").forEachObject { collect(it, heights, out) }
            "split" -> seg.optJSONArray("forward").forEachObject { collect(it, heights, out) }
            "linear" -> {
                val line = ArrayList<TrackPoint>()
                seg.optJSONArray("ways").forEachObject { way ->
                    for (p in wayPoints(way, heights)) if (line.isEmpty() || line.last().lat != p.lat || line.last().lon != p.lon) line += p
                }
                if (line.size >= 2) out += line
            }
            "base" -> wayPoints(seg, heights).takeIf { it.size >= 2 }?.let { out += it }
        }
    }

    /** A way's line, using its height samples (thinned to every [SAMPLE_SPACING_M]) when there are some. */
    private fun wayPoints(way: JSONObject, heights: Map<Long, List<Sample>>?): List<TrackPoint> {
        val coords = way.optJSONObject("geometry")?.optJSONArray("coordinates") ?: return emptyList()
        if (coords.length() < 2) return emptyList()
        val samples = heights?.get(way.optLong("id"))
        if (samples != null && samples.size >= 2) {
            val x0 = coords.getJSONArray(0).getDouble(0)
            val y0 = coords.getJSONArray(0).getDouble(1)
            // Samples follow the way as drawn in OpenStreetMap, which can be against the route direction.
            val s = if (samples.last().sq(x0, y0) < samples.first().sq(x0, y0)) samples.asReversed() else samples
            val out = ArrayList<TrackPoint>()
            var lastPos = 0.0
            s.forEachIndexed { i, p ->
                if (i == 0 || i == s.lastIndex || abs(p.pos - lastPos) >= SAMPLE_SPACING_M) {
                    val ll = WebMercator.fromMetres(p.x, p.y)
                    out += TrackPoint(ll.lat, ll.lon, p.ele)
                    lastPos = p.pos
                }
            }
            return out
        }
        return (0 until coords.length()).map { i ->
            val c = coords.getJSONArray(i)
            val ll = WebMercator.fromMetres(c.getDouble(0), c.getDouble(1))
            TrackPoint(ll.lat, ll.lon)
        }
    }

    private class Sample(val x: Double, val y: Double, val ele: Double?, val pos: Double) {
        fun sq(ox: Double, oy: Double) = (x - ox) * (x - ox) + (y - oy) * (y - oy)
    }

    private fun heights(id: Long): Map<Long, List<Sample>> {
        val segments = JSONObject(get("$API/details/relation/$id/way-elevation")).optJSONObject("segments") ?: return emptyMap()
        val out = HashMap<Long, List<Sample>>()
        for (key in segments.keys()) {
            val wayId = key.toLongOrNull() ?: continue
            val list = ArrayList<Sample>()
            segments.optJSONObject(key)?.optJSONArray("elevation").forEachObject { e ->
                val ele = e.optDouble("ele")
                list += Sample(e.getDouble("x"), e.getDouble("y"), if (ele.isNaN()) null else ele, e.optDouble("pos", 0.0))
            }
            if (list.isNotEmpty()) out[wayId] = list
        }
        return out
    }

    private inline fun JSONArray?.forEachObject(block: (JSONObject) -> Unit) {
        if (this == null) return
        for (i in 0 until length()) optJSONObject(i)?.let(block)
    }

    private fun get(url: String): String {
        if (SatelliteNetworkManager.onSatellite(TrailMindApp.instance)) throw IOException("Finding routes needs normal signal: TrailMind doesn't search over satellite.")
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
            val code = conn.responseCode
            if (code != 200) throw IOException("Waymarked Trails answered HTTP $code.")
            return conn.inputStream.use { input ->
                val out = ByteArrayOutputStream()
                val buf = ByteArray(32 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > MAX_BYTES) throw IOException("This route is too large to download in one piece.")
                }
                out.toString("UTF-8")
            }
        } finally {
            conn.disconnect()
        }
    }
}
