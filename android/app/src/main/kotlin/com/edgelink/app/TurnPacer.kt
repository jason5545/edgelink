package com.edgelink.app

// Token-bucket pacing for the TURN relay leg. Measured Cloudflare TURN
// capacity is ~5-6 Mbps per allocation (tools/turn-capacity.py); the 5 Mbps
// encoder plus KCP retransmits otherwise overruns the pipe and collapses it.
// Short bursts pass through, sustained excess is delayed up to a bound, then
// dropped (the source's KCP retransmits drops). Direct paths (no TURN relay
// in the leg) pace at a rate the encoder never reaches.
//
// admit() is a pure decision function with an injectable clock so the pacer
// is unit-testable; the caller performs the delay and the send.
class TurnPacer(
    private val rateBytesPerSecond: () -> Double,
    private val burstBytes: Int,
    private val maxDelayMs: Long,
    private val clockNs: () -> Long = System::nanoTime
) {
    var delayedCount = 0L
        private set
    var droppedCount = 0L
        private set

    private var tokens = burstBytes.toDouble()
    private var lastRefillNs = 0L

    // Returns the milliseconds the caller must wait before sending (0 = send
    // immediately), or null to drop the datagram.
    fun admit(bytes: Int): Long? {
        val bytesPerNs = rateBytesPerSecond() / 1_000_000_000.0
        val now = clockNs()
        if (lastRefillNs == 0L) {
            lastRefillNs = now
        }
        val elapsedNs = now - lastRefillNs
        tokens = minOf(burstBytes.toDouble(), tokens + elapsedNs * bytesPerNs)
        lastRefillNs = now
        tokens -= bytes
        if (tokens >= 0) {
            return 0L
        }
        val deficitMs = ((-tokens) / bytesPerNs / 1_000_000).toLong()
        if (deficitMs <= maxDelayMs) {
            delayedCount += 1
            tokens = 0.0
            // The caller delays deficitMs before sending; the next admit()
            // measures refill from after that wait.
            lastRefillNs = now + deficitMs * 1_000_000
            return deficitMs
        }
        droppedCount += 1
        return null
    }
}
