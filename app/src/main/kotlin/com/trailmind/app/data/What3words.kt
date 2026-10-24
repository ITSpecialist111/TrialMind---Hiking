package com.trailmind.app.data

import android.os.SystemClock
import com.trailmind.app.location.Fix
import com.trailmind.app.map.TileProvider
import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.ThreeWordAddress
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** Explicit online lookups only. No automatic requests from tracking or emergency flows. */
object What3words {
    data class Address(val words: String, val position: LatLon, val southwest: LatLon, val northeast: LatLon, val nearby: String) {
        fun contains(point: LatLon) = point.lat >= southwest.lat && point.lat < northeast.lat &&
            point.lon >= southwest.lon && point.lon < northeast.lon
    }
    private data class Cached(val address: Address, val fixAtMs: Long)
    @Volatile private var cached: Cached? = null

    fun search(input: String, key: String, request: OsNames.Request): Address {
        val words = ThreeWordAddress.normalize(input) ?: throw IOException("what3words: enter three words separated by dots, such as ///filled.count.soap.")
        val result = get("convert-to-coordinates", "words=$words", key, request)
        if (result.words != words) throw IOException("what3words: response did not match the requested address.")
        return result
    }

    fun locate(fix: Fix, key: String, request: OsNames.Request): Address {
        if (SystemClock.elapsedRealtime() - fix.location.elapsedRealtimeNanos / 1_000_000 !in 0..60_000) {
            throw IOException("what3words: wait for a fresh GPS fix before looking up your position.")
        }
        val result = get("convert-to-3wa", "coordinates=${fix.lat},${fix.lon}", key, request)
        if (!result.contains(LatLon(fix.lat, fix.lon))) throw IOException("what3words: response did not match the requested location.")
        cached = Cached(result, fix.location.elapsedRealtimeNanos / 1_000_000)
        return result
    }

    fun current(fix: Fix?): Address? {
        val saved = cached ?: return null
        fix ?: return null
        val now = SystemClock.elapsedRealtime()
        return saved.address.takeIf {
            ThreeWordAddress.canShare(saved.fixAtMs, fix.location.elapsedRealtimeNanos / 1_000_000, now, it.contains(LatLon(fix.lat, fix.lon)))
        }
    }

    private fun get(endpoint: String, parameter: String, key: String, request: OsNames.Request): Address {
        if (key.isBlank()) throw IOException("what3words: add your API key in Settings first. Your plan must allow both conversions.")
        val (name, value) = parameter.split("=", limit = 2)
        val language = if (endpoint == "convert-to-3wa") "&language=en" else ""
        val connection = URL("https://api.what3words.com/v3/$endpoint?$name=${URLEncoder.encode(value, "UTF-8")}$language").openConnection() as HttpURLConnection
        try {
            if (!request.attach(connection)) throw IOException("what3words: lookup cancelled.")
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 8_000
            connection.readTimeout = 10_000
            connection.setRequestProperty("X-Api-Key", key)
            connection.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
            val code = connection.responseCode
            if (code != 200) throw IOException(when (code) {
                400, 404 -> "what3words: address not found. Check all three words; spelling changes can point to a different country."
                401, 402, 403 -> "what3words: check your API key, plan and conversion permissions in Settings."
                429 -> "what3words: request limit reached. Try again later."
                else -> "what3words: service returned HTTP $code. Use coordinates or a grid reference instead."
            })
            val body = connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (output.size() <= 32_768) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            if (body.size > 32_768) throw IOException("what3words: response was too large.")
            return parseResponse(body.toString(Charsets.UTF_8))
        } catch (error: IOException) {
            if (error.message?.startsWith("what3words:") == true) throw error
            throw IOException("what3words: could not connect. Coordinates and grid references still work offline.")
        } finally {
            request.clear(connection)
            connection.disconnect()
        }
    }

    internal fun parseResponse(body: String): Address {
        try {
            val json = JSONObject(body)
            if (json.has("error")) throw IOException("what3words: conversion failed. Check the address and your API plan.")
            fun position(obj: JSONObject): LatLon {
                val lat = obj.getDouble("lat")
                val lon = obj.getDouble("lng")
                if (!lat.isFinite() || !lon.isFinite() || lat !in -90.0..90.0 || lon !in -180.0..180.0)
                    throw IOException("what3words: invalid coordinates in response.")
                return LatLon(lat, lon)
            }
            val words = ThreeWordAddress.normalize(json.getString("words"))
                ?: throw IOException("what3words: invalid address in response.")
            val square = json.getJSONObject("square")
            val result = Address(words, position(json.getJSONObject("coordinates")), position(square.getJSONObject("southwest")),
                position(square.getJSONObject("northeast")), json.optString("nearestPlace"))
            if (!result.contains(result.position)) throw IOException("what3words: invalid square in response.")
            return result
        } catch (error: JSONException) {
            throw IOException("what3words: unreadable service response.")
        }
    }
}
