package com.edgelink.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.net.InetAddress

class LANSessionTransportTest {
    private fun address(literal: String): InetAddress = InetAddress.getByName(literal)

    @Test
    fun prefersRoutableIPv4OverLinkLocalIPv6() {
        val selected = LANSessionTransport.selectPreferredAddress(
            listOf(
                address("fe80::894:9bed:f04:be0e"),
                address("10.5.48.51")
            )
        )

        assertEquals("10.5.48.51", selected)
    }

    @Test
    fun prefersRoutableIPv4OverLinkLocalIPv4() {
        val selected = LANSessionTransport.selectPreferredAddress(
            listOf(
                address("169.254.10.20"),
                address("192.168.1.10")
            )
        )

        assertEquals("192.168.1.10", selected)
    }

    @Test
    fun fallsBackToLinkLocalIPv6WhenNothingElse() {
        val selected = LANSessionTransport.selectPreferredAddress(
            listOf(address("fe80::894:9bed:f04:be0e"))
        )

        assertEquals("fe80:0:0:0:894:9bed:f04:be0e", selected)
    }

    @Test
    fun returnsNullForEmptyCandidates() {
        assertNull(LANSessionTransport.selectPreferredAddress(emptyList()))
    }
}
