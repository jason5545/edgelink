package com.edgelink.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidMiConnectNetworkingDefaultsTest {
    @Test
    fun resolvesMirrorServiceProfiles() {
        val cast = AndroidMiConnectNetworkingDefaults.serviceProfile("mirrorCast")
        val synergy = AndroidMiConnectNetworkingDefaults.serviceProfile("mirrorSynergy")

        assertEquals("cast", cast?.serviceName)
        assertArrayEquals(byteArrayOf(0x0C, 0xDD.toByte(), 0xFF.toByte(), 0xFC.toByte()), cast?.serviceData)
        assertEquals("synergy", synergy?.serviceName)
        assertArrayEquals(byteArrayOf(0x0C, 0xDD.toByte(), 0xFF.toByte(), 0xFC.toByte()), synergy?.serviceData)
    }

    @Test
    fun keepsLyraShareProfileAvailable() {
        val profile = AndroidMiConnectNetworkingDefaults.serviceProfile("miLyraShare")

        assertEquals("miLyraShare", profile?.serviceName)
        assertArrayEquals(
            byteArrayOf(0x00, 0x00, 0x00, 0x00, 0x12, 0x00, 0x00, 0x01, 0x03),
            profile?.serviceData
        )
    }

    @Test
    fun rejectsUnknownProfile() {
        assertNull(AndroidMiConnectNetworkingDefaults.serviceProfile("unknown"))
    }
}
