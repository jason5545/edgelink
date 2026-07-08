package com.edgelink.core

import org.junit.Assert.assertEquals
import org.junit.Test

class RelayAuthTest {
    @Test
    fun relayAuthMessageVector() {
        val message = RelayAuth.message("949758990", 1_751_941_000L).decodeToString()
        assertEquals("EdgeLink relay auth v1\n949758990\n1751941000", message)
    }
}
