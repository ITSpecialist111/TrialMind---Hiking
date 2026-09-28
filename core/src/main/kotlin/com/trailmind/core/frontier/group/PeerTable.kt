package com.trailmind.core.frontier.group

/** What this phone knows about each other member of its trip group, merged from direct and relayed frames. */
class PeerTable(private val ownMemberId: Int) {
    enum class Freshness { FRESH, STALE, LAST_SEEN }
    enum class Result { NEW, NEWER, SAME, OLDER, REJECTED }

    data class Peer(
        val memberId: Int,
        val name: String? = null,
        val colour: Int? = null,
        val position: PositionFrame? = null,
        /** When this phone first got [position] (phone clock, ms). */
        val positionReceivedMs: Long = 0,
        /** When anything was last heard from or about this member, direct or relayed. */
        val lastHeardMs: Long = 0,
        /** When this phone last heard the member's own phone rather than a relay. */
        val lastDirectMs: Long = 0,
        /** Signal strength of the last direct frame, dBm. */
        val rssi: Int? = null,
        /** Whether the last direct frame came on LE Coded (long range). */
        val coded: Boolean = false,
    )

    private val peers = LinkedHashMap<Int, Peer>()

    @Synchronized fun peers(): List<Peer> = peers.values.toList()
    @Synchronized fun peer(memberId: Int): Peer? = peers[memberId]
    @Synchronized fun restore(peer: Peer) { if (peer.memberId != ownMemberId) peers[peer.memberId] = peer }
    @Synchronized fun clear() = peers.clear()

    /** Merges [frame], heard at [receivedMs] with [rssi] dBm, and says how it compared with what was known. */
    @Synchronized fun accept(frame: GroupFrame, receivedMs: Long, nowS: Long, rssi: Int, coded: Boolean): Result {
        if (frame.memberId == ownMemberId) return Result.REJECTED
        if (frame is PositionFrame && frame.originTimeS > nowS + FUTURE_TOLERANCE_S) return Result.REJECTED
        val old = peers[frame.memberId] ?: Peer(frame.memberId)
        val direct = frame.hops == 0
        val heard = old.copy(
            lastHeardMs = receivedMs,
            lastDirectMs = if (direct) receivedMs else old.lastDirectMs,
            rssi = if (direct) rssi else old.rssi,
            coded = if (direct) coded else old.coded,
        )
        return when (frame) {
            is ProfileFrame -> {
                val same = old.name == frame.name && old.colour == frame.colour
                peers[frame.memberId] = heard.copy(name = frame.name, colour = frame.colour)
                if (same) Result.SAME else Result.NEW
            }
            is PositionFrame -> {
                val cur = old.position
                val order = if (cur == null) 1 else compareValuesBy(frame, cur, { it.originTimeS }, { it.sequence })
                when {
                    order > 0 -> {
                        peers[frame.memberId] = heard.copy(position = frame, positionReceivedMs = receivedMs)
                        if (cur == null) Result.NEW else Result.NEWER
                    }
                    order == 0 -> {
                        // A copy with fewer hops replaces a relayed one, so the map can show it as direct.
                        peers[frame.memberId] = if (cur != null && frame.hops < cur.hops) heard.copy(position = frame) else heard
                        Result.SAME
                    }
                    else -> {
                        peers[frame.memberId] = heard
                        Result.OLDER
                    }
                }
            }
        }
    }

    companion object {
        const val FUTURE_TOLERANCE_S = 300L
        const val FRESH_S = 120L
        const val STALE_S = 900L

        fun freshness(position: PositionFrame, nowS: Long): Freshness {
            val age = nowS - position.originTimeS
            return when {
                age <= FRESH_S -> Freshness.FRESH
                age <= STALE_S -> Freshness.STALE
                else -> Freshness.LAST_SEEN
            }
        }
    }
}

/**
 * Chooses which frames heard from other members this phone passes on, so a member out of someone's range can still
 * reach them through a phone in between. Each frame is passed on for a minute after it first arrives (five for a call
 * for help), a few at a time: calls for help first, then whichever was sent longest ago.
 */
class RelayPolicy(private val windowMs: Long = 60_000, private val helpWindowMs: Long = 300_000) {
    private class Candidate(val frame: GroupFrame, val firstSeenMs: Long) {
        var lastSentMs = 0L
    }

    private val candidates = LinkedHashMap<Long, Candidate>()

    /** Offers a frame this phone accepted as new, or as the same news with fewer hops. */
    @Synchronized fun offer(frame: GroupFrame, receivedMs: Long) {
        val next = frame.relayed() ?: return
        val key = key(frame)
        val existing = candidates[key]
        if (existing != null && sameNews(existing.frame, next)) {
            if (existing.frame.ttl < next.ttl) candidates[key] = Candidate(next, existing.firstSeenMs)
            return
        }
        candidates[key] = Candidate(next, receivedMs)
    }

    @Synchronized fun pick(nowMs: Long, nowS: Long, max: Int, helpOnly: Boolean): List<GroupFrame> {
        candidates.values.removeAll { expired(it, nowMs, nowS) }
        if (max <= 0) return emptyList()
        return candidates.values.filter { !helpOnly || it.frame.needsHelp }
            .sortedWith(compareByDescending<Candidate> { it.frame.needsHelp }.thenBy { it.lastSentMs })
            .take(max)
            .onEach { it.lastSentMs = nowMs }
            .map { it.frame }
    }

    @Synchronized fun size(): Int = candidates.size
    @Synchronized fun clear() = candidates.clear()

    private fun key(f: GroupFrame): Long = ((f.memberId.toLong() and 0xFFFF_FFFFL) shl 2) or if (f is PositionFrame) 1L else 2L

    private fun sameNews(a: GroupFrame, b: GroupFrame) = when {
        a is PositionFrame && b is PositionFrame -> a.sequence == b.sequence && a.originTimeS == b.originTimeS
        a is ProfileFrame && b is ProfileFrame -> a.name == b.name && a.colour == b.colour
        else -> false
    }

    private fun expired(c: Candidate, nowMs: Long, nowS: Long): Boolean {
        val help = c.frame.needsHelp
        if (nowMs - c.firstSeenMs > if (help) helpWindowMs else windowMs) return true
        val f = c.frame
        return f is PositionFrame && nowS - f.originTimeS > if (help) HELP_MAX_AGE_S else MAX_AGE_S
    }

    companion object {
        const val MAX_AGE_S = 600L
        const val HELP_MAX_AGE_S = 3600L
    }
}
