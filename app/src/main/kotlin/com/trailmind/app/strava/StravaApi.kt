package com.trailmind.app.strava

import com.trailmind.app.map.TileProvider
import com.trailmind.core.strava.StravaActivityKind
import com.trailmind.core.strava.StravaMultipart
import com.trailmind.core.strava.StravaOAuth
import com.trailmind.core.strava.StravaPolicy
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

/** Strava's web API over plain HTTPS. Every call returns what happened rather than throwing. */
object StravaApi {
    /** Strava's address. Only tests change this, to point at a server of their own. */
    @Volatile var baseUrl = "https://www.strava.com"

    sealed interface Reply {
        data class Ok(val body: JSONObject) : Reply
        /** Strava answered, but not with success. [message] is its own explanation when it gave one. */
        data class Http(val code: Int, val message: String, val retryAfterS: Long?) : Reply
        data class Offline(val message: String) : Reply
    }

    fun exchangeCode(clientId: String, clientSecret: String, code: String): Reply =
        postForm(StravaOAuth.TOKEN_PATH, StravaOAuth.tokenRequestBody(clientId, clientSecret, code))

    fun refresh(clientId: String, clientSecret: String, refreshToken: String): Reply =
        postForm(StravaOAuth.TOKEN_PATH, StravaOAuth.refreshRequestBody(clientId, clientSecret, refreshToken))

    /** Tells Strava the user has unlinked TrailMind, so it disappears from their connected apps. Best effort. */
    fun deauthorize(accessToken: String): Reply = postForm(StravaOAuth.DEAUTHORIZE_PATH, "", bearer = accessToken)

    fun upload(accessToken: String, gpx: ByteArray, fileName: String, name: String, kind: StravaActivityKind, externalId: String): Reply {
        val form = StravaMultipart()
            .field("data_type", "gpx")
            .field("name", name)
            .field("description", StravaPolicy.DESCRIPTION)
            .field("activity_type", kind.code)
            .field("external_id", externalId)
            .file("file", fileName, "application/gpx+xml", gpx)
        return send("POST", "/api/v3/uploads", form.build(), form.contentType, accessToken)
    }

    fun uploadStatus(accessToken: String, uploadId: Long): Reply = send("GET", "/api/v3/uploads/$uploadId", null, null, accessToken)

    private fun postForm(path: String, body: String, bearer: String? = null): Reply =
        send("POST", path, body.toByteArray(Charsets.UTF_8), "application/x-www-form-urlencoded", bearer)

    private fun send(method: String, path: String, body: ByteArray?, contentType: String?, bearer: String?): Reply {
        return try {
            val conn = URL(baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection
            try {
                conn.requestMethod = method
                conn.connectTimeout = 15_000
                conn.readTimeout = 30_000
                conn.instanceFollowRedirects = false
                conn.setRequestProperty("User-Agent", TileProvider.USER_AGENT)
                conn.setRequestProperty("Accept", "application/json")
                bearer?.let { conn.setRequestProperty("Authorization", "Bearer $it") }
                if (body != null) {
                    conn.doOutput = true
                    contentType?.let { conn.setRequestProperty("Content-Type", it) }
                    conn.setFixedLengthStreamingMode(body.size)
                    conn.outputStream.use { it.write(body) }
                }
                val code = conn.responseCode
                val text = (if (code in 200..299) conn.inputStream else conn.errorStream)?.use { it.readBytes().toString(Charsets.UTF_8) }.orEmpty()
                if (code in 200..299) Reply.Ok(runCatching { JSONObject(text) }.getOrDefault(JSONObject()))
                else Reply.Http(code, explain(text), conn.getHeaderField("Retry-After")?.toLongOrNull())
            } finally {
                conn.disconnect()
            }
        } catch (e: IOException) {
            Reply.Offline(e.message ?: "no connection")
        }
    }

    /** Strava's own words for a failure: `{"message": "...", "errors": [{"field": "...", "code": "..."}]}`. */
    private fun explain(text: String): String {
        val json = runCatching { JSONObject(text) }.getOrNull() ?: return text.take(200)
        val message = json.optString("message")
        val errors = json.optJSONArray("errors")
        val detail = (0 until (errors?.length() ?: 0)).mapNotNull { i ->
            errors?.optJSONObject(i)?.let { e -> listOf(e.optString("resource"), e.optString("field"), e.optString("code")).filter { it.isNotBlank() }.joinToString(" ") }
        }.filter { it.isNotBlank() }
        return (listOf(message) + detail).filter { it.isNotBlank() }.joinToString(": ").ifBlank { text.take(200) }
    }
}
