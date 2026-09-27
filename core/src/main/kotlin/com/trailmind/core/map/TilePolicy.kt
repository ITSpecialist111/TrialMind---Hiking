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
    const val PREMIUM_CACHE_MS = 24L * 3_600_000

    /** A download fetches a Premium tile again unless it has this long left, so renewing restarts the 24 hours. */
    const val PREMIUM_REUSE_MIN_LEFT_MS = 20L * 3_600_000

    fun premiumCacheFresh(cachedAtMs: Long, nowMs: Long): Boolean =
        nowMs - cachedAtMs in 0 until PREMIUM_CACHE_MS

    fun premiumReusable(cachedAtMs: Long, nowMs: Long): Boolean =
        premiumCacheFresh(cachedAtMs, nowMs) && cachedAtMs + PREMIUM_CACHE_MS - nowMs >= PREMIUM_REUSE_MIN_LEFT_MS

    fun premiumPurgeDue(cachedAtMs: Long, nowMs: Long, aheadMs: Long = 0L): Boolean =
        !premiumCacheFresh(cachedAtMs, nowMs) || nowMs - cachedAtMs >= PREMIUM_CACHE_MS - aheadMs

    fun openDataTile(tile: TileKey, premiumFromZoom: Int?): TileKey {
        require(tile.z in 0..MAX_ZOOM)
        val zoom = minOf(tile.z, premiumFromZoom?.minus(1) ?: tile.z)
        require(zoom >= 0)
        val difference = tile.z - zoom
        return TileKey(zoom, tile.x shr difference, tile.y shr difference)
    }

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
