package com.trailmind.core.frontier.group

import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The service data TrailMind puts in its Bluetooth advertisements: a version byte, the group's rotating tag, then one
 * to [MAX_FRAMES] frames, each sealed with AES-128-GCM under its own random nonce. Without the group code nothing in
 * it is readable, and the tag changes every [GroupKeys.EPOCH_SECONDS] so the group can't be followed for long.
 */
object GroupAdvert {
    /** 128-bit service-data UUID. 16-bit UUIDs are assigned by the Bluetooth SIG, so TrailMind uses its own random one. */
    const val SERVICE_UUID = "79085c44-3375-4f46-b449-c00580560a2b"
    const val VERSION = 1
    const val HEADER_BYTES = 1 + GroupKeys.TAG_BYTES
    const val NONCE_BYTES = 12
    const val TAG_BITS = 96
    const val SEALED_BYTES = NONCE_BYTES + GroupFrames.SIZE + TAG_BITS / 8
    const val MAX_FRAMES = 3

    /** What the service-data AD structure adds around the payload: length, type and the 128-bit UUID. */
    const val AD_OVERHEAD = 2 + 16

    /** How many frames fit in one advertisement when the controller takes up to [maxAdvertisingDataBytes]. */
    fun maxFrames(maxAdvertisingDataBytes: Int): Int =
        ((maxAdvertisingDataBytes - AD_OVERHEAD - HEADER_BYTES) / SEALED_BYTES).coerceIn(0, MAX_FRAMES)

    fun build(keys: GroupKeys, unixSeconds: Long, frames: List<GroupFrame>, random: SecureRandom): ByteArray {
        require(frames.size in 1..MAX_FRAMES) { "1 to $MAX_FRAMES frames per advertisement" }
        val out = ByteArray(HEADER_BYTES + frames.size * SEALED_BYTES)
        out[0] = VERSION.toByte()
        keys.tag(GroupKeys.epoch(unixSeconds)).copyInto(out, 1)
        val header = out.copyOf(HEADER_BYTES)
        frames.forEachIndexed { i, frame ->
            val at = HEADER_BYTES + i * SEALED_BYTES
            val nonce = ByteArray(NONCE_BYTES).also(random::nextBytes)
            nonce.copyInto(out, at)
            cipher(Cipher.ENCRYPT_MODE, keys, nonce, header).doFinal(GroupFrames.encode(frame)).copyInto(out, at + NONCE_BYTES)
        }
        return out
    }

    class Opened(val keys: GroupKeys, val frames: List<GroupFrame>)

    /** The frames in [payload] for whichever of [groups] it belongs to, or null if it isn't theirs. */
    fun open(groups: Collection<GroupKeys>, payload: ByteArray, unixSeconds: Long): Opened? {
        val count = (payload.size - HEADER_BYTES) / SEALED_BYTES
        if (count !in 1..MAX_FRAMES || payload.size != HEADER_BYTES + count * SEALED_BYTES) return null
        if (payload[0].toInt() != VERSION) return null
        val header = payload.copyOf(HEADER_BYTES)
        for (keys in groups) {
            if (!keys.matches(payload, 1, unixSeconds)) continue
            val frames = ArrayList<GroupFrame>(count)
            for (i in 0 until count) {
                val at = HEADER_BYTES + i * SEALED_BYTES
                val nonce = payload.copyOfRange(at, at + NONCE_BYTES)
                val plain = try {
                    cipher(Cipher.DECRYPT_MODE, keys, nonce, header).doFinal(payload, at + NONCE_BYTES, SEALED_BYTES - NONCE_BYTES)
                } catch (e: GeneralSecurityException) {
                    null
                }
                plain?.let(GroupFrames::decode)?.let(frames::add)
            }
            if (frames.isNotEmpty()) return Opened(keys, frames)
        }
        return null
    }

    private fun cipher(mode: Int, keys: GroupKeys, nonce: ByteArray, header: ByteArray): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(keys.encKey, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            updateAAD(header)
        }
}
