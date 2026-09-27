package com.trailmind.core

import com.trailmind.core.geo.HeadingGate
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HeadingGateTest {
    @Test fun finalRateLimitedHeadingIsDeliveredWithoutAnotherSensorEvent() {
        val gate = HeadingGate()
        assertTrue(gate.accept(0.0, 0))
        assertFalse(gate.accept(45.0, 20))
        assertEquals(47L, gate.pendingDelayMs(20))
        assertFalse(gate.accept(90.0, 60))
        assertNull(gate.flush(66))
        assertEquals(90.0, gate.flush(67))
        assertNull(gate.pendingDelayMs(67))
        assertNull(gate.flush(100))
    }

    @Test fun returningToDrawnHeadingCancelsPendingTurn() {
        val gate = HeadingGate()
        assertTrue(gate.accept(359.5, 0))
        assertFalse(gate.accept(20.0, 20))
        assertFalse(gate.accept(0.0, 40))
        assertNull(gate.flush(67))
    }

    @Test fun halfDegreeStepsReachFinalHeading() {
        val gate = HeadingGate()
        assertTrue(gate.accept(350.0, 0))
        var drawn = 350.0
        for (step in 1..80) {
            val heading = (350.0 + step * 0.5) % 360.0
            if (gate.accept(heading, step * 10L)) drawn = heading
        }
        drawn = gate.flush(867) ?: drawn
        assertEquals(30.0, drawn)
    }

    @Test fun resetAcceptsFirstReadingAndDropsPendingWork() {
        val gate = HeadingGate()
        assertTrue(gate.accept(10.0, 100))
        assertFalse(gate.accept(30.0, 120))
        gate.reset()
        assertNull(gate.flush(200))
        assertTrue(gate.accept(10.5, 200))
    }

    @Test fun firstHeadingAndStationaryNoise() {
        val gate = HeadingGate()
        assertTrue(gate.accept(90.0, 0))
        assertFalse(gate.accept(90.0, 1000))
        assertFalse(gate.accept(90.9, 2000))
        assertFalse(gate.accept(89.1, 3000))
        assertTrue(gate.accept(91.0, 4000))
    }

    @Test fun thresholdAccumulatesFromLastAcceptedHeading() {
        val gate = HeadingGate()
        assertTrue(gate.accept(10.0, 0))
        assertFalse(gate.accept(10.4, 100))
        assertFalse(gate.accept(10.8, 200))
        assertTrue(gate.accept(11.2, 300))
    }

    @Test fun wrapsAcrossNorthInBothDirections() {
        val gate = HeadingGate()
        assertTrue(gate.accept(359.5, 0))
        assertFalse(gate.accept(0.4, 100))
        assertTrue(gate.accept(0.5, 200))
        assertFalse(gate.accept(360.5, 300))
        assertTrue(gate.accept(359.5, 400))
        assertFalse(gate.accept(-0.5, 500))
    }

    @Test fun rateCapDoesNotConsumeRejectedHeading() {
        val gate = HeadingGate()
        assertTrue(gate.accept(0.0, 0))
        assertFalse(gate.accept(45.0, 66))
        assertTrue(gate.accept(45.0, 67))
        assertFalse(gate.accept(90.0, 133))
        assertTrue(gate.accept(90.0, 134))
    }

    @Test fun sustainedTurningIsCappedAtFifteenUpdatesPerSecond() {
        val gate = HeadingGate()
        val updates = (0L until 1000L).count { gate.accept(it.toDouble(), it) }
        assertEquals(15, updates)
    }

    @Test fun invalidReadingsDoNotChangeAcceptedState() {
        val gate = HeadingGate()
        assertFalse(gate.accept(Double.NaN, 0))
        assertFalse(gate.accept(Double.POSITIVE_INFINITY, 10))
        assertTrue(gate.accept(10.0, 20))
        assertFalse(gate.accept(Double.NEGATIVE_INFINITY, 100))
        assertTrue(gate.accept(11.0, 100))
    }
}