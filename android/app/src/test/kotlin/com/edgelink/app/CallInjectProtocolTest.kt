package com.edgelink.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallInjectProtocolTest {
    @Test
    fun magicMatchesMacUplinkFraming() {
        assertArrayEquals(
            byteArrayOf('E'.code.toByte(), 'L'.code.toByte(), 'M'.code.toByte(), 'A'.code.toByte()),
            CallInjectProtocol.MAGIC
        )
    }

    @Test
    fun hasMagicAcceptsExactPrefix() {
        assertTrue(CallInjectProtocol.hasMagic("ELMA".toByteArray()))
        assertTrue(CallInjectProtocol.hasMagic("ELMA\u0000\u0001".toByteArray()))
    }

    @Test
    fun hasMagicRejectsWrongOrShortInput() {
        assertFalse(CallInjectProtocol.hasMagic("ELMB".toByteArray()))
        assertFalse(CallInjectProtocol.hasMagic("elma".toByteArray()))
        assertFalse(CallInjectProtocol.hasMagic("ELM".toByteArray()))
        assertFalse(CallInjectProtocol.hasMagic(ByteArray(0)))
    }
}
