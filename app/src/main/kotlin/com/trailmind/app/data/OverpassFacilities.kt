package com.trailmind.app.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.JsonReader
import com.trailmind.app.Async
import com.trailmind.app.frontier.SatelliteNetworkManager
import com.trailmind.app.map.TileProvider
import com.trailmind.core.geo.Facility
import com.trailmind.core.geo.FacilityCategory
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.RouteFacilities
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

data class SavedFacilities(val fetchedMs: Long, val items: List<Facility>, val partial: Boolean = false)

object OverpassFacilities {
    const val ATTRIBUTION = "Facilities: © OpenStreetMap contributors"
    private val servers = listOf("https://overpass-api.de/api/interpreter", "https://overpass.openstreetmap.fr/api/interpreter")
    private const val MAX_BYTES = 12 * 1024 * 1024
    private const val MAX_ELEMENTS = 900
    private val fetching = HashSet<Long>()
    private val listeners = HashMap<Long, MutableSet<(Result<SavedFacilities>) -> Unit>>()
    private val cacheLock = Any()
    private val deletedRoutes = HashSet<Long>()

    fun isFetching(routeId: Long): Boolean = routeId in fetching

    fun addListener(routeId: Long, listener: (Result<SavedFacilities>) -> Unit) {
        listeners.getOrPut(routeId) { LinkedHashSet() }.add(listener)
    }

    fun removeListener(routeId: Long, listener: (Result<SavedFacilities>) -> Unit) {
        listeners[routeId]?.remove(listener)
        if (listeners[routeId]?.isEmpty() == true) listeners.remove(routeId)
    }

    fun start(context: Context, routeId: Long, points: List<LatLon>): Boolean {
        if (!fetching.add(routeId)) return false
        Async.run({ fetch(context.applicationContext, routeId, points) }) { result ->
            fetching.remove(routeId)
            listeners[routeId]?.toList()?.forEach { it(result) }
        }
        return true
    }

    fun online(context: Context): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    fun fetch(context: Context, routeId: Long, points: List<LatLon>): SavedFacilities {
        require(points.isNotEmpty())
        if (SatelliteNetworkManager.onSatellite(context)) throw IOException("Facilities need normal signal: TrailMind doesn't download them over satellite.")
        val query = query(points)
        var lastError: IOException? = null
        for (server in servers) {
            try {
                val (items, partial) = request(server, query, points)
                val saved = SavedFacilities(System.currentTimeMillis(), items, partial || RouteFacilities.corridorM(points) < 250)
                val json = JSONObject().put("fetchedMs", saved.fetchedMs).put("partial", saved.partial).put("items", JSONArray().apply {
                    items.forEach { item -> put(JSONObject()
                        .put("category", item.category.name).put("lat", item.position.lat).put("lon", item.position.lon)
                        .put("name", item.name).put("ele", item.ele).put("openingHours", item.openingHours)
                        .put("fee", item.fee).put("access", item.access).put("website", item.website)
                        .put("alongM", item.alongM).put("offM", item.offM)) }
                }).toString()
                val target = file(context, routeId).apply { parentFile?.mkdirs() }
                val temporary = File(target.parentFile, "$routeId.tmp")
                synchronized(cacheLock) {
                    if (routeId in deletedRoutes) throw IOException("Route was deleted.")
                    try {
                        temporary.writeText(json)
                        if (!temporary.renameTo(target)) throw IOException()
                    } catch (e: IOException) {
                        temporary.delete()
                        throw IOException("Could not save facilities offline.", e)
                    }
                }
                return saved
            } catch (e: IOException) {
                lastError = e
                if (synchronized(cacheLock) { routeId in deletedRoutes } || e.message == "Could not save facilities offline." ||
                    e.message.orEmpty().contains(Regex("HTTP 4\\d\\d")) && !e.message.orEmpty().contains("HTTP 429")) break
            }
        }
        throw lastError ?: IOException("Facilities are unavailable.")
    }

    fun saved(context: Context, routeId: Long): SavedFacilities? = runCatching {
        val json = JSONObject(file(context, routeId).readText())
        val array = json.getJSONArray("items")
        SavedFacilities(json.getLong("fetchedMs"), (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            Facility(FacilityCategory.valueOf(item.getString("category")), LatLon(item.getDouble("lat"), item.getDouble("lon")),
                item.optString("name"), item.optString("ele"), item.optString("openingHours"), item.optString("fee"),
                item.optString("access"), item.optString("website"), item.getDouble("alongM"), item.getDouble("offM"))
        }, json.optBoolean("partial", false))
    }.getOrNull()

    fun hasSaved(context: Context, routeId: Long): Boolean = file(context, routeId).exists()

    fun delete(context: Context, routeId: Long) {
        synchronized(cacheLock) {
            deletedRoutes.add(routeId)
            file(context, routeId).delete()
        }
    }

    private fun file(context: Context, routeId: Long) = File(context.filesDir, "pois/$routeId.json")

    private fun query(points: List<LatLon>): String {
        val radius = RouteFacilities.corridorM(points)
        val corridor = RouteFacilities.simplify(points, if (radius < 250) 50 else 150).joinToString(",") { "${it.lat},${it.lon}" }
        val start = points.first()
        val finish = points.last()
        val filters = listOf(
            "[amenity~\"^(drinking_water|water_point|toilets|pub|cafe|restaurant|parking|shelter)$\"]",
            "[man_made=water_tap][drinking_water=yes]", "[shop~\"^(convenience|supermarket)$\"]",
            "[highway=bus_stop]", "[railway~\"^(station|halt)$\"]",
            "[tourism~\"^(camp_site|hostel|guest_house|hotel|wilderness_hut|viewpoint)$\"]",
            "[building=hut]", "[natural=peak][name]",
        )
        val around = if (points.size == 1) "around:$radius,${start.lat},${start.lon}" else "around:$radius,$corridor"
        return buildString {
            append("[out:json][timeout:120];(")
            filters.forEach { append("nwr($around)$it;") }
            for (point in listOf(start, finish).distinct()) {
                val nearby = "around:800,${point.lat},${point.lon}"
                listOf("[amenity=parking]", "[highway=bus_stop]", "[railway~\"^(station|halt)$\"]").forEach {
                    append("nwr($nearby)$it;")
                }
            }
            append(");out center tags $MAX_ELEMENTS;")
        }
    }

    private fun parse(input: InputStream, points: List<LatLon>): Pair<List<Facility>, Boolean> {
        val items = ArrayList<Facility>()
        var elements = 0
        var partial = false
        try {
            JsonReader(InputStreamReader(LimitedInputStream(input), Charsets.UTF_8)).use { reader ->
                reader.beginObject()
                while (reader.hasNext()) when (reader.nextName()) {
                    "elements" -> {
                        reader.beginArray()
                        while (reader.hasNext()) {
                            readElement(reader)?.let { items.add(it) }
                            elements++
                        }
                        reader.endArray()
                    }
                    "remark" -> {
                        val remark = reader.nextString()
                        if (remark.contains("runtime error", ignoreCase = true)) partial = true
                    }
                    else -> reader.skipValue()
                }
                reader.endObject()
            }
        } catch (_: ResponseLimit) {
            partial = true
        }
        if (partial && items.isEmpty() && elements == 0) throw IOException("Overpass returned no facilities before its limit.")
        return RouteFacilities.locate(points, items, RouteFacilities.corridorM(points)) to (partial || elements >= MAX_ELEMENTS)
    }

    private fun readElement(reader: JsonReader): Facility? {
        var lat: Double? = null
        var lon: Double? = null
        val tags = HashMap<String, String>()
        reader.beginObject()
        while (reader.hasNext()) when (reader.nextName()) {
            "lat" -> lat = reader.nextDouble()
            "lon" -> lon = reader.nextDouble()
            "center" -> {
                reader.beginObject()
                while (reader.hasNext()) when (reader.nextName()) {
                    "lat" -> lat = reader.nextDouble()
                    "lon" -> lon = reader.nextDouble()
                    else -> reader.skipValue()
                }
                reader.endObject()
            }
            "tags" -> {
                reader.beginObject()
                while (reader.hasNext()) tags[reader.nextName()] = reader.nextString()
                reader.endObject()
            }
            else -> reader.skipValue()
        }
        reader.endObject()
        val category = FacilityCategory.fromTags(tags) ?: return null
        return Facility(category, LatLon(lat ?: return null, lon ?: return null),
            tags["name"].orEmpty(), tags["ele"].orEmpty(), tags["opening_hours"].orEmpty(),
            tags["fee"].orEmpty(), tags["access"].orEmpty(), tags["website"].orEmpty())
    }

    private class ResponseLimit : IOException()

    private class LimitedInputStream(input: InputStream) : FilterInputStream(input) {
        private var bytes = 0
        override fun read(): Int {
            if (bytes >= MAX_BYTES) throw ResponseLimit()
            return super.read().also { if (it >= 0) bytes++ }
        }
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (bytes >= MAX_BYTES) throw ResponseLimit()
            return `in`.read(buffer, offset, minOf(length, MAX_BYTES - bytes)).also { if (it > 0) bytes += it }
        }
    }

    private fun request(server: String, query: String, points: List<LatLon>): Pair<List<Facility>, Boolean> {
        val conn = URL(server).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = 15_000
            conn.readTimeout = 145_000
            conn.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
            conn.outputStream.use { it.write("data=${URLEncoder.encode(query, "UTF-8")}".toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            if (code != 200) throw IOException("Overpass answered HTTP $code.")
            return conn.inputStream.use { parse(it, points) }
        } finally { conn.disconnect() }
    }
}