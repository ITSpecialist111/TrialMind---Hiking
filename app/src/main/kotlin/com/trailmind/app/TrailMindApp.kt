package com.trailmind.app

import android.app.Application
import android.os.UserManager
import com.trailmind.app.data.Db
import com.trailmind.app.data.PackStatus
import com.trailmind.app.data.Prefs
import com.trailmind.app.data.RoutePlanner
import com.trailmind.app.location.LocationHub
import com.trailmind.app.location.CheckIn
import com.trailmind.app.map.PremiumRenewal
import com.trailmind.app.map.TileProvider
import com.trailmind.app.map.TerrainProvider
import com.trailmind.app.nav.NavigationController
import com.trailmind.app.sensor.Barometer
import com.trailmind.app.ui.Notifications
import com.trailmind.app.watch.WatchLink

class TrailMindApp : Application() {
    val planner by lazy { RoutePlanner(db, tiles::networkAllowed) }
    lateinit var db: Db
        private set
    lateinit var prefs: Prefs
        private set
    lateinit var tiles: TileProvider
        private set
    lateinit var terrain: TerrainProvider
        private set
    lateinit var nav: NavigationController
        private set
    lateinit var location: LocationHub
        private set
    lateinit var watch: WatchLink
        private set
    lateinit var baro: Barometer
        private set

    override fun onCreate() {
        super.onCreate()
        if (!getSystemService(UserManager::class.java).isUserUnlocked) return
        instance = this
        prefs = Prefs(this)
        db = Db(this)
        db.packs().filter { it.status == PackStatus.DOWNLOADING }.forEach {
            db.updatePackProgress(it.id, it.tileDone, it.tileFailed, it.bytes, PackStatus.PAUSED,
                "Download interrupted. Tap Resume to continue.")
        }
        baro = Barometer(this)
        tiles = TileProvider(this)
        terrain = TerrainProvider(this)
        nav = NavigationController(this)
        location = LocationHub(nav)
        watch = WatchLink(this)
        Notifications.createChannels(this)
        CheckIn.arm(this)
        Async.io { tiles.trimDiskCache(); terrain.trimDiskCache(); tiles.reschedulePremiumExpiry(); PremiumRenewal.reschedule(this) }
    }

    companion object {
        lateinit var instance: TrailMindApp
            private set
    }
}
