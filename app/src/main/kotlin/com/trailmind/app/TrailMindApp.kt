package com.trailmind.app

import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
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
import com.trailmind.app.sensor.FallMonitor
import com.trailmind.app.frontier.FrontierCoordinator
import com.trailmind.app.frontier.group.GroupSharing
import com.trailmind.app.ui.Notifications
import com.trailmind.app.watch.WatchLink

class TrailMindApp : Application() {
    val planner by lazy { RoutePlanner(db, tiles::networkAllowed) }
    /** The installed version, from trailmind.versionName in gradle.properties. */
    val versionName: String by lazy {
        runCatching {
            if (Build.VERSION.SDK_INT >= 33) packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0)).versionName
            else @Suppress("DEPRECATION") packageManager.getPackageInfo(packageName, 0).versionName
        }.getOrNull() ?: "unknown"
    }
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
    lateinit var frontier: FrontierCoordinator
        private set
    lateinit var fallMonitor: FallMonitor
        private set
    lateinit var group: GroupSharing
        private set

    override fun onCreate() {
        super.onCreate()
        if (!getSystemService(UserManager::class.java).isUserUnlocked) return
        // The ":boot" process only re-arms the check-in alarm; it must not start a second copy of the app.
        if (Build.VERSION.SDK_INT >= 28 && Application.getProcessName() != packageName) return
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
        frontier = FrontierCoordinator(this)
        fallMonitor = FallMonitor(this, frontier::recordFall)
        watch = WatchLink(this)
        frontier.start()
        Notifications.createChannels(this)
        group = GroupSharing(this)
        group.start()
        CheckIn.arm(this)
        Async.io { tiles.trimDiskCache(); terrain.trimDiskCache(); tiles.reschedulePremiumExpiry(); PremiumRenewal.reschedule(this) }
    }

    companion object {
        lateinit var instance: TrailMindApp
            private set
    }
}
