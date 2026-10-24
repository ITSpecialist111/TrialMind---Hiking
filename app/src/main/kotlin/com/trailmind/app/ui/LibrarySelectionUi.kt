package com.trailmind.app.ui

import android.content.res.ColorStateList
import android.view.View
import android.widget.CheckBox
import com.trailmind.app.R
import com.trailmind.core.stats.LibrarySelection

internal fun Ui.selectionBar(selection: LibrarySelection, eligible: List<Long>, busy: Boolean, refresh: () -> Unit, delete: () -> Unit): View {
    selection.reconcile(eligible)
    return flow {
        if (!selection.enabled) {
            addView(button("Select", null, Ui.B.TONAL) { selection.begin(); refresh() })
        } else {
            addView(button("Select all", null, Ui.B.TONAL) { selection.selectAll(eligible); refresh() }.apply { isEnabled = !busy })
            addView(button("Cancel", null, Ui.B.TEXT) { selection.cancel(); refresh() }.apply { isEnabled = !busy })
            addView(button(if (busy) "Deleting..." else "Delete (${selection.ids.size})", R.drawable.ic_delete, Ui.B.DANGER, delete).apply {
                isEnabled = !busy && selection.ids.isNotEmpty()
            })
        }
    }
}

internal fun Ui.selectionItem(selection: LibrarySelection, id: Long, label: String, eligible: Boolean, busy: Boolean, refresh: () -> Unit): View =
    CheckBox(ctx).apply {
        text = label
        setTextColor(p.onSurface)
        buttonTintList = ColorStateList.valueOf(p.primary)
        minHeight = dp(48)
        isChecked = id in selection.ids
        isEnabled = eligible && !busy
        setOnCheckedChangeListener { _, _ -> selection.toggle(id); refresh() }
    }
