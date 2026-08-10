package com.edgelink.app

import org.junit.Assert.assertEquals
import org.junit.Test

class EdgeLinkShizukuScrollTest {
    @Test
    fun wheelAxisMatchesLegacyHookConversion() {
        assertEquals(1f, scrollAxisValue(16), 0.0001f)
        assertEquals(-1f, scrollAxisValue(-16), 0.0001f)
        assertEquals(7.5f, scrollAxisValue(120), 0.0001f)
        assertEquals(0f, scrollAxisValue(0), 0.0001f)
    }

    @Test
    fun wheelAxisClampsToMax() {
        assertEquals(8f, scrollAxisValue(240), 0.0001f)
        assertEquals(-8f, scrollAxisValue(-240), 0.0001f)
        assertEquals(8f, scrollAxisValue(Int.MAX_VALUE), 0.0001f)
        assertEquals(-8f, scrollAxisValue(Int.MIN_VALUE), 0.0001f)
    }
}
