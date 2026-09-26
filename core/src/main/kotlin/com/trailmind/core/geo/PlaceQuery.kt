package com.trailmind.core.geo

object PlaceQuery {
    private val decimal = Regex("^([+-]?\\d+(?:\\.\\d+)?)\\s*(N|S)?(?:\\s*,\\s*|\\s+)([+-]?\\d+(?:\\.\\d+)?)\\s*(E|W)?$", RegexOption.IGNORE_CASE)
    private val gridLike = Regex("^[A-Z]{2}[\\d\\s]+$", RegexOption.IGNORE_CASE)

    fun looksLikeCoordinates(text: String): Boolean = decimal.matches(text.trim())
    fun looksLikeGrid(text: String): Boolean = gridLike.matches(text.trim())

    fun coordinates(text: String): LatLon? {
        val match = decimal.matchEntire(text.trim()) ?: return null
        val lat = match.groupValues[1].toDoubleOrNull() ?: return null
        val lon = match.groupValues[3].toDoubleOrNull() ?: return null
        val ns = match.groupValues[2].uppercase()
        val ew = match.groupValues[4].uppercase()
        if ((ns.isNotEmpty() && lat < 0) || (ew.isNotEmpty() && lon < 0)) return null
        val latitude = if (ns == "S") -lat else lat
        val longitude = if (ew == "W") -lon else lon
        return if (latitude in -90.0..90.0 && longitude in -180.0..180.0) LatLon(latitude, longitude) else null
    }
}