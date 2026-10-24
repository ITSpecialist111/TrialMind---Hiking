package com.trailmind.core.stats

class LibrarySelection {
    var enabled = false
        private set
    private val selected = linkedSetOf<Long>()
    val ids: Set<Long> get() = selected.toSet()

    fun begin() { enabled = true }
    fun cancel() { enabled = false; selected.clear() }
    fun toggle(id: Long) { if (enabled && !selected.remove(id)) selected.add(id) }
    fun selectAll(eligible: Collection<Long>) { if (enabled) { selected.clear(); selected.addAll(eligible) } }
    fun reconcile(eligible: Collection<Long>) { selected.retainAll(eligible.toSet()) }
}
