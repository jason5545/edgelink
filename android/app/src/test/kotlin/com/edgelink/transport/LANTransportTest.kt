package com.edgelink.transport

import com.edgelink.core.PhoneActionBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class LANTransportTest {
    private val cloudflareBody = PhoneActionBody(
        requestId = "call-1",
        action = "dial",
        relayHost = "127.0.0.1",
        relayPort = 7102,
        relaySessionId = "cloudflare-session-1",
        lanHost = "192.168.50.10",
        lanPort = 7102,
        lanProbePort = 7103
    )

    @Test
    fun reachableLANReplacesCloudflareMediaEndpoint() {
        val selected = LANTransport.selectPhoneRelayRoute(cloudflareBody, lanReachable = true)

        assertEquals("192.168.50.10", selected.relayHost)
        assertEquals(7102, selected.relayPort)
        assertNull(selected.relaySessionId)
        assertNull(selected.relayControlPort)
    }

    @Test
    fun unreachableLANKeepsWorkingCloudflareEndpoint() {
        val selected = LANTransport.selectPhoneRelayRoute(cloudflareBody, lanReachable = false)

        assertEquals(cloudflareBody, selected)
    }

    @Test
    fun onlyPrivateOrLinkLocalAddressesCanBeProbed() {
        assertTrue(LANTransport.isPermittedLANAddress(InetAddress.getByName("192.168.50.10")))
        assertTrue(LANTransport.isPermittedLANAddress(InetAddress.getByName("169.254.20.30")))
        assertFalse(LANTransport.isPermittedLANAddress(InetAddress.getByName("127.0.0.1")))
        assertFalse(LANTransport.isPermittedLANAddress(InetAddress.getByName("8.8.8.8")))
    }
}
