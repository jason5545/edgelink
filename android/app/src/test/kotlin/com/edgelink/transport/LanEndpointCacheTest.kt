package com.edgelink.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class LanEndpointCacheTest {
    private val cache = LanEndpointCache()

    @Test
    fun returnsEntryWhenNetworkUnchanged() {
        cache.put("192.168.1.10", 7105, networkKey = "net-1", nowMs = 1000)

        val entry = cache.get("net-1")

        assertNotNull(entry)
        assertEquals("192.168.1.10", entry!!.host)
        assertEquals(7105, entry.port)
        assertEquals(1000, entry.resolvedAtMs)
    }

    @Test
    fun dropsEntryWhenNetworkKeyChanges() {
        cache.put("192.168.1.10", 7105, networkKey = "net-1")

        assertNull(cache.get("net-2"))
        assertNull(cache.get("net-2"))
    }

    @Test
    fun acceptsEntryWhenCurrentNetworkUnknown() {
        cache.put("192.168.1.10", 7105, networkKey = "net-1")

        assertNotNull(cache.get(null))
    }

    @Test
    fun acceptsEntryWhenResolvedNetworkUnknown() {
        cache.put("192.168.1.10", 7105, networkKey = null)

        assertNotNull(cache.get("net-2"))
    }

    @Test
    fun invalidateClearsEntry() {
        cache.put("192.168.1.10", 7105, networkKey = "net-1")

        cache.invalidate()

        assertNull(cache.get("net-1"))
    }

    @Test
    fun invalidateIfMatchesOnlyClearsMatchingEndpoint() {
        cache.put("192.168.1.10", 7105, networkKey = "net-1")

        cache.invalidateIfMatches("192.168.1.11", 7105)
        assertNotNull(cache.get("net-1"))

        cache.invalidateIfMatches("192.168.1.10", 7106)
        assertNotNull(cache.get("net-1"))

        cache.invalidateIfMatches("192.168.1.10", 7105)
        assertNull(cache.get("net-1"))
    }

    @Test
    fun putOverwritesPreviousEntry() {
        cache.put("192.168.1.10", 7105, networkKey = "net-1")
        cache.put("192.168.1.20", 7105, networkKey = "net-1")

        assertEquals("192.168.1.20", cache.get("net-1")!!.host)
    }
}
