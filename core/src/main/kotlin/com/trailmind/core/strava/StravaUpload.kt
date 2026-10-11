package com.trailmind.core.strava

/** Where one hike's post to Strava has got to. Kept per hike, so a retry never posts it twice. */
enum class StravaPostState {
    /** Waiting for signal, or for the next try. */
    QUEUED,
    /** Strava has the file and is working on it. */
    PROCESSING,
    /** On Strava. */
    POSTED,
    /** Gave up for now; the hike page offers Try again. */
    FAILED,
    /** Not worth posting (too short), or the user didn't want it. */
    SKIPPED,
}

/** What kind of Strava activity a hike is posted as. The code is the `activity_type` Strava's upload takes. */
enum class StravaActivityKind(val code: String, val label: String) {
    HIKE("hike", "Hike"),
    WALK("walk", "Walk"),
    ;

    companion object {
        fun of(code: String?) = entries.firstOrNull { it.code == code } ?: HIKE
    }
}

/** How Strava answered an upload or a later check on it. */
sealed interface StravaUploadResult {
    data class Ready(val activityId: Long) : StravaUploadResult
    data object Processing : StravaUploadResult
    /** Strava already has this activity: fine, there's nothing more to post. */
    data class Duplicate(val message: String) : StravaUploadResult
    data class Failed(val message: String) : StravaUploadResult
}

/** The rules around posting hikes that are worth testing without a phone or Strava. */
object StravaPolicy {
    /** A recording shorter than this is a stray tap on Start, not a hike. */
    const val MIN_DISTANCE_M = 250.0
    const val MIN_POINTS = 10
    const val DESCRIPTION = "Recorded with TrailMind"
    /** Strava's own page for uploading a GPX by hand: the way in that needs neither a subscription nor an API application. */
    const val UPLOAD_PAGE_URL = "https://www.strava.com/upload/select"
    const val MAX_ATTEMPTS = 8
    /** Strava's limit for a new application is 100 requests per 15 minutes. */
    const val RATE_LIMIT_WAIT_MS = 15 * 60_000L
    const val POLL_MS = 2_000L
    const val POLL_TRIES = 15

    fun worthPosting(distanceM: Double, pointCount: Int): Boolean = distanceM >= MIN_DISTANCE_M && pointCount >= MIN_POINTS

    /** Stable per hike, so Strava can tell a retry from a second hike. */
    fun externalId(startMs: Long, hikeId: Long) = "trailmind-$hikeId-$startMs"

    /** Strava names are limited to 255 characters. */
    fun activityName(hikeName: String, fallback: String = "Hike"): String = hikeName.trim().take(255).ifBlank { fallback }

    /** 1 minute, 5, 15, 1 hour, then 6 hours, for the attempt that just failed (1 is the first). */
    fun retryDelayMs(attempt: Int): Long = when {
        attempt <= 1 -> 60_000L
        attempt == 2 -> 5 * 60_000L
        attempt == 3 -> 15 * 60_000L
        attempt == 4 -> 3_600_000L
        else -> 6 * 3_600_000L
    }

    /**
     * Reads Strava's upload object: [status] and [error] are its text fields, [activityId] its `activity_id` (null, or
     * 0, until processing ends).
     */
    fun classify(status: String?, error: String?, activityId: Long?): StravaUploadResult {
        val err = error?.trim().orEmpty()
        val st = status?.trim().orEmpty()
        if (err.isNotEmpty()) {
            return if (err.contains("duplicate", ignoreCase = true)) StravaUploadResult.Duplicate(err) else StravaUploadResult.Failed(err)
        }
        if (activityId != null && activityId > 0) return StravaUploadResult.Ready(activityId)
        if (st.contains("error", ignoreCase = true)) return StravaUploadResult.Failed(st)
        if (st.contains("deleted", ignoreCase = true)) return StravaUploadResult.Failed("The activity was deleted on Strava.")
        return StravaUploadResult.Processing
    }

    /** The link to an activity on Strava. */
    fun activityUrl(activityId: Long) = "https://www.strava.com/activities/$activityId"
}
