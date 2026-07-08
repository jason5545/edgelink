package com.edgelink.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceIdTest {
    @Test
    fun validatesAndFormatsDeviceIds() {
        assertTrue(DeviceId.isValid("949758990"))
        assertFalse(DeviceId.isValid("049758990"))
        assertEquals("949 758 990", DeviceId.display("949758990"))
    }
}
