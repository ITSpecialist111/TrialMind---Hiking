package com.trailmind.app.data

import com.trailmind.app.map.TileProvider
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.Geo
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.math.roundToInt

object OsNames {
    data class Place(val name: String, val type: String, val area: String, val position: LatLon, val grid: String?, val zoom: Double)

    class Request {
        private var connection: HttpURLConnection? = null
        private var cancelled = false

        @Synchronized fun attach(conn: HttpURLConnection): Boolean {
            if (cancelled) return false
            connection = conn
            return true
        }

        @Synchronized fun cancel() {
            cancelled = true
            connection?.disconnect()
            connection = null
        }

        @Synchronized fun clear(conn: HttpURLConnection) {
            if (connection === conn) connection = null
        }
    }

    fun search(query: String, key: String, request: Request = Request()): List<Place> {
        if (key.isBlank()) throw IOException("Add your OS Data Hub API key in Settings to search places.")
        return parse(get("https://api.os.uk/search/names/v1/find?query=${URLEncoder.encode(query, "UTF-8")}&maxresults=20&key=${URLEncoder.encode(key, "UTF-8")}",
            request, 10_000, 15_000))
    }

    private const val SETTLEMENTS = "LOCAL_TYPE:City LOCAL_TYPE:Town LOCAL_TYPE:Village LOCAL_TYPE:Hamlet LOCAL_TYPE:Other_Settlement LOCAL_TYPE:Suburban_Area"
    // Only types the API accepts: an unknown LOCAL_TYPE fails the whole request.
    private const val LANDSCAPE = "LOCAL_TYPE:Hill_Or_Mountain LOCAL_TYPE:Hill_Or_Mountain_Ranges LOCAL_TYPE:Valley LOCAL_TYPE:Woodland_Or_Forest " +
        "LOCAL_TYPE:Inland_Water LOCAL_TYPE:Waterfall LOCAL_TYPE:Cirque_Or_Hollow LOCAL_TYPE:Cliff_Or_Slope LOCAL_TYPE:Island LOCAL_TYPE:Bay " +
        "LOCAL_TYPE:Beach LOCAL_TYPE:Other_Landform LOCAL_TYPE:Other_Landcover"

    /** A name for a downloaded area from the settlement, else hill, wood or water, nearest its centre, e.g. "Parkend, Forest of Dean". */
    fun areaName(box: BoundingBox, key: String): String? {
        val grid = OsGrid.fromWgs84(box.center) ?: return null
        val point = "${grid.easting.roundToInt()},${grid.northing.roundToInt()}"
        val entry = nearest(point, key, SETTLEMENTS) ?: nearest(point, key, LANDSCAPE) ?: nearest(point, key, null) ?: return null
        return areaName(entry.optString("NAME1"), entry.optString("LOCAL_TYPE"), entry.optString("POPULATED_PLACE"),
            entry.optString("DISTRICT_BOROUGH").ifBlank { entry.optString("COUNTY_UNITARY") },
            Geo.distanceM(box.minLat, box.minLon, box.maxLat, box.maxLon) / 1000)
    }

    /** Big areas are named after their district; roads and postcodes give way to the place they are in. */
    internal fun areaName(name: String, type: String, populatedPlace: String, district: String, diagonalKm: Double): String? {
        val area = district.substringBefore(" - ").trim()
        val place = (if (type.contains("Road", true) || type.contains("Postcode", true)) populatedPlace else name).trim()
        return when {
            diagonalKm >= 20 && area.isNotEmpty() -> area
            place.isEmpty() -> area.ifEmpty { null }
            area.isEmpty() || area.equals(place, ignoreCase = true) -> place
            else -> "$place, $area"
        }
    }

    private fun nearest(point: String, key: String, filter: String?): JSONObject? {
        val url = "https://api.os.uk/search/names/v1/nearest?point=$point&radius=1000" +
            (filter?.let { "&fq=" + URLEncoder.encode(it, "UTF-8").replace("+", "%20") } ?: "") +
            "&key=" + URLEncoder.encode(key, "UTF-8")
        return JSONObject(get(url, Request(), 4_000, 4_000)).optJSONArray("results")?.optJSONObject(0)?.optJSONObject("GAZETTEER_ENTRY")
    }

    private fun get(url: String, request: Request, connectMs: Int, readMs: Int): String {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            if (!request.attach(conn)) throw IOException("Search cancelled")
            conn.connectTimeout = connectMs
            conn.readTimeout = readMs
            conn.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
            val code = conn.responseCode
            if (code != 200) throw IOException(when (code) {
                401, 403 -> "OS Names could not use this API key. Check it in Settings."
                429 -> "OS Names is busy. Please try again later."
                else -> "OS Names returned HTTP $code."
            })
            return conn.inputStream.use { input ->
                val bytes = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    bytes.write(buffer, 0, count)
                    if (bytes.size() > 1_000_000) throw IOException("OS Names response was too large.")
                }
                bytes.toString("UTF-8")
            }
        } catch (error: IOException) {
            if (error.message?.startsWith("OS Names") == true) throw error
            throw IOException("Could not reach OS Names. Check your connection and try again.")
        } finally {
            request.clear(conn)
            conn.disconnect()
        }
    }

    internal fun parse(json: String): List<Place> {
        val results = JSONObject(json).optJSONArray("results") ?: return emptyList()
        return (0 until results.length()).mapNotNull { index ->
            val entry = results.optJSONObject(index)?.optJSONObject("GAZETTEER_ENTRY") ?: return@mapNotNull null
            val name = entry.optString("NAME1").ifBlank { return@mapNotNull null }
            val east = entry.optDouble("GEOMETRY_X")
            val north = entry.optDouble("GEOMETRY_Y")
            if (!east.isFinite() || !north.isFinite()) return@mapNotNull null
            val type = entry.optString("LOCAL_TYPE")
            val area = listOf("POPULATED_PLACE", "DISTRICT_BOROUGH", "COUNTY_UNITARY", "POSTCODE_DISTRICT")
                .map { entry.optString(it) }.firstOrNull { it.isNotBlank() && it != name } ?: ""
            Place(name, type, area, OsGrid.toWgs84(east, north), OsGrid.letters(east, north)?.let { com.trailmind.core.geo.OsGridRef(east, north).format(6) },
                if (type.contains("County", true) || type.contains("City", true)) 12.0 else 15.0)
        }
    }
}