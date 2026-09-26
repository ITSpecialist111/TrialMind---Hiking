package com.trailmind.app.data

import android.content.Context
import com.trailmind.app.map.TileProvider
import com.trailmind.core.geo.LatLon
import com.trailmind.core.weather.ForecastHour
import com.trailmind.core.weather.PointForecast
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.roundToInt

/** Hourly point forecasts from Open-Meteo (free, no key), saved per route so they can be read offline. */
object OpenMeteo {
    const val ATTRIBUTION = "Weather data by Open-Meteo.com (CC BY 4.0)"
    private const val HOURLY = "temperature_2m,apparent_temperature,wind_speed_10m,wind_gusts_10m,wind_direction_10m," +
        "precipitation_probability,precipitation,cloud_cover_low,visibility,freezing_level_height"
    private const val MAX_BYTES = 512 * 1024

    /** Fetches the forecast for [at], [eleM] high (Open-Meteo corrects its temperatures to that height), and saves it for [routeId]. */
    fun fetch(context: Context, routeId: Long, at: LatLon, eleM: Double): PointForecast {
        val json = JSONObject(get(
            "https://api.open-meteo.com/v1/forecast?latitude=${at.lat}&longitude=${at.lon}&elevation=${eleM.roundToInt()}" +
                "&hourly=$HOURLY&timeformat=unixtime&forecast_days=5",
        ))
        val fetchedMs = System.currentTimeMillis()
        val forecast = parse(json, fetchedMs)
        file(context, routeId).apply { parentFile?.mkdirs() }.writeText(JSONObject().put("fetchedMs", fetchedMs).put("data", json).toString())
        return forecast
    }

    fun saved(context: Context, routeId: Long): PointForecast? {
        val f = file(context, routeId)
        if (!f.exists()) return null
        // A damaged file (say, cut short by a full disk) counts as no forecast.
        return runCatching { JSONObject(f.readText()).let { parse(it.getJSONObject("data"), it.getLong("fetchedMs")) } }.getOrNull()
    }

    fun delete(context: Context, routeId: Long) {
        file(context, routeId).delete()
    }

    private fun file(context: Context, routeId: Long) = File(context.filesDir, "forecasts/$routeId.json")

    private fun parse(json: JSONObject, fetchedMs: Long): PointForecast {
        val hourly = json.getJSONObject("hourly")
        val time = hourly.getJSONArray("time")
        fun column(name: String): (Int) -> Double {
            val a = hourly.optJSONArray(name)
            return { i -> if (a == null || a.isNull(i)) Double.NaN else a.optDouble(i) }
        }
        val temp = column("temperature_2m")
        val feels = column("apparent_temperature")
        val wind = column("wind_speed_10m")
        val gust = column("wind_gusts_10m")
        val from = column("wind_direction_10m")
        val chance = column("precipitation_probability")
        val rain = column("precipitation")
        val lowCloud = column("cloud_cover_low")
        val visibility = column("visibility")
        val freezing = column("freezing_level_height")
        return PointForecast(fetchedMs, (0 until time.length()).map { i ->
            ForecastHour(time.getLong(i) * 1000, temp(i), feels(i), wind(i), gust(i), from(i), chance(i), rain(i), lowCloud(i), visibility(i), freezing(i))
        })
    }

    private fun get(url: String): String {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
            val code = conn.responseCode
            if (code != 200) throw IOException("Open-Meteo answered HTTP $code.")
            return conn.inputStream.use { input ->
                val out = ByteArrayOutputStream()
                val buf = ByteArray(16 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > MAX_BYTES) throw IOException("The forecast was unexpectedly large.")
                }
                out.toString("UTF-8")
            }
        } finally {
            conn.disconnect()
        }
    }
}
