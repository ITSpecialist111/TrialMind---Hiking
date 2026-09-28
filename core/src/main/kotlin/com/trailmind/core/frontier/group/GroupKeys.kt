package com.trailmind.core.frontier.group

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** HKDF with HMAC-SHA256 (RFC 5869), on the platform's own crypto so the app needs no library. */
object Hkdf {
    private const val HASH_BYTES = 32

    fun extract(salt: ByteArray, ikm: ByteArray): ByteArray = hmac(if (salt.isEmpty()) ByteArray(HASH_BYTES) else salt, ikm)

    fun expand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * HASH_BYTES) { "bad HKDF length $length" }
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var i = 1
        while (pos < length) {
            t = hmac(prk, t + info + byteArrayOf(i.toByte()))
            val n = minOf(t.size, length - pos)
            t.copyInto(out, pos, 0, n)
            pos += n
            i++
        }
        return out
    }

    fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(data)
}

/** Keys derived from a group code: a local id, the frame encryption key and the key for the rotating group tag. */
class GroupKeys(code: GroupCode) {
    private val secret = Hkdf.extract(SALT, code.bytes)

    /** Identifies the group in this phone's database. Never broadcast. */
    val groupId: String = Hkdf.expand(secret, "id".toByteArray(), 8).joinToString("") { "%02x".format(it) }
    internal val encKey: ByteArray = Hkdf.expand(secret, "enc".toByteArray(), 16)
    private val tagKey: ByteArray = Hkdf.expand(secret, "tag".toByteArray(), 32)
    private val tags = HashMap<Long, ByteArray>()

    /** The [TAG_BYTES]-byte tag the group's advertisements carry during [epoch]. */
    @Synchronized fun tag(epoch: Long): ByteArray = tags.getOrPut(epoch) {
        if (tags.size >= 8) tags.clear()
        val e = epoch.toInt()
        Hkdf.hmac(tagKey, byteArrayOf((e ushr 24).toByte(), (e ushr 16).toByte(), (e ushr 8).toByte(), e.toByte())).copyOf(TAG_BYTES)
    }.copyOf()

    /**
     * Whether the tag at [offset] in [payload] is this group's for the epoch of [unixSeconds] or either neighbour,
     * which allows for phone clocks up to a quarter of an hour apart.
     */
    fun matches(payload: ByteArray, offset: Int, unixSeconds: Long): Boolean {
        if (payload.size < offset + TAG_BYTES) return false
        val now = epoch(unixSeconds)
        return (now - 1..now + 1).any { e ->
            val t = tag(e)
            (0 until TAG_BYTES).all { payload[offset + it] == t[it] }
        }
    }

    companion object {
        const val EPOCH_SECONDS = 900L
        const val TAG_BYTES = 4
        private val SALT = "TrailMind group v1".toByteArray()

        fun epoch(unixSeconds: Long): Long = Math.floorDiv(unixSeconds, EPOCH_SECONDS)
    }
}
