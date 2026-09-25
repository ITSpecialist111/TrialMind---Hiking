package com.trailmind.core.geo

/**
 * Joins the pieces of a route (for example the sections of an OpenStreetMap route relation) into one
 * line. A piece is flipped when that puts its start nearer to where the line so far ends. When
 * [ordered] is false the pieces are also chained nearest-end-first, because relations with gaps list
 * their sections in no particular order.
 */
object PathJoin {
    fun join(pieces: List<List<TrackPoint>>, ordered: Boolean = true): List<TrackPoint> {
        val todo = pieces.filter { it.isNotEmpty() }.toMutableList()
        if (todo.isEmpty()) return emptyList()
        val out = ArrayList<TrackPoint>()
        var first = todo.removeAt(0)
        todo.firstOrNull()?.let { next ->
            val fromStart = minOf(d(first.first(), next.first()), d(first.first(), next.last()))
            val fromEnd = minOf(d(first.last(), next.first()), d(first.last(), next.last()))
            if (fromStart < fromEnd) first = first.asReversed()
        }
        append(out, first)
        while (todo.isNotEmpty()) {
            val end = out.last()
            val i = if (ordered) 0 else todo.indices.minBy { minOf(d(end, todo[it].first()), d(end, todo[it].last())) }
            val piece = todo.removeAt(i)
            append(out, if (d(end, piece.last()) < d(end, piece.first())) piece.asReversed() else piece)
        }
        return out
    }

    private fun append(out: MutableList<TrackPoint>, piece: List<TrackPoint>) {
        for (p in piece) if (out.isEmpty() || d(out.last(), p) > 0.5) out += p
    }

    private fun d(a: TrackPoint, b: TrackPoint) = Geo.distanceM(a.lat, a.lon, b.lat, b.lon)
}
