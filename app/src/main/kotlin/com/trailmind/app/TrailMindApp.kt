package com.trailmind.app

import android.app.Application
import com.trailmind.app.data.Db
import com.trailmind.app.data.Prefs
import com.trailmind.app.location.LocationHub
import com.trailmind.app.map.TileProvider
import com.trailmind.app.nav.NavigationController
import com.trailmind.app.ui.Notifications

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

    override fun onCreate() {
        super.onCreate()
        instance = this
        prefs = Prefs(this)
        db = Db(this)
        tiles = TileProvider(this)
        nav = NavigationController(this)
        location = LocationHub(nav)
        Notifications.createChannels(this)
        Async.io { tiles.trimDiskCache() }
    }

    companion object {
        lateinit var instance: TrailMindApp
            private set
    }
}
