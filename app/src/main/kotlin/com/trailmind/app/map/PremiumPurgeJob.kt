package com.trailmind.app.map

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import com.trailmind.app.TrailMindApp

class PremiumPurgeJob : JobService() {
    @Volatile private var stopped = false
    private var worker: Thread? = null

    override fun onStartJob(params: JobParameters): Boolean {
        stopped = false
        worker = Thread({
            try {
                val tiles = (application as TrailMindApp).tiles
                tiles.purgeExpiredPremium()
                if (stopped) return@Thread
                jobFinished(params, false)
                tiles.reschedulePremiumExpiry()
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (_: Exception) {
                if (!stopped) jobFinished(params, true)
            }
        }, "premium-tile-purge").also { it.start() }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        stopped = true
        worker?.interrupt()
        return true
    }

    companion object {
        const val JOB_ID = 27700

        fun schedule(context: Context, expiryMs: Long) {
            val latency = (expiryMs - System.currentTimeMillis()).coerceAtLeast(0L)
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, PremiumPurgeJob::class.java))
                .setMinimumLatency(latency)
                .setOverrideDeadline(latency)
                .setPersisted(true)
                .build()
            (context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).schedule(job)
        }

        fun cancel(context: Context) {
            (context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).cancel(JOB_ID)
        }
    }
}