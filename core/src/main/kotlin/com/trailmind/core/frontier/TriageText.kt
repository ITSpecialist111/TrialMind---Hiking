package com.trailmind.core.frontier

/** Plain-English wording for the three triage answers, in the order a rescue call handler wants them. */
object TriageText {
    fun situation(injury: InjuryType, mobility: Mobility, bleeding: Bleeding): String {
        val i = when (injury) {
            InjuryType.NONE -> "no injury"
            InjuryType.LEG -> "leg injury"
            InjuryType.ARM -> "arm injury"
            InjuryType.HEAD -> "head injury"
            InjuryType.TORSO -> "back or chest injury"
            InjuryType.MULTIPLE -> "multiple injuries"
            InjuryType.OTHER -> "ill or exhausted"
        }
        val m = when (mobility) {
            Mobility.MOBILE -> "can walk"
            Mobility.LIMITED -> "limping"
            Mobility.STATIONARY -> "cannot move"
            Mobility.UNCONSCIOUS -> "not responding"
        }
        val b = when (bleeding) {
            Bleeding.NONE -> "no bleeding"
            Bleeding.CONTROLLED -> "bleeding controlled"
            Bleeding.UNCONTROLLED -> "bleeding not controlled"
            Bleeding.UNKNOWN -> "bleeding unknown"
        }
        return "$i, $m, $b".replaceFirstChar { it.uppercase() }
    }

    /** Needs the fastest response: say so first. */
    fun isUrgent(injury: InjuryType, mobility: Mobility, bleeding: Bleeding) =
        bleeding == Bleeding.UNCONTROLLED || mobility == Mobility.UNCONSCIOUS ||
            (injury == InjuryType.HEAD && mobility != Mobility.MOBILE)

    fun hex(code: Int) = "0x%02X".format(code)
}
