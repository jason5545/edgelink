package com.edgelink.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TurnPacerTest {
    private var nowNs = 1_000_000_000L

    private fun newPacer(
        rateBytesPerSecond: Double = 600_000.0,
        burstBytes: Int = 65_536,
        maxDelayMs: Long = 30
    ) = TurnPacer(
        rateBytesPerSecond = { rateBytesPerSecond },
        burstBytes = burstBytes,
        maxDelayMs = maxDelayMs,
        clockNs = { nowNs }
    )

    private fun advanceMs(ms: Long) {
        nowNs += ms * 1_000_000
    }

    @Test
    fun burstWithinBudgetSendsImmediately() {
        val pacer = newPacer()
        // 65_536 bytes of burst budget at ~1200-byte datagrams.
        repeat(50) {
            assertEquals(0L, pacer.admit(1_200))
        }
        assertEquals(0L, pacer.delayedCount)
        assertEquals(0L, pacer.droppedCount)
    }

    @Test
    fun sustainedRateAtCapacityIsDelayedNotDropped() {
        val pacer = newPacer()
        // Drain the burst instantly.
        assertEquals(0L, pacer.admit(65_536))
        // At 600 KB/s a 1_200-byte datagram costs 2ms — inside maxDelayMs.
        // Sustained at-capacity streaming delays every datagram by that cost
        // instead of dropping.
        repeat(10) {
            assertEquals(2L, pacer.admit(1_200))
            advanceMs(2)
        }
        assertEquals(10L, pacer.delayedCount)
        assertEquals(0L, pacer.droppedCount)
    }

    @Test
    fun excessBeyondMaxDelayDrops() {
        val pacer = newPacer()
        // Drain the burst instantly.
        assertEquals(0L, pacer.admit(65_536))
        // 60_000 bytes at 600 KB/s = 100ms deficit — beyond the 30ms bound.
        assertNull(pacer.admit(60_000))
        assertEquals(1L, pacer.droppedCount)
    }

    @Test
    fun tokensRefillAfterIdle() {
        val pacer = newPacer()
        assertEquals(0L, pacer.admit(65_536))
        assertNull(pacer.admit(60_000))
        // Idle long enough to refill the full burst budget.
        advanceMs(1_000)
        assertEquals(0L, pacer.admit(65_536))
        assertEquals(1L, pacer.droppedCount)
        assertEquals(0L, pacer.delayedCount)
    }

    @Test
    fun directPathRateLeavesEncoderRateUntouched() {
        // Direct leg paces at 900 KB/s; 5 Mbps HEVC ≈ 625 KB/s of 1_200-byte
        // datagrams (~2ms apart) must never be delayed or dropped.
        val pacer = newPacer(rateBytesPerSecond = 900_000.0)
        repeat(1_000) {
            assertEquals(0L, pacer.admit(1_200))
            advanceMs(2)
        }
        assertEquals(0L, pacer.delayedCount)
        assertEquals(0L, pacer.droppedCount)
    }

    @Test
    fun moderateExcessIsAbsorbedBelowDelayGranularity() {
        // Current-behavior characterization: the pacer computes delays in
        // whole milliseconds, so a modest excess (1_200-byte datagrams every
        // 1.9ms ≈ 632 KB/s against a 600 KB/s budget, ~0.1ms deficit each)
        // truncates to a 0ms delay and passes — it is neither dropped nor
        // measurably delayed. Effective throttling only starts at larger
        // per-datagram deficits.
        val pacer = newPacer(rateBytesPerSecond = 600_000.0)
        repeat(5_000) {
            val wait = pacer.admit(1_200)
            assertEquals(0L, wait)
            nowNs += 1_900_000
        }
        assertEquals(0L, pacer.droppedCount)
    }

    @Test
    fun floodAboveCapacityDrops() {
        // 1_200-byte datagrams every 0.9ms (≈1.33 MB/s, over twice the
        // 600 KB/s budget): the per-datagram deficit accumulates in whole
        // milliseconds and quickly crosses the 30ms bound — the pacer drops
        // instead of delaying unboundedly.
        val pacer = newPacer(rateBytesPerSecond = 600_000.0)
        var drops = 0L
        repeat(5_000) {
            if (pacer.admit(1_200) == null) {
                drops += 1
            }
            nowNs += 900_000
        }
        assertEquals(drops, pacer.droppedCount)
        assert(drops > 0) { "sustained flood must eventually drop" }
    }
}
