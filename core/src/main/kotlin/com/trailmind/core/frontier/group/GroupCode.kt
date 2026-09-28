package com.trailmind.core.frontier.group

import java.security.MessageDigest
import java.security.SecureRandom

/**
 * A trip group's secret, written as 16 Crockford base32 characters ("K7QM-2XRA-9PTW-4HNE"). The first 75 bits are
 * random and the last 5 are a check, so most typing mistakes are rejected instead of silently joining an empty group.
 */
class GroupCode private constructor(private val raw: ByteArray) {
    val bytes: ByteArray get() = raw.copyOf()

    /** The 16 characters without separators. */
    val text: String get() = encode(raw)

    /** For reading out and typing: four groups of four. */
    val formatted: String get() = text.chunked(4).joinToString("-")

    override fun equals(other: Any?) = other is GroupCode && raw.contentEquals(other.raw)
    override fun hashCode() = raw.contentHashCode()
    override fun toString() = "GroupCode(****)"

    companion object {
        const val LENGTH = 16
        const val BYTES = 10
        private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

        fun generate(random: SecureRandom = SecureRandom()): GroupCode =
            GroupCode(withCheck(ByteArray(BYTES).also(random::nextBytes)))

        /** Accepts any case, spaces and dashes, and the usual look-alikes (O for 0, I and L for 1). Null if invalid. */
        fun parse(input: String): GroupCode? {
            val chars = input.uppercase().filterNot { it == '-' || it.isWhitespace() }
                .map { when (it) { 'O' -> '0'; 'I', 'L' -> '1'; else -> it } }
            if (chars.size != LENGTH) return null
            val b = ByteArray(BYTES)
            var bit = 0
            for (c in chars) {
                val v = ALPHABET.indexOf(c)
                if (v < 0) return null
                for (i in 4 downTo 0) {
                    if ((v shr i) and 1 == 1) b[bit / 8] = (b[bit / 8].toInt() or (0x80 ushr (bit % 8))).toByte()
                    bit++
                }
            }
            return if (withCheck(b.copyOf()).contentEquals(b)) GroupCode(b) else null
        }

        private fun withCheck(b: ByteArray): ByteArray {
            b[BYTES - 1] = (b[BYTES - 1].toInt() and 0xE0).toByte()
            val digest = MessageDigest.getInstance("SHA-256").digest(b)
            b[BYTES - 1] = (b[BYTES - 1].toInt() or ((digest[0].toInt() and 0xFF) ushr 3)).toByte()
            return b
        }

        private fun encode(b: ByteArray): String = buildString(LENGTH) {
            for (i in 0 until LENGTH) {
                var v = 0
                for (j in 0 until 5) {
                    val bit = i * 5 + j
                    v = (v shl 1) or ((b[bit / 8].toInt() ushr (7 - bit % 8)) and 1)
                }
                append(ALPHABET[v])
            }
        }
    }
}
