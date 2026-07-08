package com.edgelink.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Base64

class PairingTest {
    @Test
    fun sasVectorV1() {
        val hostPk = b64("A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")
        val clientPk = b64("Kay64UG8yvCyLhqU000LxzYeUm0L/hLIl5S8kyKWbdc=")
        val nonceH = b64("QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8=")
        val nonceC = b64("YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8=")

        assertArrayEquals(b64("GmEr3dD+3U/Bfxizfu8qM7FXrqdyXRB2xrkM7vRepm0="), Pairing.commitment(hostPk, nonceH))
        assertEquals("260 433", Pairing.sas(hostPk, clientPk, nonceH, nonceC).display)
    }

    private fun b64(value: String): ByteArray = Base64.getDecoder().decode(value)
}
