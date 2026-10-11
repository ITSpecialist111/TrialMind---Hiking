package com.trailmind.app.strava

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import com.trailmind.app.TrailMindApp

/**
 * Posts the hikes waiting for Strava once there is a network, and keeps coming back until none are left. The system
 * runs it even if TrailMind is closed, so a hike recorded without signal reaches Strava when the phone finds some.
 */
class StravaUploadJob : JobService() {
    @Volatile private var stopped = false
    private var worker: Thread? = null

    override fun onStartJob(params: JobParameters): Boolean {
        stopped = false
        worker = Thread({
            try {
                val next = (application as TrailMindApp).strava.runQueue()
                if (next != null && !stopped) schedule(applicationContext, next)
                jobFinished(params, false)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (_: Exception) {
                if (!stopped) jobFinished(params, true)
            }
        }, "strava-upload").also { it.start() }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        stopped = true
        return true
    }

    companion object {
        const val JOB_ID = 27701

        /** Runs after [delayMs], when the phone has a network. Replaces any run already planned. */
        fun schedule(context: Context, delayMs: Long) {
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, StravaUploadJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setMinimumLatency(delayMs.coerceAtLeast(0L))
                .setBackoffCriteria(60_000L, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
                .build()
            (context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).schedule(job)
        }
    }
}
