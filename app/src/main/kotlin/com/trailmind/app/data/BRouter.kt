package com.trailmind.app.data

import com.trailmind.app.map.TileProvider
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.TrackPoint
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

object BRouter {
    class NoPath(message: String) : IOException(message)
    private val cache = object : LinkedHashMap<Pair<LatLon, LatLon>, List<TrackPoint>>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Pair<LatLon, LatLon>, List<TrackPoint>>?) = size > 50
    }

    class Request {
        private var connection: HttpURLConnection? = null
        private var cancelled = false

        @Synchronized fun attach(conn: HttpURLConnection): Boolean {
            if (cancelled) return false
            connection = conn
            return true
        }

        fun cancel() {
            val conn = synchronized(this) {
                cancelled = true
                connection.also { connection = null }
            }
            conn?.disconnect()
        }

        @Synchronized fun clear(conn: HttpURLConnection) {
            if (connection === conn) connection = null
        }

        @Synchronized fun isCancelled() = cancelled

        @Synchronized fun ifActive(action: () -> Unit): Boolean {
            if (cancelled) return false
            action()
            return true
        }
    }

    fun leg(start: LatLon, end: LatLon, request: Request = Request()): List<TrackPoint> {
        if (request.isCancelled()) throw IOException("Routing cancelled")
        val key = start to end
        synchronized(cache) { cache[key]?.let { return it } }
        val url = String.format(Locale.ROOT,
            "https://brouter.de/brouter?lonlats=%.6f,%.6f|%.6f,%.6f&profile=hiking-mountain&alternativeidx=0&format=geojson",
            start.lon, start.lat, end.lon, end.lat)
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            if (!request.attach(connection)) throw IOException("Routing cancelled")
            connection.connectTimeout = 20_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
            if (connection.responseCode != 200) {
                val body = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                if (connection.responseCode == 400 && body.contains(Regex("no track|no route|no path|island|position.*not mapped", RegexOption.IGNORE_CASE))) {
                    throw NoPath(body.take(160))
                }
                throw IOException("BRouter HTTP ${connection.responseCode}: ${body.take(160)}")
            }
            val json = connection.inputStream.bufferedReader().use { it.readText() }
            val features = JSONObject(json).getJSONArray("features")
            if (features.length() == 0) throw NoPath("No path")
            val feature = features.getJSONObject(0)
            if (feature.getJSONObject("geometry").getString("type") != "LineString") throw NoPath("No path")
            val coords = feature.getJSONObject("geometry").getJSONArray("coordinates")
            val points = (0 until coords.length()).map { index ->
                val coordinate = coords.getJSONArray(index)
                TrackPoint(coordinate.getDouble(1), coordinate.getDouble(0),
                    if (coordinate.length() > 2 && !coordinate.isNull(2)) coordinate.getDouble(2) else null)
            }
            if (points.size < 2) throw NoPath("No path")
            if (!request.ifActive { synchronized(cache) { cache[key] = points } }) throw IOException("Routing cancelled")
            return points
        } finally {
            request.clear(connection)
            connection.disconnect()
        }
    }
}