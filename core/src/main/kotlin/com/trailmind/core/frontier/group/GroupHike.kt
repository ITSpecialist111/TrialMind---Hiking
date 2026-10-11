package com.trailmind.core.frontier.group

/**
 * Decides when this phone should offer to record the hike another member of the trip group is recording, so that
 * everyone in the group ends up with their own log of it.
 *
 * A member's position frames say what they're doing: [GroupFrames.FLAG_RECORDING] with [GroupFrames.FLAG_GROUP_HIKE]
 * means they are recording a hike for the group. [next] returns such a member once, so the phone can start
 * recording or ask. Whatever was decided, that member isn't offered again until their hike has ended, which shows
 * as a frame with neither [GroupFrames.FLAG_RECORDING] nor [GroupFrames.FLAG_PAUSED] set. A paused hike still counts as
 * under way, so someone stopping for lunch (or in the car park) doesn't make a finished hike come back.
 */
class GroupHikeWatch(
    private val freshS: Long = PeerTable.FRESH_S,
    private val handledMaxMs: Long = 24 * 3_600_000L,
) {
    private val handled = HashMap<Int, Long>()

    /** The member whose group hike should be offered now, or null. Each hike is returned once. */
    @Synchronized fun next(peers: List<PeerTable.Peer>, nowS: Long, nowMs: Long): PeerTable.Peer? {
        var best: PeerTable.Peer? = null
        for (peer in peers) {
            val position = peer.position ?: continue
            if (position.flags and (GroupFrames.FLAG_RECORDING or GroupFrames.FLAG_PAUSED) == 0) {
                handled.remove(peer.memberId)
                continue
            }
            val handledMs = handled[peer.memberId]
            if (handledMs != null) {
                if (nowMs - handledMs <= handledMaxMs) continue
                handled.remove(peer.memberId)
            }
            if (!isGroupHike(position) || nowS - position.originTimeS > freshS) continue
            if (best == null || position.originTimeS > best.position!!.originTimeS) best = peer
        }
        best?.let { handled[it.memberId] = nowMs }
        return best
    }

    /** This phone has finished its own hike: the group hikes still going on are not offered back. */
    @Synchronized fun handleAll(peers: List<PeerTable.Peer>, nowMs: Long) {
        for (peer in peers) {
            val position = peer.position ?: continue
            if (position.flags and (GroupFrames.FLAG_RECORDING or GroupFrames.FLAG_PAUSED) != 0) handled[peer.memberId] = nowMs
        }
    }

    @Synchronized fun clear() = handled.clear()

    /** Lets [memberId]'s hike be offered again, when an offer couldn't be made. */
    @Synchronized fun forget(memberId: Int) { handled.remove(memberId) }

    companion object {
        /** Recording, and recording for the group. */
        fun isGroupHike(position: PositionFrame): Boolean =
            position.flags and GroupFrames.FLAG_RECORDING != 0 && position.flags and GroupFrames.FLAG_GROUP_HIKE != 0
    }
}
