package com.trailmind.core.frontier.group

enum class RadioMode { ON_SCREEN, RECORDING, SAVER, BOOST }
enum class ScanDuty { LOW_POWER, BALANCED, LOW_LATENCY }

data class RadioPlan(
    val mode: RadioMode,
    /** Advertising interval in Bluetooth units of 0.625 ms. */
    val advertiseInterval: Int,
    val scan: ScanDuty,
    /** Restart the scan this often, so Android keeps its duty cycle (it lowers it after 10 minutes); null to leave it. */
    val scanRefreshMs: Long?,
    val relay: Boolean,
    val relayHelpOnly: Boolean,
)

/**
 * How hard the trip-group radio works. Advertising costs little and scanning costs a lot, so every profile advertises
 * often and scans only as much as it needs: flat out while TrailMind is on screen or someone needs help, and at the
 * rate Android allows with the screen off while a hike records.
 */
object RadioProfile {
    const val SAVER_BATTERY_PERCENT = 20
    const val BOOST_MS = 30 * 60_000L

    /** Null while TrailMind is neither on screen nor recording: the radio is off. */
    fun plan(uiVisible: Boolean, recording: Boolean, boost: Boolean, batteryPercent: Int?, powerSave: Boolean, relay: Boolean): RadioPlan? {
        if (!uiVisible && !recording) return null
        val saver = powerSave || (batteryPercent != null && batteryPercent <= SAVER_BATTERY_PERCENT)
        return when {
            boost -> RadioPlan(RadioMode.BOOST, 400, ScanDuty.LOW_LATENCY, 9 * 60_000L, relay, relayHelpOnly = false)
            saver -> RadioPlan(RadioMode.SAVER, 1600, ScanDuty.LOW_POWER, null, relay, relayHelpOnly = true)
            uiVisible -> RadioPlan(RadioMode.ON_SCREEN, 800, ScanDuty.LOW_LATENCY, null, relay, relayHelpOnly = false)
            else -> RadioPlan(RadioMode.RECORDING, 800, ScanDuty.BALANCED, null, relay, relayHelpOnly = false)
        }
    }
}
