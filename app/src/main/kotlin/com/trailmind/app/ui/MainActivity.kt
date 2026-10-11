package com.trailmind.app.ui

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Outline
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowInsets
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.TrailMindApp
import com.trailmind.app.data.PackKind
import com.trailmind.app.data.PackStatus
import com.trailmind.app.frontier.group.GroupRadio
import com.trailmind.app.frontier.group.UwbRadio
import com.trailmind.app.location.CheckIn
import com.trailmind.app.location.ForegroundLocation
import com.trailmind.app.location.TrackingService
import com.trailmind.app.location.TrackingState
import com.trailmind.app.map.MbTiles
import com.trailmind.app.map.TileProvider
import com.trailmind.app.sensor.Compass
import com.trailmind.app.share.ExportProvider
import com.trailmind.core.gpx.GpxParser
import com.trailmind.core.strava.StravaOAuth

/**
 * Single activity. Layout adapts to window width rather than device model, so it works on the
 * Galaxy Z Fold cover screen (narrow: map + bottom navigation, pages full-screen) and the inner
 * screen / tablets / split-screen (wide: navigation rail + map + side pane). Folding or unfolding
 * rebuilds the layout in place without restarting the activity, so recording and page state survive.
 */
class MainActivity : Activity() {
    enum class Tab(val label: String, val icon: Int) {
        MAP("Map", R.drawable.ic_map),
        ROUTES("Routes", R.drawable.ic_route),
        HIKES("Hikes", R.drawable.ic_walk),
        COMPASS("Compass", R.drawable.ic_compass),
        OFFLINE("Offline", R.drawable.ic_download),
        ASSIST("Beacon", R.drawable.ic_sparkle),
        SAFETY("Safety", R.drawable.ic_sos),
        SETTINGS("Settings", R.drawable.ic_tune),
        MORE("More", R.drawable.ic_menu),
    }

    val app get() = TrailMindApp.instance
    lateinit var ui: Ui; private set
    lateinit var map: MapScreen; private set
    lateinit var compass: Compass; private set
    private lateinit var fgLocation: ForegroundLocation

    var wide = false; private set
    var tab = Tab.MAP; private set

    /** Wide layout only: the map fills the window and the rail and side pane are hidden. */
    val mapFullScreen get() = wide && app.prefs.mapFullScreen
    private val stack = ArrayList<Page>()
    private val insets = Rect()
    private var contentFrame: FrameLayout? = null
    private var navBar: LinearLayout? = null
    private var railFrame: View? = null
    private var mapHolder: View? = null
    private var bottomFade: View? = null
    private var navTabs: List<Tab> = emptyList()
    private val navButtons = HashMap<Tab, View>()
    private var lastWidthDp = -1
    private var lastCompactRail = false

    /** Latest compass heading, degrees true; null if no sensor data. */
    var headingDeg: Double? = null; private set
    var compassUnreliable = false; private set
    /** The magnetometer sees more than the Earth's field (steel, magnets, electronics), whatever its calibration says. */
    var compassDisturbed = false; private set
    private val headingListeners = LinkedHashSet<() -> Unit>()
    private val headingGate = com.trailmind.core.geo.HeadingGate()
    private val flushHeading = Runnable {
        headingGate.flush(android.os.SystemClock.elapsedRealtime())?.let {
            headingDeg = it
            headingListeners.forEach { listener -> listener() }
        }
    }

    private var pendingPermission: (() -> Unit)? = null
    private var pendingBluetooth: (() -> Unit)? = null
    private var pendingNearby: (() -> Unit)? = null
    private var pendingRanging: (() -> Unit)? = null
    private var pendingSms: (() -> Unit)? = null
    private var pendingExport: String? = null
    private var backCallback: Any? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        map = MapScreen(this)
        fgLocation = ForegroundLocation(this, app.location)
        compass = Compass(this) { trueDeg, _, acc, disturbed ->
            val now = android.os.SystemClock.elapsedRealtime()
            val headingChanged = headingGate.accept(trueDeg, now)
            Async.main.removeCallbacks(flushHeading)
            headingGate.pendingDelayMs(now)?.let { Async.main.postDelayed(flushHeading, it) }
            val unreliable = acc <= android.hardware.SensorManager.SENSOR_STATUS_ACCURACY_LOW
            val statusChanged = compassUnreliable != unreliable || compassDisturbed != disturbed
            if (headingChanged) headingDeg = trueDeg
            compassUnreliable = unreliable
            compassDisturbed = disturbed
            if (headingChanged || statusChanged) headingListeners.forEach { it() }
        }
        // Edge-to-edge is enforced from API 35; opt in explicitly on older releases.
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT >= 30) window.setDecorFitsSystemWindows(false) else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
        savedInstanceState?.getString("tab")?.let { t -> runCatching { tab = Tab.valueOf(t) } }
        buildLayout()
        showTab(tab)
        if (!app.prefs.onboardingAccepted) push(OnboardingPage(this)) else handleIntent(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString("tab", tab.name)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (app.prefs.onboardingAccepted) handleIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        app.baro.acquire()
        fgLocation.start()
        map.onStart()
        app.watch.setUiVisible(true)
        app.group.setUiVisible(true)
        app.group.groupHikeHandler = ::offerGroupHike
    }

    override fun onStop() {
        app.group.groupHikeHandler = null
        fgLocation.stop()
        map.onStop()
        app.watch.setUiVisible(false)
        app.group.setUiVisible(false)
        app.baro.release()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        headingGate.reset()
        compass.start()
        CheckIn.arm(this)
        stack.lastOrNull()?.onShow()
    }

    override fun onPause() {
        compass.stop()
        Async.main.removeCallbacks(flushHeading)
        headingGate.reset()
        stack.lastOrNull()?.onHide()
        map.saveCamera()
        super.onPause()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (newConfig.screenWidthDp != lastWidthDp || compactRail(newConfig) != lastCompactRail) {
            val wasWide = wide
            val nowWide = newConfig.screenWidthDp >= WIDE_DP
            if (wasWide != nowWide || (nowWide && compactRail(newConfig) != lastCompactRail)) buildLayout() else map.onResize()
            showTab(tab, keepStack = true)
        }
    }

    /** Short wide windows (e.g. the cover screen in landscape) can't fit all rail destinations. */
    private fun compactRail(c: Configuration) = c.screenHeightDp < 600

    fun addHeadingListener(l: () -> Unit) = headingListeners.add(l)
    fun removeHeadingListener(l: () -> Unit) = headingListeners.remove(l)

    // ------------------------------------------------------------------ layout

    private fun detach(v: View) { (v.parent as? ViewGroup)?.removeView(v) }

    private fun buildLayout() {
        lastWidthDp = resources.configuration.screenWidthDp
        lastCompactRail = compactRail(resources.configuration)
        wide = lastWidthDp >= WIDE_DP
        detach(map.view)
        stack.forEach { detach(it.root) }
        navButtons.clear()
        railFrame = null
        mapHolder = null
        bottomFade = null
        val p = ui.p
        val content = FrameLayout(this).apply { setBackgroundColor(p.bg) }
        contentFrame = content
        val root: ViewGroup
        if (!wide) {
            navTabs = listOf(Tab.MAP, Tab.ROUTES, Tab.HIKES, Tab.COMPASS, Tab.MORE)
            val nav = buildNavBar(navTabs, vertical = false)
            navBar = nav
            // Content passes under the capsule, so its foot fades into the page colour instead of ending in a hard edge.
            val fade = View(this).apply {
                background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(p.bg and 0x00FFFFFF, p.bg))
            }
            bottomFade = fade
            root = FrameLayout(this).apply {
                addView(map.view, FrameLayout.LayoutParams(-1, -1))
                addView(content, FrameLayout.LayoutParams(-1, -1))
                addView(fade, FrameLayout.LayoutParams(-1, dp(96), Gravity.BOTTOM))
                // A floating capsule, not a bar: the map shows on both sides of it and below the page's edge.
                addView(nav, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
            }
        } else {
            navTabs = if (lastCompactRail) listOf(Tab.MAP, Tab.ROUTES, Tab.HIKES, Tab.COMPASS, Tab.MORE)
            else listOf(Tab.MAP, Tab.ROUTES, Tab.HIKES, Tab.COMPASS, Tab.OFFLINE, Tab.ASSIST, Tab.SAFETY, Tab.SETTINGS)
            val nav = buildNavBar(navTabs, vertical = true, logo = !lastCompactRail)
            navBar = nav
            val rail = ScrollView(this).apply {
                isFillViewport = true
                isVerticalScrollBarEnabled = false
                addView(nav)
            }
            railFrame = rail
            // The map takes the larger share: a slim rail and a pane no wider than its content needs.
            val paneWidth = (resources.configuration.screenWidthDp * 0.34f).coerceIn(300f, 400f)
            val holder = FrameLayout(this).apply {
                addView(map.view, FrameLayout.LayoutParams(-1, -1))
                clipToOutline = true
                outlineProvider = object : ViewOutlineProvider() {
                    override fun getOutline(view: View, outline: Outline) {
                        val r = if (mapFullScreen) 0f else dp(28).toFloat()
                        // The right corners are pushed off the view, so only the edge beside the pane is rounded.
                        outline.setRoundRect(0, 0, view.width + r.toInt(), view.height, r)
                    }
                }
            }
            mapHolder = holder
            root = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setBackgroundColor(p.bg)
                addView(rail, LinearLayout.LayoutParams(dp(RAIL_DP), -1))
                addView(content, LinearLayout.LayoutParams(dp(paneWidth), -1))
                addView(holder, LinearLayout.LayoutParams(0, -1, 1f))
            }
        }
        root.setOnApplyWindowInsetsListener { _, wi ->
            if (Build.VERSION.SDK_INT >= 30) {
                val i = wi.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                val ime = wi.getInsets(WindowInsets.Type.ime())
                insets.set(i.left, i.top, i.right, maxOf(i.bottom, ime.bottom))
            } else {
                @Suppress("DEPRECATION")
                insets.set(wi.systemWindowInsetLeft, wi.systemWindowInsetTop, wi.systemWindowInsetRight, wi.systemWindowInsetBottom)
            }
            applyInsets()
            wi
        }
        setContentView(root)
        map.onLayoutChanged(wide)
        applyMapFullScreen()
    }

    fun setMapFullScreen(on: Boolean) {
        if (app.prefs.mapFullScreen == on) return
        app.prefs.mapFullScreen = on
        applyMapFullScreen()
    }

    private fun applyMapFullScreen() {
        val full = mapFullScreen
        railFrame?.visibility = if (full) View.GONE else View.VISIBLE
        if (wide) contentFrame?.visibility = if (full) View.GONE else View.VISIBLE
        mapHolder?.invalidateOutline()
        map.onFullScreenChanged(full)
        applyInsets()
        updateBackCallback()
    }

    private fun buildNavBar(tabs: List<Tab>, vertical: Boolean, logo: Boolean = true): LinearLayout {
        if (!vertical) return buildCapsule(tabs)
        val p = ui.p
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            // On the page's own colour, so the rail reads as part of the layout and not as a bar bolted to its edge.
            setBackgroundColor(p.bg)
            if (logo) addView(ImageView(this@MainActivity).apply {
                setImageResource(R.mipmap.ic_launcher)
                contentDescription = "TrailMind"
            }, LinearLayout.LayoutParams(dp(44), dp(44)).apply { topMargin = dp(8); bottomMargin = dp(12) })
            for (t in tabs) {
                val item = LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER
                    setPadding(0, dp(8), 0, dp(8))
                    isClickable = true
                    contentDescription = t.label
                    background = ripple(null, 0x22000000, rounded(android.graphics.Color.WHITE, dp(16).toFloat()))
                    val pill = FrameLayout(this@MainActivity).apply {
                        tag = "pill"
                        addView(ImageView(this@MainActivity).apply {
                            tag = "icon"
                            setImageDrawable(getDrawable(t.icon)?.mutate())
                        }, FrameLayout.LayoutParams(dp(24), dp(24), Gravity.CENTER))
                    }
                    addView(pill, LinearLayout.LayoutParams(dp(56), dp(32)))
                    addView(TextView(this@MainActivity).apply {
                        tag = "label"
                        text = t.label
                        textSize = 11.5f
                        gravity = Gravity.CENTER
                        setPadding(0, dp(4), 0, 0)
                    })
                    setOnClickListener { onNavClick(t) }
                }
                navButtons[t] = item
                addView(item, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(4) })
            }
        }
    }

    /**
     * The phone's navigation: a dark capsule floating over the map. Each destination is an icon; the one you are on
     * opens into a mint pill with its name, so five destinations fit in about 300 dp and the map shows around them.
     */
    private fun buildCapsule(tabs: List<Tab>): LinearLayout {
        val p = ui.p
        // The Fold's cover screen is about 330 dp wide: five destinations and one open label need slimmer buttons there.
        val sidePad = if (resources.configuration.screenWidthDp < 360) 10 else 14
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(p.inverse, dp(32).toFloat(), p.glassStroke, dp(1))
            setPadding(dp(6), dp(6), dp(6), dp(6))
            elevation = dp(10).toFloat()
            for (t in tabs) {
                val item = LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER
                    setPadding(dp(sidePad), 0, dp(sidePad), 0)
                    isClickable = true
                    contentDescription = t.label
                    addView(ImageView(this@MainActivity).apply {
                        tag = "icon"
                        setImageDrawable(getDrawable(t.icon)?.mutate())
                    }, LinearLayout.LayoutParams(dp(24), dp(24)))
                    addView(TextView(this@MainActivity).apply {
                        tag = "label"
                        text = t.label
                        textSize = 13.5f
                        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                        maxLines = 1
                        visibility = View.GONE
                        setPadding(dp(8), 0, 0, 0)
                    })
                    setOnClickListener { onNavClick(t) }
                }
                navButtons[t] = item
                addView(item, LinearLayout.LayoutParams(-2, dp(48)))
            }
        }
    }

    private fun onNavClick(t: Tab) {
        if (t == tab) {
            if (stack.size > 1) showTab(t) else if (t == Tab.MAP) map.locate()
        } else showTab(t)
    }

    private fun updateNavSelection() {
        val p = ui.p
        val selected = if (tab in navTabs) tab else Tab.MORE
        navButtons.forEach { (t, v) ->
            val sel = t == selected
            if (!wide) {
                val mask = rounded(android.graphics.Color.WHITE, dp(24).toFloat())
                v.background = if (sel) ripple(rounded(p.navSelected, dp(24).toFloat()), 0x22000000, mask) else ripple(null, 0x33FFFFFF, mask)
                v.findViewWithTag<ImageView>("icon").drawable?.setTint(if (sel) p.onNavSelected else p.inverseMuted)
                v.findViewWithTag<TextView>("label").apply {
                    visibility = if (sel) View.VISIBLE else View.GONE
                    setTextColor(p.onNavSelected)
                }
            } else {
                val pill = v.findViewWithTag<FrameLayout>("pill")
                pill.background = if (sel) rounded(p.navSelected, dp(16).toFloat()) else null
                v.findViewWithTag<ImageView>("icon").drawable?.setTint(if (sel) p.onNavSelected else p.muted)
                v.findViewWithTag<TextView>("label").setTextColor(if (sel) p.onSurface else p.muted)
            }
        }
    }

    private fun applyInsets() {
        val nav = navBar ?: return
        if (!wide) {
            // The capsule floats above the gesture bar; pages and the map keep clear of it by its height plus the gap.
            val gap = insets.bottom + dp(10)
            (nav.layoutParams as? FrameLayout.LayoutParams)?.let { lp ->
                if (lp.bottomMargin != gap) { lp.bottomMargin = gap; nav.layoutParams = lp }
            }
            contentFrame?.setPadding(insets.left, insets.top, insets.right, 0)
            nav.post {
                val clear = nav.height + gap
                map.setInsets(insets.left, insets.top, insets.right, clear)
                stack.lastOrNull()?.setBottomInset(clear + dp(4))
            }
        } else {
            nav.setPadding(insets.left, insets.top + dp(8), 0, insets.bottom)
            railFrame?.let { r ->
                val lp = r.layoutParams as? LinearLayout.LayoutParams
                if (lp != null && lp.width != dp(RAIL_DP) + insets.left) { lp.width = dp(RAIL_DP) + insets.left; r.layoutParams = lp }
            }
            contentFrame?.setPadding(0, insets.top, 0, 0)
            map.setInsets(if (mapFullScreen) insets.left else 0, insets.top, insets.right, insets.bottom)
            stack.lastOrNull()?.setBottomInset(insets.bottom)
        }
    }

    // ------------------------------------------------------------------ navigation

    private fun rootPage(t: Tab): Page? = when (t) {
        Tab.MAP -> if (wide) DashboardPage(this) else null
        Tab.ROUTES -> RoutesPage(this)
        Tab.HIKES -> HikesPage(this)
        Tab.COMPASS -> CompassPage(this)
        Tab.OFFLINE -> OfflinePage(this)
        Tab.ASSIST -> AssistantPage(this)
        Tab.SAFETY -> SafetyPage(this)
        Tab.SETTINGS -> SettingsPage(this)
        Tab.MORE -> MorePage(this)
    }

    /** Switches tab. With [keepStack] the current page stack is re-attached (used after fold/unfold). */
    fun showTab(t: Tab, keepStack: Boolean = false) {
        if (!keepStack && t != Tab.MAP && t != tab) app.planner.cancelPending()
        if (!keepStack && t != tab) setMapFullScreen(false)
        if (!keepStack) {
            val onboarding = (stack.firstOrNull() as? OnboardingPage)?.takeIf { !app.prefs.onboardingAccepted }
            stack.lastOrNull()?.onHide()
            stack.forEach { if (it !== onboarding) it.dispose() }
            stack.clear()
            tab = t
            if (onboarding != null) stack.add(onboarding) else rootPage(t)?.let { stack.add(it) }
        } else {
            // The map tab has a dashboard side pane only in the wide layout.
            if (!wide && stack.size == 1 && stack[0] is DashboardPage) { stack[0].dispose(); stack.clear() }
            if (wide && stack.isEmpty()) rootPage(tab)?.let { stack.add(it) }
        }
        attachTop()
        if (!keepStack) stack.lastOrNull()?.onShow()
    }

    fun push(page: Page) {
        setMapFullScreen(false)
        stack.lastOrNull()?.onHide()
        stack.add(page)
        attachTop()
        page.onShow()
    }

    fun refreshRouteReadiness() {
        (stack.lastOrNull() as? RouteDetailPage)?.onBaseMapChanged()
    }

    fun pop() {
        if (stack.isEmpty()) return
        val top = stack.removeAt(stack.lastIndex)
        top.onHide(); top.dispose()
        if (stack.isEmpty() && !wide) tab = Tab.MAP
        if (stack.isEmpty() && wide) rootPage(tab)?.let { stack.add(it) }
        attachTop()
        stack.lastOrNull()?.let { it.refresh(); it.onShow() }
    }

    private fun attachTop() {
        val frame = contentFrame ?: return
        frame.removeAllViews()
        val top = stack.lastOrNull()
        if (top != null) {
            detach(top.root)
            frame.addView(top.root, FrameLayout.LayoutParams(-1, -1))
            top.ensureRendered()
            frame.visibility = if (mapFullScreen) View.GONE else View.VISIBLE
        } else {
            frame.visibility = if (wide && !mapFullScreen) View.VISIBLE else View.GONE
        }
        // The fade belongs to a page; over the bare map there is nothing to fade.
        bottomFade?.visibility = frame.visibility
        updateNavSelection()
        applyInsets()
        updateBackCallback()
    }

    /** Brings the map into view (narrow screens switch tab; wide screens keep the side pane). */
    fun showMap() {
        if (!wide) showTab(Tab.MAP)
    }

    /** True if [page] is not the root of the current stack (so it gets a back arrow). */
    fun canGoBackWithin(page: Page): Boolean = stack.indexOf(page) > 0

    fun canGoBack(): Boolean = mapFullScreen || (stack.size > 1 && stack.last() !is OnboardingPage) ||
        (!wide && (tab != Tab.MAP || stack.lastOrNull() is SearchPage))

    fun goBack() {
        when {
            mapFullScreen -> setMapFullScreen(false)
            !wide && stack.lastOrNull() is SearchPage -> showTab(Tab.MAP)
            stack.size > 1 -> pop()
            !wide && tab != Tab.MAP -> showTab(Tab.MAP)
        }
    }

    private fun updateBackCallback() {
        if (Build.VERSION.SDK_INT < 33) return
        val want = canGoBack()
        val registered = backCallback != null
        if (want && !registered) {
            val cb = OnBackInvokedCallback { goBack() }
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, cb)
            backCallback = cb
        } else if (!want && registered) {
            onBackInvokedDispatcher.unregisterOnBackInvokedCallback(backCallback as OnBackInvokedCallback)
            backCallback = null
        }
    }

    // Only reached below API 33; newer releases use the OnBackInvokedCallback from updateBackCallback().
    @SuppressLint("GestureBackNavigation")
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (canGoBack()) goBack() else @Suppress("DEPRECATION") super.onBackPressed()
    }

    // ------------------------------------------------------------------ group hikes

    private var groupHikeDialog: android.app.AlertDialog? = null

    /**
     * [who] in the trip group is recording a group hike and this phone isn't. Starts recording straight away when
     * that needs nothing from the user, otherwise (or if they chose to be asked) asks first.
     */
    private fun offerGroupHike(who: String) {
        if (!app.prefs.onboardingAccepted || !app.prefs.groupHikes ||
            TrackingState.status != TrackingState.Status.IDLE || TrackingService.running) return
        val join = {
            withLocationPermission {
                ensureGpsEnabled {
                    requestNotificationPermissionIfNeeded()
                    // Android can refuse to start location recording from a stopped activity; the user can still tap Start hike.
                    runCatching { TrackingService.start(this) }
                        .onSuccess { toast("$who started a group hike, so TrailMind is recording yours too.") }
                        .onFailure { toast("Couldn't start recording. Tap Start hike on the map to join $who.") }
                }
            }
        }
        if (isFinishing || isDestroyed) return
        if (!app.prefs.groupHikesAsk && hasFineLocation() && isGpsEnabled()) { join(); return }
        if (groupHikeDialog?.isShowing == true) return
        groupHikeDialog = ui.dialog().setTitle("$who started a group hike")
            .setMessage("Record your own copy of it? It is saved on this phone, with your own track, time and distance.")
            .setPositiveButton("Start my hike") { _, _ -> join() }
            .setNegativeButton("Not now", null)
            .show()
    }

    // ------------------------------------------------------------------ permissions

    fun hasLocationPermission() = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun hasFineLocation() = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    /** Requests location (and, on Android 13+, notifications) then runs [then] if location was granted. */
    fun withLocationPermission(then: () -> Unit) {
        if (hasFineLocation()) { then(); return }
        pendingPermission = then
        val perms = arrayListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (Build.VERSION.SDK_INT >= 33) perms += Manifest.permission.POST_NOTIFICATIONS
        requestPermissions(perms.toTypedArray(), RC_PERMS)
    }

    fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), RC_NOTIF)
        }
    }

    /** Runs [then] once "Nearby devices" (Bluetooth connect) is granted; not needed before Android 12. */
    fun withBluetoothPermission(then: () -> Unit) {
        if (app.watch.hasPermission()) { then(); return }
        pendingBluetooth = then
        requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), RC_BLUETOOTH)
    }

    /** Runs [then] once trip groups may use Bluetooth: precise location, then "Nearby devices" (scan, advertise, connect). */
    fun withNearbyPermission(then: () -> Unit) {
        withLocationPermission {
            if (GroupRadio.hasPermissions(this) && (!UwbRadio.supported(this) || UwbRadio.hasPermission(this))) {
                then()
            } else {
                pendingNearby = then
                // Ranging (UWB) is in the same Nearby devices group, so Android asks once for both.
                requestPermissions(GroupRadio.permissions() + rangingPermission(), RC_NEARBY)
            }
        }
    }

    /** Runs [then] once TrailMind may use UWB (Android 16's Ranging permission, part of Nearby devices). */
    fun withRangingPermission(then: () -> Unit) {
        if (!UwbRadio.supported(this) || UwbRadio.hasPermission(this)) { then(); return }
        pendingRanging = then
        requestPermissions(rangingPermission(), RC_RANGING)
    }

    @SuppressLint("InlinedApi") // Only asked for on Android 16 and later, where UwbRadio.supported() is true.
    private fun rangingPermission(): Array<String> = if (UwbRadio.supported(this)) arrayOf(Manifest.permission.RANGING) else emptyArray()

    /** Runs [then] once TrailMind may send texts itself (only used for the SOS text the user turned on). */
    fun withSmsPermission(then: () -> Unit) {
        if (checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED) { then(); return }
        pendingSms = then
        requestPermissions(arrayOf(Manifest.permission.SEND_SMS), RC_SMS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RC_SMS) {
            val then = pendingSms
            pendingSms = null
            if (checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED) then?.invoke()
            else toast("Without SMS permission TrailMind can only get the SOS text ready for you to send.")
            stack.lastOrNull()?.refresh()
            return
        }
        if (requestCode == RC_NEARBY) {
            val then = pendingNearby
            pendingNearby = null
            if (GroupRadio.hasPermissions(this)) then?.invoke()
            else ui.dialog().setTitle("Nearby devices needed")
                .setMessage("Trip groups share positions directly between phones over Bluetooth, so TrailMind needs the Nearby devices permission. You can allow it in App info → Permissions.")
                .setPositiveButton("App settings") { _, _ ->
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                }
                .setNegativeButton("Not now", null).show()
            app.group.settingsChanged()
            app.watch.refresh()
            stack.lastOrNull()?.refresh()
            return
        }
        if (requestCode == RC_RANGING) {
            val then = pendingRanging
            pendingRanging = null
            app.group.settingsChanged()
            if (UwbRadio.hasPermission(this)) then?.invoke()
            else toast("TrailMind needs the Nearby devices permission to use UWB.")
            stack.lastOrNull()?.refresh()
            return
        }
        if (requestCode == RC_BLUETOOTH) {
            val then = pendingBluetooth
            pendingBluetooth = null
            if (app.watch.hasPermission()) then?.invoke() else toast("TrailMind needs the Nearby devices permission to reach your watch.")
            app.watch.refresh()
            stack.lastOrNull()?.refresh()
            return
        }
        if (requestCode != RC_PERMS) return
        fgLocation.stop(); fgLocation.start()
        val then = pendingPermission
        pendingPermission = null
        if (hasFineLocation()) then?.invoke()
        else if (hasLocationPermission()) {
            toast("Approximate location only: tracking needs precise location. Enable it in App info → Permissions.")
        } else {
            ui.dialog().setTitle("Location permission needed")
                .setMessage("TrailMind uses your location only on this device, to show you on the map, record hikes and guide you along routes. Nothing is uploaded.")
                .setPositiveButton("App settings") { _, _ ->
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                }
                .setNegativeButton("Not now", null).show()
        }
    }

    fun isGpsEnabled(): Boolean = fgLocation.isGpsEnabled()

    fun ensureGpsEnabled(then: () -> Unit) {
        if (isGpsEnabled()) { then(); return }
        ui.dialog().setTitle("Turn on location")
            .setMessage("GPS (Location) is switched off. Recording and navigation need it.")
            .setPositiveButton("Open settings") { _, _ -> startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) }
            .setNegativeButton("Cancel", null).show()
    }

    // ------------------------------------------------------------------ files

    fun pickGpx() = startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "*/*"
        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/gpx+xml", "application/gpx", "application/xml", "text/xml", "application/octet-stream"))
    }, RC_GPX)

    fun pickMbtiles() = startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "*/*"
    }, RC_MBTILES)

    /** Lets the user save [content] anywhere via the system file picker (Downloads, Drive…). */
    fun saveGpx(fileName: String, content: String) {
        pendingExport = content
        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = ExportProvider.GPX_MIME
            putExtra(Intent.EXTRA_TITLE, safeFileName(fileName) + ".gpx")
        }, RC_EXPORT)
    }

    fun shareGpx(fileName: String, content: String, chooserTitle: String = "Share GPX") {
        val uri = ExportProvider.write(this, safeFileName(fileName) + ".gpx", content)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = ExportProvider.GPX_MIME
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, fileName)
            clipData = ClipData.newRawUri(fileName, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(send, chooserTitle))
    }

    fun shareText(subject: String, text: String) {
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, subject)
            putExtra(Intent.EXTRA_TEXT, text)
        }, subject))
    }

    fun copy(label: String, text: String) {
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(label, text))
        if (Build.VERSION.SDK_INT < 33) toast("Copied")
    }

    fun openUrl(url: String) {
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
            .onFailure { toast("No app can open $url") }
    }

    /** Opens [url] in the web browser even when an installed app (Strava's) has claimed that address. */
    fun openInBrowser(url: String) {
        val intent = Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_BROWSER).apply { data = Uri.parse(url) }
        runCatching { startActivity(intent) }.onFailure { openUrl(url) }
    }

    /**
     * Saves a GPX into the phone's Downloads without asking where, so a file chooser lists it first. Saving it again
     * replaces the earlier copy. Returns the file name, or null where that needs a permission this app doesn't ask for
     * (Android 9 and older) or the save failed.
     */
    fun saveGpxToDownloads(fileName: String, content: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val name = safeFileName(fileName) + ".gpx"
        val downloads = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val earlier = runCatching {
            contentResolver.query(downloads, arrayOf(MediaStore.MediaColumns._ID), "${MediaStore.MediaColumns.DISPLAY_NAME} = ?", arrayOf(name), null)?.use { c ->
                if (c.moveToFirst()) ContentUris.withAppendedId(downloads, c.getLong(0)) else null
            }
        }.getOrNull()
        val uri = earlier ?: runCatching {
            contentResolver.insert(downloads, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, ExportProvider.GPX_MIME)
            })
        }.getOrNull() ?: return null
        val written = runCatching {
            (contentResolver.openOutputStream(uri, "wt") ?: error("no stream")).use { it.write(content.toByteArray()) }
        }.isSuccess
        if (!written) {
            if (earlier == null) runCatching { contentResolver.delete(uri, null, null) }
            return null
        }
        // MediaStore renames on a clash ("name (1).gpx"), so say the name it really used.
        return runCatching {
            contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        }.getOrNull() ?: name
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) { pendingExport = null; return }
        when (requestCode) {
            RC_GPX -> importGpx(uri)
            RC_MBTILES -> importMbtiles(uri)
            RC_EXPORT -> {
                val content = pendingExport ?: return
                pendingExport = null
                Async.run({ contentResolver.openOutputStream(uri, "wt")!!.use { it.write(content.toByteArray()) } }) { r ->
                    toast(if (r.isSuccess) "GPX saved" else "Could not save: ${r.exceptionOrNull()?.message}")
                }
            }
        }
    }

    /** Handles a GPX opened/shared into the app that arrived while onboarding was showing. */
    fun handlePendingIntent() = handleIntent(intent)

    private fun handleIntent(intent: Intent?) {
        intent ?: return
        if (intent.action == ACTION_GROUP_MEMBER) {
            intent.action = null
            showTab(Tab.MAP)
            map.focusMember(intent.getIntExtra(EXTRA_MEMBER, 0))
            return
        }
        if (intent.action == ACTION_GROUP_FIND) {
            intent.action = null
            showTab(Tab.SAFETY)
            push(GroupFindPage(this, intent.getIntExtra(EXTRA_MEMBER, 0)))
            return
        }
        if (intent.action == ACTION_STRAVA) {
            intent.action = null
            push(StravaPage(this))
            return
        }
        // Strava's sign-in coming back. Checked before the group invites, which share the trailmind:// scheme.
        if (intent.action == Intent.ACTION_VIEW && intent.dataString?.let { StravaOAuth.isRedirect(it) } == true) {
            val url = intent.dataString.orEmpty()
            intent.action = null
            app.strava.handleRedirect(url) { message -> toast(message); (stack.lastOrNull() as? StravaPage)?.refresh() }
            if (stack.lastOrNull() !is StravaPage) push(StravaPage(this))
            return
        }
        if (intent.action == Intent.ACTION_VIEW && intent.data?.scheme == GROUP_LINK_SCHEME) {
            val link = intent.data
            intent.action = null
            link?.let { joinGroupFromLink(this, it) }
            return
        }
        if (intent.action == ACTION_SAFETY) {
            intent.action = null
            showTab(Tab.SAFETY)
            return
        }
        if (intent.action == ACTION_OFFLINE) {
            intent.action = null
            showTab(Tab.OFFLINE)
            return
        }
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
            else -> null
        }
        if (uri != null) {
            intent.action = null
            importGpx(uri)
        }
    }

    fun displayName(uri: Uri): String? = runCatching {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull()

    fun importGpx(uri: Uri) {
        val fileName = displayName(uri)?.substringBeforeLast('.')
        toast("Importing GPX…")
        Async.run({
            val doc = contentResolver.openInputStream(uri)!!.use { GpxParser.parse(it) }
            val line = doc.primaryLine()
            require(line.size >= 2) { "No track or route with at least two points was found in this file." }
            val name = doc.bestName() ?: fileName ?: "Imported route"
            app.db.insertRoute(name, line, doc.waypoints) to line.none { it.ele != null }
        }) { r ->
            r.onSuccess { (id, needsTerrain) ->
                val detail = RouteDetailPage(this, id)
                val fetchTerrain = needsTerrain && app.tiles.networkAllowed()
                toast(if (fetchTerrain) "Route imported. Adding heights…" else "Route imported")
                showTab(Tab.ROUTES)
                push(detail)
                if (fetchTerrain) Async.run({
                    val route = app.db.routeData(id) ?: return@run false to null
                    val changed = app.db.updateRouteHeights(id, app.terrain.fill(route.points))
                    changed to app.db.routeData(id)
                }) { terrainResult ->
                    terrainResult.getOrNull()?.let { (changed, updated) ->
                        if (changed) {
                            detail.applyTerrainData(updated)
                            toast("Terrain heights added")
                        }
                    }
                }
            }.onFailure { e -> ui.dialog().setTitle("Import failed").setMessage(e.message ?: e.toString()).setPositiveButton("OK", null).show() }
        }
    }

    fun importMbtiles(uri: Uri) {
        val name = displayName(uri)?.substringBeforeLast('.') ?: "Imported map"
        val progress = ui.dialog().setTitle("Importing offline map").setMessage("Copying $name…").setCancelable(false).show()
        Async.run({
            val fileName = "import_${System.currentTimeMillis()}.mbtiles"
            val file = TileProvider.packFile(this, fileName)
            try {
                contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use { input.copyTo(it, 256 * 1024) } }
                val info = MbTiles.openReadOnly(file).use { mb ->
                    require(mb.metadata()["crs"]?.equals("EPSG:27700", ignoreCase = true) != true) {
                        "This British National Grid map cannot be imported because TrailMind places imported maps using Web Mercator."
                    }
                    mb.info()
                }
                require(info.tileCount > 0) { "This file contains no tiles." }
                require(info.format in MbTiles.RASTER_FORMATS) {
                    "This is a '${info.format}' MBTiles file. TrailMind renders raster (PNG/JPEG/WebP) tiles only; vector (pbf) packs are not supported yet."
                }
                app.db.insertPack(
                    name = info.name?.takeIf { it.isNotBlank() } ?: name, kind = PackKind.IMPORT, sourceId = "import",
                    fileName = fileName, minZoom = info.minZoom, maxZoom = info.maxZoom, bounds = info.bounds, routeId = null,
                    bufferM = 0.0, tileTotal = info.tileCount, status = PackStatus.READY, format = info.format,
                    attribution = info.attribution,
                ).also {
                    app.db.updatePackProgress(it, info.tileCount, 0, file.length(), PackStatus.READY)
                    app.tiles.reloadPacks()
                }
            } catch (e: Throwable) {
                file.delete()
                throw e
            }
        }) { r ->
            progress.dismiss()
            r.onSuccess { id ->
                ui.dialog().setTitle("Offline map ready")
                    .setMessage("\"$name\" was imported. Use it as the base map now?")
                    .setPositiveButton("Use it") { _, _ -> map.setSource("pack:$id") }
                    .setNegativeButton("Later", null).show()
                stack.lastOrNull()?.refresh()
            }.onFailure { e -> ui.dialog().setTitle("Import failed").setMessage(e.message ?: e.toString()).setPositiveButton("OK", null).show() }
        }
    }

    fun edgeGalleryInstalled(): Boolean = packageManager.getLaunchIntentForPackage(EDGE_GALLERY) != null

    /** Copies [prompt] and opens Google AI Edge Gallery. It has no public intent API, so the user pastes the prompt. */
    fun openEdgeGallery(prompt: String) {
        copy("TrailMind prompt", prompt)
        val launch = packageManager.getLaunchIntentForPackage(EDGE_GALLERY)
        if (launch == null) {
            ui.dialog().setTitle("Edge Gallery not found")
                .setMessage("Google AI Edge Gallery runs Gemma models fully on-device. Install it, download a Gemma model inside it, then paste the prompt (already copied) into AI Chat.")
                .setPositiveButton("Get Edge Gallery") { _, _ -> openUrl("https://play.google.com/store/apps/details?id=$EDGE_GALLERY") }
                .setNeutralButton("GitHub") { _, _ -> openUrl("https://github.com/google-ai-edge/gallery") }
                .setNegativeButton("Close", null).show()
            return
        }
        toast("Prompt copied. In Edge Gallery open AI Chat with a Gemma model and paste it.")
        startActivity(launch)
    }

    companion object {
        const val ACTION_SAFETY = "com.trailmind.app.OPEN_SAFETY"
        const val ACTION_OFFLINE = "com.trailmind.app.OPEN_OFFLINE"
        const val ACTION_GROUP_MEMBER = "com.trailmind.app.GROUP_MEMBER"
        const val ACTION_GROUP_FIND = "com.trailmind.app.GROUP_FIND"
        const val ACTION_STRAVA = "com.trailmind.app.STRAVA"
        const val EXTRA_MEMBER = "member"
        const val GROUP_LINK_SCHEME = "trailmind"
        const val WIDE_DP = 600
        const val RAIL_DP = 76
        const val EDGE_GALLERY = "com.google.aiedge.gallery"
        private const val RC_PERMS = 10
        private const val RC_NOTIF = 11
        private const val RC_BLUETOOTH = 12
        private const val RC_SMS = 13
        private const val RC_NEARBY = 14
        private const val RC_RANGING = 15
        private const val RC_GPX = 20
        private const val RC_MBTILES = 21
        private const val RC_EXPORT = 22

        fun safeFileName(s: String) = s.replace(Regex("[^A-Za-z0-9 ._-]+"), "_").trim().take(60).ifBlank { "trailmind" }
    }
}
