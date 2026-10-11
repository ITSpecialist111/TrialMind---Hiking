package com.trailmind.core

import com.trailmind.core.strava.StravaActivityKind
import com.trailmind.core.strava.StravaAthlete
import com.trailmind.core.strava.StravaMultipart
import com.trailmind.core.strava.StravaOAuth
import com.trailmind.core.strava.StravaOAuth.Redirect
import com.trailmind.core.strava.StravaPolicy
import com.trailmind.core.strava.StravaTokens
import com.trailmind.core.strava.StravaUploadResult
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class StravaTest {
    private val state = "a1b2c3d4"

    @Test fun authorizeUrlAsksForOnlyWhatItNeedsAndCarriesTheState() {
        val url = StravaOAuth.authorizeUrl("https://www.strava.com/", " 12345 ", state)
        assertTrue(url.startsWith("https://www.strava.com/oauth/mobile/authorize?"))
        assertTrue("client_id=12345&" in url)
        assertTrue("redirect_uri=trailmind%3A%2F%2Flocalhost%2Fstrava" in url)
        assertTrue("response_type=code" in url)
        assertTrue("scope=read%2Cactivity%3Awrite" in url)
        assertTrue(url.endsWith("&state=$state"))
        // Nothing that reads the athlete's activities.
        assertFalse("activity%3Aread" in url)
    }

    @Test fun aGrantedRedirectGivesTheCodeAndScopes() {
        val r = StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state&code=abc123&scope=read,activity:write", state)
        assertTrue(r is Redirect.Granted)
        r as Redirect.Granted
        assertEquals("abc123", r.code)
        assertEquals(setOf("read", "activity:write"), r.scopes)
        assertTrue(r.canUpload)
    }

    @Test fun scopesMayComeUrlEncodedOrSpaceSeparated() {
        val a = StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state&code=c&scope=read%2Cactivity%3Awrite", state) as Redirect.Granted
        assertTrue(a.canUpload)
        val b = StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state&code=c&scope=read%20activity%3Awrite", state) as Redirect.Granted
        assertTrue(b.canUpload)
    }

    @Test fun theUserCanOptOutOfUploading() {
        val r = StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state&code=c&scope=read", state) as Redirect.Granted
        assertFalse(r.canUpload)
    }

    @Test fun aWrongOrMissingStateIsNotAnAnswerToThisSignIn() {
        assertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=other&code=c&scope=read", state) is Redirect.Invalid)
        assertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?code=c&scope=read", state) is Redirect.Invalid)
        assertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state&code=c", null) is Redirect.Invalid)
        assertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state&code=c", "") is Redirect.Invalid)
        // The same length but not the same.
        assertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=a1b2c3d5&code=c", state) is Redirect.Invalid)
    }

    @Test fun aMalformedLinkIsIgnoredNotACrash() {
        // Any web page or app can open trailmind://localhost/strava, so garbage must come back as "not an answer".
        assertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?x=%zz", state) is Redirect.Invalid)
        assertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state&code=%", state) is Redirect.Invalid)
        assertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?%e0%a4%a=1&state=$state", state) is Redirect.Invalid)
    }

    @Test fun refusalsAreReportedInPlainWords() {
        val denied = StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state&error=access_denied", state)
        assertTrue(denied is Redirect.Refused)
        assertTrue((denied as Redirect.Refused).reason.contains("didn't allow"))
        val other = StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state&error=redirect_uri_mismatch", state) as Redirect.Refused
        assertTrue("redirect_uri_mismatch" in other.reason)
        assertTrue(StravaOAuth.parseRedirect("trailmind://localhost/strava?state=$state", state) is Redirect.Invalid)
    }

    @Test fun onlyTrailMindsOwnRedirectIsRecognised() {
        assertTrue(StravaOAuth.isRedirect("trailmind://localhost/strava?code=1"))
        assertTrue(StravaOAuth.isRedirect("TrailMind://LOCALHOST/strava"))
        assertFalse(StravaOAuth.isRedirect("trailmind://group/join?code=1"))
        assertFalse(StravaOAuth.isRedirect("https://localhost/strava"))
        assertFalse(StravaOAuth.isRedirect("trailmind://example.com/strava"))
        assertFalse(StravaOAuth.isRedirect("not a url"))
        assertTrue(StravaOAuth.parseRedirect("https://evil.example/strava?state=$state&code=c", state) is Redirect.Invalid)
    }

    @Test fun tokenCallBodiesAreFormEncoded() {
        assertEquals("client_id=42&client_secret=s%26%3D&code=c+d&grant_type=authorization_code",
            StravaOAuth.tokenRequestBody(" 42 ", " s&= ", "c d"))
        assertEquals("client_id=42&client_secret=sec&grant_type=refresh_token&refresh_token=r%2Ft",
            StravaOAuth.refreshRequestBody("42", "sec", "r/t"))
    }

    @Test fun anAccessTokenIsRenewedBeforeItLapses() {
        val t = StravaTokens("a", "r", expiresAtS = 100_000, scope = "read,activity:write")
        assertFalse(t.needsRefresh(100_000 - 3_600))
        assertTrue(t.needsRefresh(100_000 - 599))
        assertTrue(t.needsRefresh(100_001))
        assertTrue(t.canUpload)
        assertFalse(t.copy(scope = "read").canUpload)
        assertFalse(t.copy(scope = "").canUpload)
    }

    @Test fun theLinkedAthleteIsShownByNameAndHandle() {
        assertEquals("Graham Hosking · @graham", StravaAthlete(1, "graham", "Graham", "Hosking").display)
        assertEquals("@graham", StravaAthlete(1, "graham", "Graham", "Hosking").handle)
        // Many athletes have no username.
        assertEquals("Graham Hosking", StravaAthlete(1, null, "Graham", "Hosking").display)
        assertNull(StravaAthlete(1, " ", "G", null).handle)
        assertEquals("Strava athlete 7", StravaAthlete(7, null, null, null).display)
        assertEquals("@only", StravaAthlete(7, "only", "", "").display)
    }

    @Test fun multipartHasEachFieldTheFileAndTheClosingBoundary() {
        val m = StravaMultipart("XYZ").field("name", "Forest \"loop\"\nhike").field("data_type", "gpx")
            .file("file", "a\"b.gpx", "application/gpx+xml", "<gpx/>".toByteArray())
        val body = String(m.build(), Charsets.UTF_8)
        assertEquals("multipart/form-data; boundary=XYZ", m.contentType)
        assertTrue(body.startsWith("--XYZ\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nForest \"loop\"\nhike\r\n"))
        assertTrue("name=\"data_type\"\r\n\r\ngpx\r\n" in body)
        assertTrue("name=\"file\"; filename=\"a'b.gpx\"\r\nContent-Type: application/gpx+xml\r\n\r\n<gpx/>\r\n" in body)
        assertTrue(body.endsWith("--XYZ--\r\n"))
        assertEquals(3, Regex("--XYZ\r\n").findAll(body).count())
    }

    @Test fun uploadAnswersAreReadFromTheirFields() {
        assertEquals(StravaUploadResult.Ready(99), StravaPolicy.classify("Your activity is ready.", null, 99))
        assertEquals(StravaUploadResult.Processing, StravaPolicy.classify("Your activity is still being processed.", null, null))
        assertEquals(StravaUploadResult.Processing, StravaPolicy.classify(null, null, 0))
        assertTrue(StravaPolicy.classify("There was an error processing your activity.", null, null) is StravaUploadResult.Failed)
        assertTrue(StravaPolicy.classify("The created activity has been deleted.", null, null) is StravaUploadResult.Failed)
        assertEquals(StravaUploadResult.Failed("file is empty"), StravaPolicy.classify("ok", "file is empty", null))
        // Strava says "duplicate" for a file it already has.
        val dup = StravaPolicy.classify("There was an error processing your activity.", "trailmind.gpx duplicate of activity 5", null)
        assertTrue(dup is StravaUploadResult.Duplicate)
    }

    @Test fun onlyRealHikesArePosted() {
        assertTrue(StravaPolicy.worthPosting(3_000.0, 120))
        assertFalse(StravaPolicy.worthPosting(120.0, 120))
        assertFalse(StravaPolicy.worthPosting(3_000.0, 4))
    }

    @Test fun retriesBackOffAndNamesAreSafe() {
        assertEquals(listOf(1, 5, 15, 60, 360, 360), (1..6).map { (StravaPolicy.retryDelayMs(it) / 60_000).toInt() })
        assertEquals("trailmind-7-1790000000000", StravaPolicy.externalId(1_790_000_000_000, 7))
        assertEquals("Hike", StravaPolicy.activityName("   "))
        assertEquals(255, StravaPolicy.activityName("x".repeat(400)).length)
        assertEquals("Forest · Oct 11", StravaPolicy.activityName("  Forest · Oct 11 "))
        assertEquals("https://www.strava.com/activities/123", StravaPolicy.activityUrl(123))
        assertEquals(StravaActivityKind.HIKE, StravaActivityKind.of(null))
        assertEquals(StravaActivityKind.WALK, StravaActivityKind.of("walk"))
        assertEquals("hike", StravaActivityKind.HIKE.code)
    }
}
