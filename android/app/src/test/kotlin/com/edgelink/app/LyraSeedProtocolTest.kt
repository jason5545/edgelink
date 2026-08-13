package com.edgelink.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LyraSeedProtocolTest {
    @Test
    fun validate_acceptsStatusWithDeviceId() {
        val request = LyraSeedServiceRequest(action = "status", deviceId = "721572C3")
        assertNull(LyraSeedProtocol.validate(request))
    }

    @Test
    fun validate_rejectsUnknownAction() {
        val request = LyraSeedServiceRequest(action = "drop", deviceId = "721572C3")
        assertEquals("bad action: drop", LyraSeedProtocol.validate(request))
    }

    @Test
    fun validate_rejectsBadDeviceId() {
        for (bad in listOf("", "zz", "721572C3;rm -rf /", "../../etc", "ABC")) {
            val request = LyraSeedServiceRequest(action = "status", deviceId = bad)
            assertNotNull("expected rejection for '$bad'", LyraSeedProtocol.validate(request))
        }
    }

    @Test
    fun validate_seedRequiresCredAndTicket() {
        val missing = LyraSeedServiceRequest(action = "seed", deviceId = "721572C3")
        assertNotNull(LyraSeedProtocol.validate(missing))

        val badJson = LyraSeedServiceRequest(
            action = "seed",
            deviceId = "721572C3",
            cred = "{not json",
            ticket = "{}"
        )
        assertNotNull(LyraSeedProtocol.validate(badJson))

        val nonObject = LyraSeedServiceRequest(
            action = "seed",
            deviceId = "721572C3",
            cred = "[1,2]",
            ticket = "{}"
        )
        assertNotNull(LyraSeedProtocol.validate(nonObject))

        val ok = LyraSeedServiceRequest(
            action = "seed",
            deviceId = "721572C3",
            cred = "{\"account\":{}}",
            ticket = "{\"key\":\"x\"}"
        )
        assertNull(LyraSeedProtocol.validate(ok))
    }

    @Test
    fun requestRoundTrip() {
        val request = LyraSeedServiceRequest(
            action = "seed",
            deviceId = "721572C3",
            cred = "{\"a\":1}",
            ticket = "{\"key\":\"x\"}"
        )
        val decoded = LyraSeedProtocol.decodeRequest(LyraSeedProtocol.encodeRequest(request))
        assertEquals(request, decoded)
    }

    @Test
    fun resultRoundTrip() {
        val result = LyraSeedServiceResult(
            ok = true,
            action = "seed",
            deviceId = "721572C3",
            hasCred = true,
            hasTicket = true,
            credNotAfter = 1833271034,
            output = "installed"
        )
        val decoded = LyraSeedProtocol.decodeResult(LyraSeedProtocol.encodeResult(result))
        assertEquals(result, decoded)
    }

    @Test
    fun decodeResult_defaultsForMissingFields() {
        val decoded = LyraSeedProtocol.decodeResult(
            "{\"ok\":false,\"action\":\"status\",\"deviceId\":\"721572C3\"}"
        )
        assertFalse(decoded.ok)
        assertFalse(decoded.hasCred)
        assertFalse(decoded.hasTicket)
        assertNull(decoded.credNotAfter)
        assertEquals("", decoded.output)
    }

    @Test
    fun decodeResult_ignoresUnknownFields() {
        val decoded = LyraSeedProtocol.decodeResult(
            "{\"ok\":true,\"action\":\"status\",\"deviceId\":\"721572C3\",\"extra\":\"ignored\"}"
        )
        assertTrue(decoded.ok)
    }
}
