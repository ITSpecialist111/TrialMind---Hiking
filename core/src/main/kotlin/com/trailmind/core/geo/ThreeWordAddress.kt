package com.trailmind.core.geo

import java.util.Locale

object ThreeWordAddress {
    private val words = Regex("""[\p{L}]+(?:[-'][\p{L}]+)*\.[\p{L}]+(?:[-'][\p{L}]+)*\.[\p{L}]+(?:[-'][\p{L}]+)*""")
    fun normalize(input: String): String? {
        val value = input.trim().removePrefix("///").lowercase(Locale.ROOT)
        return value.takeIf { it.length <= 100 && words.matches(it) }
    }
    fun looksLike(input: String) = input.trim().startsWith("///") || normalize(input) != null

    fun canShare(lookupFixMs: Long, currentFixMs: Long, nowMs: Long, sameSquare: Boolean) =
        sameSquare && nowMs - lookupFixMs in 0..60_000 && nowMs - currentFixMs in 0..60_000
}
