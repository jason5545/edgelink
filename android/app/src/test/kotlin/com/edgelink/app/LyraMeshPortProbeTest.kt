package com.edgelink.app

import org.junit.Assert.assertEquals
import org.junit.Test

class LyraMeshPortProbeTest {

    // Real `ss -ulpn` shape from the device (2026-08-08): process names are
    // truncated to 15 chars. 50426 = main mi_connect_service ("connect_service"),
    // 55683 = the :idm child ("ect_service:idm"), 9876/42034 = Mirror app.
    private val ssOutput = """
        UNCONN 0 0 0.0.0.0:42034 0.0.0.0:* users:(("m.xiaomi.mirror",pid=29612,fd=310))
        UNCONN 0 0 0.0.0.0:9876 0.0.0.0:* users:(("m.xiaomi.mirror",pid=29612,fd=294))
        UNCONN 0 0 *:55683 *:* users:(("ect_service:idm",pid=28085,fd=194))
        UNCONN 0 0 *:50426 *:* users:(("connect_service",pid=27872,fd=170))
        UNCONN 0 0 0.0.0.0:59664 0.0.0.0:* users:(("m.xiaomi.mirror",pid=29612,fd=311))
    """.trimIndent().lines()

    @Test
    fun parseSsOrdersMainMeshProcessPortFirst() {
        val ordered = LyraMeshPortProbe.parseSs(ssOutput)
        assertEquals(50426, ordered.first())
    }

    @Test
    fun parseSsRanksIdmBeforeUnrelatedProcesses() {
        val ordered = LyraMeshPortProbe.parseSs(ssOutput)
        val idmIndex = ordered.indexOf(55683)
        val mirrorIndex = ordered.indexOf(9876)
        assertEquals(0, ordered.indexOf(50426))
        assert(idmIndex > 0 && idmIndex < mirrorIndex) {
            "expected :idm (index $idmIndex) to rank before Mirror (index $mirrorIndex): $ordered"
        }
    }

    @Test
    fun parseSsSkipsWellKnownAndInvalidPorts() {
        val lines = listOf(
            "UNCONN 0 0 0.0.0.0:53 0.0.0.0:* users:((\"connect_service\",pid=1,fd=1))",
            "UNCONN 0 0 0.0.0.0:5353 0.0.0.0:* users:((\"connect_service\",pid=1,fd=2))",
            "Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
        )
        assertEquals(emptyList<Int>(), LyraMeshPortProbe.parseSs(lines))
    }

    @Test
    fun parseSsFallsBackToNumericOrderWithinSameRank() {
        val lines = listOf(
            "UNCONN 0 0 *:60000 *:* users:((\"somethingelse\",pid=1,fd=1))",
            "UNCONN 0 0 *:50000 *:* users:((\"somethingelse\",pid=1,fd=2))"
        )
        assertEquals(listOf(50000, 60000), LyraMeshPortProbe.parseSs(lines))
    }
}
