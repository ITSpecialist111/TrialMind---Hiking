package com.trailmind.app.plus

import android.view.View
import com.trailmind.app.ui.MainActivity
import com.trailmind.app.ui.Palette
import com.trailmind.app.ui.Ui

/** Settings card for the Frontier look: Dusk, Day (glare) or Night vision (reds only, to keep your eyes adjusted). */
fun lookCard(host: MainActivity): View {
    val ui = host.ui
    val current = Palette.Look.of(host.app.prefs.look)
    return ui.card(spacing = 8) {
        addView(ui.text("Look", Ui.T.TITLE))
        addView(ui.text("Dusk is dark glass over the map. Day is high contrast for bright sun. Night vision uses only red, " +
            "on the map too, so a head torch or a tent does not ruin your eyes.", Ui.T.CAPTION))
        addView(ui.flow {
            Palette.Look.entries.forEach { look ->
                addView(ui.chip(look.label, look == current) {
                    if (look != current) { host.app.prefs.look = look.id; host.recreate() }
                })
            }
        })
    }
}
