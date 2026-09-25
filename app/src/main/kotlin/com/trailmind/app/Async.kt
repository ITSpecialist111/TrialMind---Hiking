package com.trailmind.app

import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Tiny async helper: run work on a background pool, deliver the result on the main thread. */
object Async {
    private val pool: ExecutorService = Executors.newFixedThreadPool(3) { r ->
        Thread(r, "trailmind-io").apply { isDaemon = true }
    }
    val main = Handler(Looper.getMainLooper())

    fun io(work: () -> Unit) {
        pool.execute {
            try {
                work()
            } catch (t: Throwable) {
                Log.e("TrailMind", "background task failed", t)
            }
        }
    }

    fun <T> run(work: () -> T, done: (Result<T>) -> Unit) {
        pool.execute {
            val r = runCatching(work)
            r.exceptionOrNull()?.let { Log.w("TrailMind", "task failed", it) }
            main.post { done(r) }
        }
    }

    fun ui(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }
}
