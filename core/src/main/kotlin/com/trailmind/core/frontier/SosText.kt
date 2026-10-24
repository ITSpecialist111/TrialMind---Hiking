package com.trailmind.core.frontier

import com.trailmind.core.geo.LatLon
import com.trailmind.core.geo.OsGrid
import java.util.Locale

/** SOS texts that fit one plain SMS, the service O2 Satellite carries everywhere it reaches. */
object SosText {
    const val MAX_CHARS = 160

    /** For a contact: what happened, where (grid, map link or coordinates), height and battery. */
    fun contact(situation: String, location: LatLon?, altitudeM: Int?, time: String, batteryPercent: Int, words: String? = null): String {
        val what = gsm(situation).trimEnd('.', ' ')
        val prefix = "SOS from TrailMind: "
        val suffix = " at ${gsm(time)}."
        val grid = location?.let { OsGrid.fromWgs84(it)?.format(8) }?.let { " Grid $it." } ?: ""
        val coords = location?.let { " " + String.format(Locale.ROOT, "%.5f,%.5f", it.lat, it.lon) + "." } ?: " No GPS fix."
        val link = location?.let {
            " " + String.format(Locale.ROOT, "https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f", it.lat, it.lon)
        }
        val tail = (altitudeM?.let { " $it m." } ?: "") + if (batteryPercent in 0..100) " Battery $batteryPercent%." else ""
        val head = prefix + what + suffix
        val threeWords = words?.let { com.trailmind.core.geo.ThreeWordAddress.normalize(it) }
            ?.takeIf { location != null && isGsm7(it) }?.let { " ///$it." }
        if (threeWords != null) {
            val room = MAX_CHARS - prefix.length - suffix.length - grid.length - coords.length - tail.length - threeWords.length
            if (room >= 12) return prefix + what.take(room).trimEnd(',', ' ') + suffix + grid + coords + threeWords + tail
        }
        link?.let { head + grid + it + tail }?.takeIf { it.length <= MAX_CHARS }?.let { return it }
        val room = MAX_CHARS - prefix.length - suffix.length - grid.length - coords.length - tail.length
        return prefix + what.take(room.coerceAtLeast(0)).trimEnd(',', ' ') + suffix + grid + coords + tail
    }

    /** For 999 by emergencySMS: the service to send, then what and where. The user reads it before sending. */
    fun emergency(situation: String, location: LatLon?, time: String, words: String? = null): String {
        val where = location?.let { l ->
            (OsGrid.fromWgs84(l)?.format(10)?.let { "Grid $it, " } ?: "") + String.format(Locale.ROOT, "lat %.5f lon %.5f", l.lat, l.lon)
        } ?: "location unknown"
        val threeWords = words?.let { com.trailmind.core.geo.ThreeWordAddress.normalize(it) }?.takeIf { location != null }?.let { " what3words ///$it." } ?: ""
        return "Police, mountain rescue. ${gsm(situation).trim().trimEnd('.')}. $where.$threeWords Time ${gsm(time)}."
    }

    /** True if [text] uses only the basic GSM-7 alphabet, so it is sent as one 160-character SMS. */
    fun isGsm7(text: String): Boolean = text.all { it in GSM7 }

    /** 999 and other emergency-service numbers: TrailMind never texts these by itself, only the user does. */
    fun isEmergencyNumber(number: String): Boolean {
        // Any script's digits (fullwidth, Arabic-Indic...) count as the ASCII digit the phone would dial.
        val digits = number.mapNotNull { c -> Character.digit(c, 10).takeIf { it >= 0 } }.joinToString("")
        return digits in EMERGENCY_NUMBERS || (digits.length <= 6 && EMERGENCY_NUMBERS.any { digits.endsWith(it) })
    }

    private val EMERGENCY_NUMBERS = setOf("999", "112", "911", "000", "110", "119")

    private fun gsm(text: String) = text.map { if (it in GSM7 && it != '\n' && it != '\r') it else ' ' }
        .joinToString("").replace(Regex(" {2,}"), " ").trim()

    private const val GSM7 = "@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?" +
        "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
}
