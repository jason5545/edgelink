package com.edgelink.app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * Regression tests for the Mac-issued `source_rtsp` endpoint hint consumed by
 * [AndroidCallRelayBridge]. Live 2026-09-03: MirrorCallService walks its
 * source listen port when 7102 is occupied (7102 -> 7105 -> 7108, Mirror.apk
 * `G.java` `p(int)` retries i+3), the phone's event-23 KeyData advertised
 * 7105, and the bridge burned all 30s of connect retries on the dead 7102 ->
 * ECONNREFUSED, zero downlink audio. The Mac now forwards the advertised
 * endpoint as kind=source_rtsp (dataBase64 = base64(ascii "host:port")) and
 * the bridge must dial the hinted endpoint first.
 */
class AndroidCallRelayBridgeTest {

    private fun waitFor(timeoutMs: Long = 3_000, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(10)
        }
        return condition()
    }

    // A port nothing listens on: bind, read the port, close.
    private fun unusedTcpPort(): Int {
        val probe = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val port = probe.localPort
        probe.close()
        return port
    }

    private fun startAcceptor(server: ServerSocket, accepted: AtomicReference<Socket?>) {
        thread(isDaemon = true) {
            runCatching { accepted.set(server.accept()) }
        }
    }

    private fun makeBridge(
        ports: List<Int>,
        logs: CopyOnWriteArrayList<String> = CopyOnWriteArrayList()
    ): AndroidCallRelayBridge.LocalMiLinkRTSPBridge {
        val bridge = AndroidCallRelayBridge.LocalMiLinkRTSPBridge(
            relaySessionId = "test-session",
            localRtspPorts = ports,
            rtpHandler = { },
            statusHandler = { }
        )
        bridge.log = { logs += it }
        return bridge
    }

    @Test
    fun sourceRtspHintArrivingMidRetryConnectsToHintedPort() = runBlocking {
        // The retry loop is already burning rounds on the dead configured
        // port when the Mac's hint lands; it must be picked up within ~one
        // 500ms round and the TCP connect must land on the hinted port.
        val deadPort = unusedTcpPort()
        val source = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val accepted = AtomicReference<Socket?>()
        startAcceptor(source, accepted)
        val bridge = makeBridge(listOf(deadPort))
        val connect = launch(Dispatchers.IO) {
            runCatching { bridge.connectRTSPWithRetry() }
        }
        try {
            delay(700) // at least one full round against the dead port
            assertNull("nothing may connect before the hint", accepted.get())

            bridge.addSourceEndpointHint("127.0.0.1", source.localPort)

            assertTrue(
                "hint should be picked up within ~one round",
                waitFor { accepted.get() != null }
            )
            assertEquals(source.localPort, accepted.get()?.localPort)
            connect.join() // connectRTSPWithRetry returned right after connecting
            assertTrue(connect.isCompleted)
        } finally {
            connect.cancelAndJoin()
            runCatching { accepted.get()?.close() }
            runCatching { source.close() }
        }
    }

    @Test
    fun sourceRtspHintedPortIsTriedBeforeConfiguredPorts() = runBlocking {
        // The hint is authoritative: even with a live listener on the
        // configured port, the hinted port must be dialed first — and once it
        // answers, the configured port is never tried at all.
        val configured = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val hinted = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val configuredAccepted = AtomicReference<Socket?>()
        val hintedAccepted = AtomicReference<Socket?>()
        startAcceptor(configured, configuredAccepted)
        startAcceptor(hinted, hintedAccepted)
        val bridge = makeBridge(listOf(configured.localPort))
        bridge.addSourceEndpointHint("127.0.0.1", hinted.localPort)
        val connect = launch(Dispatchers.IO) {
            runCatching { bridge.connectRTSPWithRetry() }
        }
        try {
            assertTrue("hinted port accepts", waitFor { hintedAccepted.get() != null })
            Thread.sleep(300)
            assertNull(
                "configured port must not be dialed once the hint answers",
                configuredAccepted.get()
            )
        } finally {
            connect.cancelAndJoin()
            runCatching { hintedAccepted.get()?.close() }
            runCatching { configuredAccepted.get()?.close() }
            runCatching { hinted.close() }
            runCatching { configured.close() }
        }
    }

    @Test
    fun sourceRtspHintIsIgnoredWhenSourceAlreadyConnected() = runBlocking {
        // A hint arriving after the source connected must be logged and
        // ignored — no reconnect, no dial towards the hinted port.
        val primary = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val other = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val primaryAccepted = AtomicReference<Socket?>()
        val otherAccepted = AtomicReference<Socket?>()
        startAcceptor(primary, primaryAccepted)
        startAcceptor(other, otherAccepted)
        val logs = CopyOnWriteArrayList<String>()
        val bridge = makeBridge(listOf(primary.localPort), logs)
        val connect = launch(Dispatchers.IO) {
            runCatching { bridge.connectRTSPWithRetry() }
        }
        try {
            assertTrue("primary accepts", waitFor { primaryAccepted.get() != null })
            connect.join()

            bridge.addSourceEndpointHint("127.0.0.1", other.localPort)

            assertTrue(
                "hint receipt must be logged",
                logs.any {
                    it.contains("callrelay.android.local_rtsp_source_hint") &&
                        it.contains("port=${other.localPort}") &&
                        it.contains("ignored=already_connected")
                }
            )
            Thread.sleep(300)
            assertNull("no dial towards the ignored hint", otherAccepted.get())
        } finally {
            connect.cancelAndJoin()
            runCatching { primaryAccepted.get()?.close() }
            runCatching { otherAccepted.get()?.close() }
            runCatching { primary.close() }
            runCatching { other.close() }
        }
    }

    @Test
    fun sourceRtspHintIsLoggedOnReceipt() {
        val logs = CopyOnWriteArrayList<String>()
        val bridge = makeBridge(listOf(7102), logs)
        bridge.addSourceEndpointHint("127.0.0.1", 7105)
        assertTrue(
            logs.any {
                it.contains("callrelay.android.local_rtsp_source_hint") &&
                    it.contains("host=127.0.0.1") &&
                    it.contains("port=7105")
            }
        )
    }

    @Test
    fun sourceRtspHintWithInvalidPortIsRejected() {
        val logs = CopyOnWriteArrayList<String>()
        val bridge = makeBridge(listOf(7102), logs)
        bridge.addSourceEndpointHint("127.0.0.1", 0)
        assertTrue(logs.any { it.contains("callrelay.android.local_rtsp_source_hint_bad") })
    }

    @Test
    fun parseSourceRtspHintAcceptsIPv4HostPort() {
        assertEquals(
            "127.0.0.1" to 7105,
            AndroidCallRelayBridge.parseSourceRTSPEndpointHint("127.0.0.1:7105")
        )
        assertEquals(
            "192.168.1.7" to 1,
            AndroidCallRelayBridge.parseSourceRTSPEndpointHint("192.168.1.7:1")
        )
        assertNotNull(AndroidCallRelayBridge.parseSourceRTSPEndpointHint(" 127.0.0.1:7105 "))
    }

    @Test
    fun parseSourceRtspHintRejectsMalformedValues() {
        listOf(
            "",
            "127.0.0.1",
            "127.0.0.1:",
            ":7105",
            "127.0.0.1:0",
            "127.0.0.1:65536",
            "127.0.0.1:notaport",
            "127.0.0.1:7105:extra",
            "localhost:7105",
            "1.2.3:7105",
            "256.0.0.1:7105",
            "[::1]:7105"
        ).forEach { raw ->
            assertNull("must reject \"$raw\"", AndroidCallRelayBridge.parseSourceRTSPEndpointHint(raw))
        }
    }
}
