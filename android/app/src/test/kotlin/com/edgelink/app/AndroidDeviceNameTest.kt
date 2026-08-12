package com.edgelink.app

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidDeviceNameTest {
    @Test
    fun `compose prefers market name when present`() {
        assertEquals(
            "POCO F8 Ultra",
            AndroidDeviceName.compose(
                marketName = "POCO F8 Ultra",
                manufacturer = "Xiaomi",
                model = "25102PCBEG"
            )
        )
    }

    @Test
    fun `compose trims market name`() {
        assertEquals(
            "Xiaomi 15",
            AndroidDeviceName.compose(marketName = "  Xiaomi 15  ", manufacturer = "Xiaomi", model = "2510")
        )
    }

    @Test
    fun `compose falls back to manufacturer and model`() {
        assertEquals(
            "samsung SM-S911B",
            AndroidDeviceName.compose(marketName = "", manufacturer = "samsung", model = "SM-S911B")
        )
    }

    @Test
    fun `compose falls back to model when manufacturer blank`() {
        assertEquals(
            "Pixel 9",
            AndroidDeviceName.compose(marketName = "", manufacturer = "", model = "Pixel 9")
        )
    }

    @Test
    fun `compose falls back to Android when everything blank`() {
        assertEquals(
            "Android",
            AndroidDeviceName.compose(marketName = "", manufacturer = "", model = "")
        )
    }
}
