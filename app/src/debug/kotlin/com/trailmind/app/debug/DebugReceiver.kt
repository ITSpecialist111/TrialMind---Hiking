package com.trailmind.app.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.trailmind.app.TrailMindApp
import com.trailmind.app.map.TileSources
import com.trailmind.core.frontier.EmergencyStatus
import com.trailmind.core.frontier.group.GroupAdvert
import com.trailmind.core.frontier.group.PositionFrame
import com.trailmind.core.frontier.group.ProfileFrame
import java.security.SecureRandom

/**
 * Debug builds only. Emulators have no Bluetooth radio that can advertise, so this plays the part of other trip-group
 * members: it builds a real sealed advert under the group's keys and feeds it to the same code the radio feeds.
 *
 *     adb shell am broadcast -n com.trailmind.app/.debug.DebugReceiver -a com.trailmind.app.debug.GROUP_CREATE --es name "Test trip"
 *     adb shell am broadcast -n com.trailmind.app/.debug.DebugReceiver -a com.trailmind.app.debug.GROUP_PEER --ei id 20481 --es name Alex --ei flags 5
 *     adb shell am broadcast -n com.trailmind.app/.debug.DebugReceiver -a com.trailmind.app.debug.GROUP_STATE
 *
 * `flags` is the member's frame flags: 1 recording, 2 paused, 4 group hike. Results go to logcat under the tag TrailMindDebug.
 */
class DebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as TrailMindApp
        when (intent.action) {
            ACTION_GROUP_CREATE -> app.group.create(intent.getStringExtra("name") ?: "Test trip", "Tester") {
                Log.i(TAG, "created group ${it.name} member=${it.memberId}")
            }
            ACTION_GROUP_PEER -> peer(app, intent)
            ACTION_OLD_MAPS_URL -> {
                TileSources.historicBaseUrl = intent.getStringExtra("url") ?: "https://api.maptiler.com/tiles"
                app.tiles.clearErrors()
                Log.i(TAG, "old maps now come from ${TileSources.historicBaseUrl}")
            }
            ACTION_GROUP_STATE -> {
                val own = app.group.ownFrame
                Log.i(TAG, "group=${app.group.group?.name} ownFlags=${own?.flags} members=${app.group.members.size} " +
                    "memberFlags=${app.group.members.map { it.position?.flags }} recording=${com.trailmind.app.location.TrackingService.running} " +
                    "groupHikes=${app.prefs.groupHikes} ask=${app.prefs.groupHikesAsk}")
            }
        }
    }

    private fun peer(app: TrailMindApp, intent: Intent) {
        val group = app.group.group ?: return run { Log.w(TAG, "no trip group: send GROUP_CREATE first") }
        val id = intent.getIntExtra("id", 0x5001)
        val flags = intent.getIntExtra("flags", 0)
        val nowS = app.group.nowS()
        val here = app.location.latest
        val lat = intent.getDoubleExtra("lat", here?.lat ?: 51.8)
        val lon = intent.getDoubleExtra("lon", here?.lon ?: -2.5)
        val frames = listOf(
            PositionFrame.of(id, nowS, nowS, lat, lon, 120.0, 5f, 90, EmergencyStatus.OK, flags = flags),
            ProfileFrame(id, 3, intent.getStringExtra("name") ?: "Alex"),
        )
        app.group.onAdvert(GroupAdvert.build(group.keys, nowS, frames, SecureRandom()), -60, false, null)
        Log.i(TAG, "peer $id flags=$flags sent")
    }

    companion object {
        const val TAG = "TrailMindDebug"
        const val ACTION_GROUP_CREATE = "com.trailmind.app.debug.GROUP_CREATE"
        const val ACTION_GROUP_PEER = "com.trailmind.app.debug.GROUP_PEER"
        const val ACTION_GROUP_STATE = "com.trailmind.app.debug.GROUP_STATE"
        const val ACTION_OLD_MAPS_URL = "com.trailmind.app.debug.OLD_MAPS_URL"
    }
}
