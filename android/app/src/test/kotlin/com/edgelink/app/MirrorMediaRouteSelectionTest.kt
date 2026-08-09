package com.edgelink.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirror media route selection (`selectMirrorMediaRouteFor`). Pins the
 * relay-connected behavior: the Mac sends cloud media args without LAN probe
 * args (the phone is unreachable over LAN), so the bridge must land on TURN
 * when both sides advertise mirrorTurnDataChannel, fall back to the WS/TCP
 * cloudflare route otherwise, and never pick lan_direct without a probe.
 */
class MirrorMediaRouteSelectionTest {

    // Mirrors the exact arg set the Mac sends for the relay-carried mirror
    // (EdgeLinkRuntime.startXiaomiMirrorRelayCloudMedia): mediaBridgeOnly
    // routes the command straight to this decision on the phone, and the
    // missing peerHost/lanProbePort make the LAN probe impossible.
    private fun relayArgs(mirrorTurn: Boolean = true): Map<String, String> = mapOf(
        "mediaBridgeOnly" to "1",
        "peerPort" to "7236",
        "mediaTransport" to "cloudflare",
        "mirrorSessionId" to "session-1",
        "rtpEnvelope" to "milink.mirror.media"
    ) + if (mirrorTurn) mapOf("mirrorTurn" to "1") else emptyMap()

    @Test
    fun relayArgsSelectTurnWhenBothCapsPresent() {
        val selection = selectMirrorMediaRouteFor(
            args = relayArgs(),
            lanProbeReachable = false,
            peerMirrorTurnSupported = true
        )
        assertEquals(MirrorMediaTransport.TURN, selection.transport)
        assertEquals("session-1", selection.cloudSessionId)
    }

    @Test
    fun relayArgsFallBackToCloudflareWithoutTurnCaps() {
        val selection = selectMirrorMediaRouteFor(
            args = relayArgs(),
            lanProbeReachable = false,
            peerMirrorTurnSupported = false
        )
        assertEquals(MirrorMediaTransport.CLOUDFLARE, selection.transport)
        assertEquals("session-1", selection.cloudSessionId)
    }

    @Test
    fun relayArgsFallBackToCloudflareWithoutMirrorTurnArg() {
        val selection = selectMirrorMediaRouteFor(
            args = relayArgs(mirrorTurn = false),
            lanProbeReachable = false,
            peerMirrorTurnSupported = true
        )
        assertEquals(MirrorMediaTransport.CLOUDFLARE, selection.transport)
    }

    @Test
    fun lanProbeReachableSelectsDirectAndDropsCloudSession() {
        val args = relayArgs() + mapOf(
            "peerHost" to "10.0.0.5",
            "lanProbePort" to "43210"
        )
        val selection = selectMirrorMediaRouteFor(
            args = args,
            lanProbeReachable = true,
            lanSourceReachable = true,
            peerMirrorTurnSupported = true
        )
        assertEquals(MirrorMediaTransport.LAN_DIRECT, selection.transport)
        assertNull(selection.cloudSessionId)
    }

    // Live 2026-08-09: relay-carried control session → the phone's Mirror
    // source is loopback-bound, so the Mac's lan_direct RTSP dial is refused
    // and the stream stalls ~40s before the fallback. A reachable Mac probe
    // is not enough — the phone's own source must answer on the LAN too.
    @Test
    fun lanProbeReachableButSourceLocalOnlyVetoesDirect() {
        val args = relayArgs() + mapOf(
            "peerHost" to "10.0.0.5",
            "lanProbePort" to "43210"
        )
        val selection = selectMirrorMediaRouteFor(
            args = args,
            lanProbeReachable = true,
            lanSourceReachable = false,
            peerMirrorTurnSupported = true
        )
        assertEquals(MirrorMediaTransport.TURN, selection.transport)
        assertEquals("session-1", selection.cloudSessionId)
    }

    @Test
    fun unreachableProbeStillSelectsTurn() {
        val args = relayArgs() + mapOf(
            "peerHost" to "10.0.0.5",
            "lanProbePort" to "43210"
        )
        val selection = selectMirrorMediaRouteFor(
            args = args,
            lanProbeReachable = false,
            peerMirrorTurnSupported = true
        )
        assertEquals(MirrorMediaTransport.TURN, selection.transport)
        assertEquals("session-1", selection.cloudSessionId)
    }

    @Test
    fun noCloudArgsSelectLegacyDirectToStopTheBridge() {
        val selection = selectMirrorMediaRouteFor(
            args = mapOf("mediaStop" to "user_stop"),
            lanProbeReachable = false,
            peerMirrorTurnSupported = true
        )
        assertEquals(MirrorMediaTransport.LEGACY_DIRECT, selection.transport)
        assertNull(selection.cloudSessionId)
    }

    // The relay announcer registers the Mac as a real mirror remote, so any
    // startMainDisplay-shaped command that misses the media-bridge guard gets
    // hijacked by the native remote-device route and pulls the phone's own
    // cross-screen UI (PhoneMainMirrorActivity) to the foreground. Recovery
    // must stay on the media bridge exactly like mediaBridgeOnly starts.
    @Test
    fun mediaBridgeGuardAcceptsMediaBridgeOnlyStart() {
        assertTrue(shouldUseMediaBridgeRouteForMirrorStart(relayArgs()))
    }

    @Test
    fun mediaBridgeGuardAcceptsSourceRecoveryArgs() {
        // Exact arg shape of EdgeLinkRuntime.sendXiaomiMirrorSourceRecoveryCommand.
        val recoveryArgs = mapOf(
            "peerPort" to "7236",
            "recovery" to "true",
            "sourceRecoveryOnly" to "true",
            "recoveryAttempt" to "1",
            "recoveryReason" to "decoded_frame_stalled_beyond_threshold"
        )
        assertTrue(shouldUseMediaBridgeRouteForMirrorStart(recoveryArgs))
    }

    @Test
    fun mediaBridgeGuardKeepsNativeRouteForPlainStarts() {
        assertFalse(shouldUseMediaBridgeRouteForMirrorStart(mapOf("peerPort" to "7236")))
        assertFalse(shouldUseMediaBridgeRouteForMirrorStart(mapOf("recovery" to "true")))
        assertFalse(shouldUseMediaBridgeRouteForMirrorStart(emptyMap()))
    }
}
