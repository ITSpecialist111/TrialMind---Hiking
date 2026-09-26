package com.trailmind.app.ui

import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.text.Editable
import android.text.TextWatcher
import com.trailmind.app.Async
import com.trailmind.app.R
import com.trailmind.app.data.OsNames
import com.trailmind.core.format.Units
import com.trailmind.core.geo.OsGrid
import com.trailmind.core.geo.PlaceQuery
import java.util.Calendar

class SearchPage(host: MainActivity) : Page(host) {
    private var query = ""
    private var results: List<OsNames.Place>? = null
    private var local: OsNames.Place? = null
    private var error: String? = null
    private var job = 0
    private var request: OsNames.Request? = null
    private val box: EditText by lazy {
        ui.input("Place, postcode, grid ref or coordinates").apply {
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            setOnEditorActionListener { _, action, _ -> if (action == EditorInfo.IME_ACTION_SEARCH) { submit(); true } else false }
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    if (!s.isNullOrEmpty() || query.isEmpty()) return
                    post {
                        if (text.isEmpty() && query.isNotEmpty()) {
                            job++
                            query = ""
                            local = null
                            results = null
                            error = null
                            refresh()
                        }
                    }
                }
            })
        }
    }

    override fun refresh() {
        val focused = box.hasFocus()
        super.refresh()
        if (focused) box.requestFocus()
    }

    override fun onHide() { cancelSearch() }

    override fun dispose() { cancelSearch() }

    private fun cancelSearch() {
        job++
        request?.cancel()
        request = null
    }

    private fun submit() {
        val text = box.text.toString().trim()
        if (text.isEmpty()) { host.toast("Enter a place or position"); return }
        host.getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(box.windowToken, 0)
        box.clearFocus()
        query = text
        app.prefs.recentSearches = (listOf(text) + app.prefs.recentSearches.filterNot { it.equals(text, true) }).take(5)
        request?.cancel()
        request = null
        val id = ++job
        val grid = OsGrid.parse(text)
        val coordinates = PlaceQuery.coordinates(text)
        local = when {
            grid != null -> OsNames.Place(text, "Grid reference", "${Units.distance(grid.precisionM.toDouble(), app.prefs.imperial)} square", grid.position, text.uppercase(), if (grid.precisionM >= 100_000) 9.0 else 15.0)
            coordinates != null -> OsNames.Place(text, "Coordinates", "", coordinates, OsGrid.fromWgs84(coordinates)?.format(6), 15.0)
            else -> null
        }
        val invalidPosition = when {
            grid == null && PlaceQuery.looksLikeGrid(text) -> "Invalid OS grid reference. Use two letters (not I) and an even number of digits."
            coordinates == null && PlaceQuery.looksLikeCoordinates(text) -> "Coordinates must be within 90° latitude and 180° longitude."
            else -> null
        }
        results = if (local != null) emptyList() else null
        error = invalidPosition
        refresh()
        if (local != null || invalidPosition != null) return
        val pending = OsNames.Request().also { request = it }
        Async.run({ OsNames.search(text, app.prefs.osApiKey, pending) }) { response ->
            if (id != job) return@run
            request = null
            results = response.getOrNull()
            error = response.exceptionOrNull()?.let {
                if (it.message?.startsWith("OS Names") == true || it.message?.startsWith("Add your OS") == true || it.message?.startsWith("Could not reach OS Names") == true) it.message
                else "Could not reach OS Names. Check your connection and try again."
            }
            refresh()
        }
    }

    private fun select(place: OsNames.Place) {
        host.map.showSearchPin(place.name, place.position, place.zoom)
        if (host.wide) host.goBack() else host.showTab(MainActivity.Tab.MAP)
    }

    override fun render(): View = ui.column {
        addView(ui.header("Search", { if (host.wide) host.goBack() else host.showTab(MainActivity.Tab.MAP) }))
        addView(ui.scroll(ui.column(padding = 16, spacing = 12) {
            (box.parent as? ViewGroup)?.removeView(box)
            addView(ui.row {
                addView(box, ui.lp(0, weight = 1f))
                addView(ui.button("Search", R.drawable.ic_search, Ui.B.TONAL) { submit() })
            })
            if (query.isEmpty()) {
                app.prefs.recentSearches.forEach { previous ->
                    addView(ui.listItem(previous, "Recent search", R.drawable.ic_search) { box.setText(previous); submit() })
                }
            } else {
                local?.let { place -> addView(ui.listItem(place.name, "${place.type} · ${place.area} · ${place.grid.orEmpty()}", R.drawable.ic_search) { select(place) }) }
                results?.forEach { place ->
                    val detail = listOf(place.type, place.area, place.grid).filterNot { it.isNullOrBlank() }.joinToString(" · ")
                    addView(ui.listItem(place.name, detail, R.drawable.ic_search) { select(place) })
                }
                error?.let { addView(ui.banner(it)) }
                if (local == null && results == null && error == null) addView(ui.text("Searching places…", Ui.T.CAPTION))
                if (local == null && results?.isEmpty() == true) addView(ui.text("No places found. Try part of the name or a postcode district.", Ui.T.CAPTION))
                if (local == null && results != null) addView(ui.text("Place names: Contains OS data © Crown copyright and database rights ${Calendar.getInstance().get(Calendar.YEAR)}", Ui.T.CAPTION))
            }
        }), ui.lp(h = 0, weight = 1f))
    }
}