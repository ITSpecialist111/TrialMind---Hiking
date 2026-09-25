package com.trailmind.app

import android.app.Application
import com.trailmind.app.data.Db
import com.trailmind.app.data.Prefs
import com.trailmind.app.location.LocationHub
import com.trailmind.app.map.TileProvider
import com.trailmind.app.nav.NavigationController
import com.trailmind.app.sensor.Barometer
import com.trailmind.app.ui.Notifications
import com.trailmind.app.watch.WatchLink

class TrailMindApp : Application() {
    lateinit var db: Db
        private set
    lateinit var prefs: Prefs
        private set
    lateinit var tiles: TileProvider
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
        instance = this
        prefs = Prefs(this)
        db = Db(this)
        baro = Barometer(this)
        tiles = TileProvider(this)
        nav = NavigationController(this)
        location = LocationHub(nav)
        watch = WatchLink(this)
        Notifications.createChannels(this)
        Async.io { tiles.trimDiskCache() }
    }

    companion object {
        lateinit var instance: TrailMindApp
            private set
    }
}
