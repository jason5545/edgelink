package com.edgelink.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallInjectModeTest {
    @Test
    fun hookListensOnlyAfterExplicitFallback() {
        assertTrue(CallInjectMode.hookShouldListen(CallInjectMode.MODE_HOOK))
    }

    @Test
    fun hookDefersByDefault() {
        assertFalse(CallInjectMode.hookShouldListen(null))
        assertFalse(CallInjectMode.hookShouldListen(""))
        assertFalse(CallInjectMode.hookShouldListen(CallInjectMode.MODE_SHIZUKU))
        assertFalse(CallInjectMode.hookShouldListen("unknown"))
    }

    @Test
    fun injectorOwnsEndpointUnlessFallback() {
        assertTrue(CallInjectMode.injectorOwnsEndpoint(CallInjectMode.MODE_SHIZUKU))
        assertTrue(CallInjectMode.injectorOwnsEndpoint(null))
        assertTrue(CallInjectMode.injectorOwnsEndpoint(""))
        assertTrue(CallInjectMode.injectorOwnsEndpoint("unknown"))
        assertFalse(CallInjectMode.injectorOwnsEndpoint(CallInjectMode.MODE_HOOK))
    }

    @Test
    fun exactlyOneOwnerForEveryMode() {
        for (mode in listOf(null, "", CallInjectMode.MODE_HOOK, CallInjectMode.MODE_SHIZUKU, "junk")) {
            val hook = CallInjectMode.hookShouldListen(mode)
            val injector = CallInjectMode.injectorOwnsEndpoint(mode)
            // Both listening would fight over port 19307; the injector is
            // the default owner so at least one side always owns the
            // endpoint.
            assertTrue("mode=$mode must have an owner", hook || injector)
            assertFalse("mode=$mode must not double-own", hook && injector)
        }
    }
}

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
