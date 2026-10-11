package com.trailmind.core.strava

import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * The pieces of Strava's OAuth 2 sign-in that don't need a network or Android: building the authorize link, reading
 * what Strava sends back to the app, and the form bodies for the token calls.
 *
 * Strava has no PKCE, so swapping the code for tokens needs a client secret. TrailMind is a personal app: each user
 * registers their own free Strava API application and gives TrailMind its Client ID and secret, which stay on the
 * phone. Nothing is bundled.
 */
object StravaOAuth {
    const val AUTHORIZE_PATH = "/oauth/mobile/authorize"
    const val TOKEN_PATH = "/oauth/token"
    const val DEAUTHORIZE_PATH = "/oauth/deauthorize"

    /**
     * Where Strava sends the user back to. Strava only checks the host against the application's Authorization
     * Callback Domain, and always accepts `localhost`, so the user enters `localhost` there.
     */
    const val REDIRECT_URI = "trailmind://localhost/strava"
    const val CALLBACK_DOMAIN = "localhost"

    /** `read` to know who signed in, `activity:write` to post hikes. Nothing that reads their activities. */
    const val SCOPE = "read,activity:write"
    const val UPLOAD_SCOPE = "activity:write"

    sealed interface Redirect {
        data class Granted(val code: String, val scopes: Set<String>) : Redirect {
            val canUpload: Boolean get() = UPLOAD_SCOPE in scopes
        }
        /** The user said no, or Strava refused (for example a wrong Client ID). */
        data class Refused(val reason: String) : Redirect
        /** Not an answer to the sign-in this phone started. */
        data class Invalid(val reason: String) : Redirect
    }

    /** The page the user signs in and approves on. Strava's own app opens for it when it's installed. */
    fun authorizeUrl(base: String, clientId: String, state: String): String =
        base.trimEnd('/') + AUTHORIZE_PATH + "?" + form(
            "client_id" to clientId.trim(),
            "redirect_uri" to REDIRECT_URI,
            "response_type" to "code",
            "approval_prompt" to "auto",
            "scope" to SCOPE,
            "state" to state,
        )

    /** Whether [url] is Strava sending the user back, whatever it says. */
    fun isRedirect(url: String): Boolean = runCatching {
        val u = URI(url)
        u.scheme.equals("trailmind", true) && u.host.equals(CALLBACK_DOMAIN, true) && u.path.orEmpty().startsWith("/strava")
    }.getOrDefault(false)

    /** What Strava's redirect says. [expectedState] is the random value this phone sent; anything else is ignored. */
    fun parseRedirect(url: String, expectedState: String?): Redirect {
        if (!isRedirect(url)) return Redirect.Invalid("Not a Strava sign-in link.")
        if (expectedState.isNullOrEmpty()) return Redirect.Invalid("No Strava sign-in is waiting. Start again with Connect with Strava.")
        // Any app or web page can send this link, so a malformed one is just not an answer.
        val q = runCatching { query(url) }.getOrNull() ?: return Redirect.Invalid("This isn't a sign-in answer from Strava.")
        // Compared in full and without leaking where they differ, as the value is a one-time secret.
        if (!constantTimeEquals(q["state"].orEmpty(), expectedState)) return Redirect.Invalid("This sign-in isn't the one TrailMind started. Try Connect with Strava again.")
        q["error"]?.takeIf { it.isNotBlank() }?.let { return Redirect.Refused(if (it == "access_denied") "You didn't allow TrailMind on Strava." else "Strava said: $it.") }
        val code = q["code"].orEmpty()
        if (code.isBlank()) return Redirect.Invalid("Strava didn't send a sign-in code.")
        val scopes = q["scope"].orEmpty().split(',', ' ').map { it.trim() }.filter { it.isNotEmpty() }.toSet()
        return Redirect.Granted(code, scopes)
    }

    fun tokenRequestBody(clientId: String, clientSecret: String, code: String): String = form(
        "client_id" to clientId.trim(), "client_secret" to clientSecret.trim(), "code" to code, "grant_type" to "authorization_code",
    )

    fun refreshRequestBody(clientId: String, clientSecret: String, refreshToken: String): String = form(
        "client_id" to clientId.trim(), "client_secret" to clientSecret.trim(), "grant_type" to "refresh_token", "refresh_token" to refreshToken,
    )

    fun form(vararg pairs: Pair<String, String>): String = pairs.joinToString("&") { (k, v) -> enc(k) + "=" + enc(v) }

    private fun enc(s: String) = URLEncoder.encode(s, Charsets.UTF_8)

    private fun query(url: String): Map<String, String> {
        val raw = url.substringAfter('?', "").substringBefore('#')
        if (raw.isEmpty()) return emptyMap()
        return raw.split('&').filter { it.isNotEmpty() }.associate { part ->
            val k = part.substringBefore('=')
            val v = part.substringAfter('=', "")
            URLDecoder.decode(k, Charsets.UTF_8) to URLDecoder.decode(v, Charsets.UTF_8)
        }
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        var diff = a.length xor b.length
        for (i in 0 until minOf(a.length, b.length)) diff = diff or (a[i].code xor b[i].code)
        return diff == 0
    }
}

/** The short-lived access token and the refresh token that renews it, as Strava hands them out. */
data class StravaTokens(
    val accessToken: String,
    val refreshToken: String,
    /** Seconds since 1970. Access tokens last six hours. */
    val expiresAtS: Long,
    val scope: String = "",
) {
    /** True when the access token is about to lapse or has: Strava returns the same one while more than an hour is left. */
    fun needsRefresh(nowS: Long, marginS: Long = 600): Boolean = expiresAtS - nowS <= marginS

    val canUpload: Boolean get() = scope.split(',', ' ').any { it == StravaOAuth.UPLOAD_SCOPE }
}

/** Who signed in, for showing "linked as". */
data class StravaAthlete(val id: Long, val username: String?, val firstName: String?, val lastName: String?) {
    /** "@username" when the athlete has one (many don't). */
    val handle: String? get() = username?.takeIf { it.isNotBlank() }?.let { "@$it" }

    val fullName: String get() = listOfNotNull(firstName?.takeIf { it.isNotBlank() }, lastName?.takeIf { it.isNotBlank() }).joinToString(" ")

    /** What to show: the name, then the handle, or whichever Strava gave. */
    val display: String get() = listOfNotNull(fullName.takeIf { it.isNotEmpty() }, handle).joinToString(" · ").ifEmpty { "Strava athlete $id" }
}

/** Builds a multipart/form-data body, which is how Strava takes an uploaded file. */
class StravaMultipart(val boundary: String = "TrailMind" + java.util.UUID.randomUUID().toString().replace("-", "")) {
    private val out = ByteArrayOutputStream()

    val contentType: String get() = "multipart/form-data; boundary=$boundary"

    fun field(name: String, value: String): StravaMultipart {
        out.write("--$boundary\r\nContent-Disposition: form-data; name=\"${quote(name)}\"\r\n\r\n".toByteArray())
        out.write(value.toByteArray(Charsets.UTF_8))
        out.write("\r\n".toByteArray())
        return this
    }

    fun file(name: String, fileName: String, mime: String, bytes: ByteArray): StravaMultipart {
        out.write("--$boundary\r\nContent-Disposition: form-data; name=\"${quote(name)}\"; filename=\"${quote(fileName)}\"\r\nContent-Type: $mime\r\n\r\n".toByteArray())
        out.write(bytes)
        out.write("\r\n".toByteArray())
        return this
    }

    fun build(): ByteArray {
        val end = ByteArrayOutputStream()
        end.write(out.toByteArray())
        end.write("--$boundary--\r\n".toByteArray())
        return end.toByteArray()
    }

    private fun quote(s: String) = s.replace("\"", "'").replace("\r", " ").replace("\n", " ")
}
