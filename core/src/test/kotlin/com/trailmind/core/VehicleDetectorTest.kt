package com.trailmind.core

import com.trailmind.core.nav.VehicleDetector
import com.trailmind.core.nav.VehicleDetector.Verdict
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class VehicleDetectorTest {
    private val detector = VehicleDetector()
    private var t = 0L
    private var lat = 51.8

    /** One fix every [dtS] seconds, moving north at [mps] and reporting [reported] (null: no Doppler speed). */
    private fun fix(mps: Double, dtS: Int = 2, reported: Double? = mps, accuracyM: Float? = 8f): Verdict {
        t += dtS * 1_000L
        lat += mps * dtS / 111_320.0
        return detector.onFix(t, lat, -2.5, accuracyM, reported)
    }

    private fun drive(mps: Double, seconds: Int, reported: Boolean = true): List<Verdict> =
        (1..seconds / 2).map { fix(mps, 2, if (reported) mps else null) }

    @Test fun walkingNeverTriggers() {
        assertTrue(drive(1.4, 600).all { it == Verdict.ON_FOOT })
        assertNull(detector.runStartedMs)
    }

    @Test fun aHardRunDownhillIsNotAVehicle() {
        assertTrue(drive(4.5, 300).all { it == Verdict.ON_FOOT })
    }

    @Test fun drivingAwayIsFoundAfterHalfAMinute() {
        drive(1.3, 60)
        val verdicts = drive(14.0, 60)
        assertEquals(Verdict.MAYBE, verdicts.first())
        val first = verdicts.indexOf(Verdict.VEHICLE)
        // 2 s apart: the fast run starts at the first fast fix and is confirmed 30 s later.
        assertEquals(15, first)
        assertTrue(verdicts.drop(first).all { it == Verdict.VEHICLE })
    }

    @Test fun theRunStartIsWhereTheDriveBegan() {
        drive(1.3, 60)
        val startOfDrive = t + 2_000
        drive(14.0, 40)
        assertEquals(startOfDrive, detector.runStartedMs)
    }

    @Test fun speedIsWorkedOutFromPositionsWhenTheReceiverGivesNone() {
        drive(1.3, 30, reported = false)
        val verdicts = drive(14.0, 60, reported = false)
        assertTrue(Verdict.VEHICLE in verdicts)
    }

    @Test fun aShortBurstIsHeldThenReleased() {
        drive(1.3, 30)
        val burst = drive(9.0, 14)
        assertTrue(burst.all { it == Verdict.MAYBE })
        // Back to walking: the run is over once the dip lasts longer than the allowance.
        val after = drive(1.3, 20)
        assertEquals(Verdict.ON_FOOT, after.last())
        assertNull(detector.runStartedMs)
    }

    @Test fun aSingleSpikeIsNotEnough() {
        drive(1.3, 30)
        assertEquals(Verdict.MAYBE, fix(1.3, reported = 25.0))
        assertEquals(Verdict.MAYBE, fix(1.3))
        val rest = drive(1.3, 30)
        assertEquals(Verdict.ON_FOOT, rest.last())
    }

    @Test fun aQueueOrJunctionDoesNotEndTheRun() {
        drive(12.0, 20)
        val stopped = drive(0.0, 6)
        assertTrue(stopped.all { it == Verdict.MAYBE })
        val verdicts = drive(12.0, 30)
        assertTrue(Verdict.VEHICLE in verdicts)
    }

    @Test fun aLongStopEndsTheRun() {
        drive(12.0, 20)
        val verdicts = drive(0.0, 20)
        assertEquals(Verdict.ON_FOOT, verdicts.last())
        // And the next drive has to last half a minute of its own.
        assertEquals(Verdict.MAYBE, drive(12.0, 20).last())
    }

    @Test fun poorFixesAreIgnored() {
        drive(1.3, 20)
        // A wild speed on a fix with a 120 m error circle starts nothing.
        assertEquals(Verdict.ON_FOOT, fix(1.3, reported = 30.0, accuracyM = 120f))
        assertNull(detector.runStartedMs)
        // Nor does one end a real run.
        drive(14.0, 10)
        assertEquals(Verdict.MAYBE, fix(1.3, reported = 0.0, accuracyM = 120f))
        assertTrue(detector.runStartedMs != null)
    }

    @Test fun noFixesForAWhileBreaksTheRun() {
        drive(14.0, 20)
        // A minute of silence (a tunnel, GPS off): the run can't carry across it, so a new one starts here.
        val verdict = fix(14.0, dtS = 60)
        assertEquals(Verdict.MAYBE, verdict)
        assertEquals(t, detector.runStartedMs)
    }

    @Test fun standingStillWithAStuckSpeedReadingIsNotAVehicle() {
        // A receiver that reports speed while the position doesn't move: the distance test refuses it.
        repeat(40) {
            t += 2_000
            assertTrue(detector.onFix(t, 51.8, -2.5, 8f, 9.0) != Verdict.VEHICLE)
        }
    }

    @Test fun resetStartsAgain() {
        drive(14.0, 50)
        detector.reset()
        assertEquals(Verdict.ON_FOOT, fix(1.3))
    }
}
