package com.trailmind.app.data

import com.trailmind.app.map.TileProvider
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

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
        val url = "https://api.os.uk/search/names/v1/find?query=${URLEncoder.encode(query, "UTF-8")}&maxresults=20&key=${URLEncoder.encode(key, "UTF-8")}"
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            if (!request.attach(conn)) throw IOException("Search cancelled")
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            conn.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
            val code = conn.responseCode
            if (code != 200) throw IOException(when (code) {
                401, 403 -> "OS Names could not use this API key. Check it in Settings."
                429 -> "OS Names is busy. Please try again later."
                else -> "OS Names returned HTTP $code."
            })
            val json = conn.inputStream.use { input ->
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
            return parse(json)
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