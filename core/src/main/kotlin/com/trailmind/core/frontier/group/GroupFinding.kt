package com.trailmind.core.frontier.group

import java.nio.ByteBuffer

/**
 * One step of finding a member up close with UWB, sealed in the group's adverts like every other frame. UWB reaches
 * only tens of metres, so these go between phones in direct Bluetooth range and are never passed on.
 */
data class RangeFrame(
    override val memberId: Int,
    /** The member this is for. */
    val targetId: Int,
    val kind: Int,
    /** Chosen by the finder; picks the session's keys and addresses, and ties every later frame to this request. */
    val nonce: Long,
    val timeS: Long,
    val configId: Int = 0,
    val channel: Int = 0,
    val preambleIndex: Int = 0,
    val updateRate: Int = 0,
    val reason: Int = 0,
) : GroupFrame {
    init {
        require(kind in REQUEST..DECLINE) { "unknown range frame kind $kind" }
        require(timeS in 0..0xFFFF_FFFFL) { "time out of range" }
        require(configId in 0..255 && channel in 0..255 && preambleIndex in 0..255 && updateRate in 0..255 && reason in 0..255) {
            "byte field out of range"
        }
    }

    override val hops: Int get() = 0
    override val ttl: Int get() = 0

    override fun relayed(): GroupFrame? = null

    companion object {
        /** From the finder: start answering UWB with these settings. */
        const val REQUEST = 1
        /** From the member being found: answering now. */
        const val ACCEPT = 2
        /** From either phone: the session is over. */
        const val STOP = 3
        /** From the member being found: can't answer, see [reason]. */
        const val DECLINE = 4

        const val REASON_NOT_ALLOWED = 1
        const val REASON_UWB_OFF = 2
        const val REASON_BUSY = 3
        const val REASON_UNSUPPORTED = 4
        const val REASON_FAILED = 5
    }
}

/**
 * What both phones need for one UWB session, worked out on each phone from the group's key, the two members and the
 * finder's nonce, so none of it goes over the air. Nobody without the group code can join, spoof or follow the session.
 */
class UwbSession private constructor(
    /** FiRa session id: positive and never 0. */
    val sessionId: Int,
    /** Two-byte UWB short addresses, never 0x0000 or the 0xFFFF broadcast, and never the same. */
    val initiatorAddress: ByteArray,
    val responderAddress: ByteArray,
    /** Session key for provisioned STS ([CONFIG_PROVISIONED]). */
    val provisionedKey: ByteArray,
    /** Vendor id then static STS IV, for static STS ([CONFIG_STATIC]). */
    val staticKey: ByteArray,
) {
    fun localAddress(initiator: Boolean): ByteArray = (if (initiator) initiatorAddress else responderAddress).copyOf()
    fun peerAddress(initiator: Boolean): ByteArray = (if (initiator) responderAddress else initiatorAddress).copyOf()

    /** The key [configId] needs, or null for a configuration TrailMind doesn't use. */
    fun keyFor(configId: Int): ByteArray? = when (configId) {
        CONFIG_PROVISIONED -> provisionedKey.copyOf()
        CONFIG_STATIC -> staticKey.copyOf()
        else -> null
    }

    companion object {
        /** Android's UwbRangingParams.CONFIG_PROVISIONED_UNICAST_DS_TWR: resists replay and relay attacks. */
        const val CONFIG_PROVISIONED = 3
        /** Android's UwbRangingParams.CONFIG_UNICAST_DS_TWR, for phones without provisioned STS. */
        const val CONFIG_STATIC = 1
        const val CHANNEL = 9
        /** The preamble codes every FiRa phone supports on channel 9 at the base pulse rate. */
        val PREAMBLES = listOf(9, 10, 11, 12)

        fun derive(keys: GroupKeys, initiatorId: Int, responderId: Int, nonce: Long): UwbSession {
            val info = ByteBuffer.allocate(7 + 16).put("session".toByteArray()).putInt(initiatorId).putInt(responderId).putLong(nonce).array()
            val okm = ByteBuffer.wrap(Hkdf.expand(keys.uwbKey, info, 4 + 2 + 2 + 16 + 8))
            val sessionId = (okm.int and 0x7FFF_FFFF).let { if (it == 0) 1 else it }
            val initiator = usable(okm.short.toInt() and 0xFFFF)
            var responder = usable(okm.short.toInt() and 0xFFFF)
            if (responder == initiator) responder = usable(responder xor 0x8000)
            val provisioned = ByteArray(16).also(okm::get)
            val static = ByteArray(8).also(okm::get)
            if (static[0].toInt() == 0 && static[1].toInt() == 0) static[1] = 1
            return UwbSession(sessionId, address(initiator), address(responder), provisioned, static)
        }

        private fun usable(a: Int): Int = when (a) {
            0x0000 -> 0x0001
            0xFFFF -> 0xFFFE
            else -> a
        }

        private fun address(a: Int) = byteArrayOf((a ushr 8).toByte(), a.toByte())
    }
}
