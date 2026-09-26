package com.trailmind.core.map

import com.trailmind.core.geo.TileKey
import java.net.URI

/**
 * Rules that keep TrailMind a polite tile client. Several community tile servers explicitly forbid
 * bulk/offline downloading ("prefetching") in their usage policies, so area downloads are refused
 * for those hosts regardless of what the user configures.
 */
object TilePolicy {
    /** Hosts whose published usage policy forbids bulk downloading. Suffix match. */
    val BULK_DOWNLOAD_FORBIDDEN_HOSTS = listOf(
        "tile.openstreetmap.org",
        "openstreetmap.org",
        "openstreetmap.fr",
        "opentopomap.org",
        "tile.thunderforest.com",
        "cyclosm",
        "arcgisonline.com",
        "google.com",
        "googleapis.com",
        "bing.com",
        "virtualearth.net",
    )

    const val MAX_TILES_PER_DOWNLOAD = 25_000
    const val MAX_ZOOM = 20

    fun hostOf(template: String): String? = runCatching {
        // Both braces escaped: Android's ICU regex rejects a bare '}' (the JVM accepts it).
        URI(template.replace(Regex("\\{-?[a-zA-Z]+\\}"), "0")).host?.lowercase()
    }.getOrNull()

    fun isBulkDownloadForbidden(template: String): Boolean {
        val host = hostOf(template) ?: return true
        return BULK_DOWNLOAD_FORBIDDEN_HOSTS.any { host == it || host.endsWith(".$it") || host.contains(it) }
    }

    /** Fills {z} {x} {y} {s} {key}; {-y} gives TMS rows. [subdomains] rotate deterministically. */
    fun fillTemplate(template: String, tile: TileKey, key: String? = null, subdomains: String = "abc"): String {
        val s = if (subdomains.isEmpty()) "" else subdomains[(tile.x + tile.y).mod(subdomains.length)].toString()
        return template
            .replace("{z}", tile.z.toString())
            .replace("{x}", tile.x.toString())
            .replace("{-y}", tile.tmsY.toString())
            .replace("{y}", tile.y.toString())
            .replace("{s}", s)
            .replace("{key}", key.orEmpty())
    }

    fun validateTemplate(template: String): String? {
        val t = template.trim()
        if (!t.startsWith("https://") && !t.startsWith("http://")) return "URL must start with https://"
        if (!t.contains("{z}") || !t.contains("{x}") || !(t.contains("{y}") || t.contains("{-y}"))) {
            return "URL must contain {z}, {x} and {y} (or {-y})"
        }
        if (hostOf(t) == null) return "URL host is not valid"
        return null
    }
}
