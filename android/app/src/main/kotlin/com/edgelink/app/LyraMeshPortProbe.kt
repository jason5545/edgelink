package com.edgelink.app

import android.content.Context

object LyraMeshPortProbe {
    private const val MI_CONNECT_PACKAGE = "com.xiaomi.mi_connect_service"

    fun uid(context: Context): Int? = runCatching {
        context.packageManager.getApplicationInfo(MI_CONNECT_PACKAGE, 0).uid
    }.getOrNull()

    fun probeWildcardUdpPorts(context: Context): List<Int> {
        val uid = uid(context) ?: return emptyList()
        val lines = listOf("/proc/net/udp", "/proc/net/udp6")
            .flatMap { file -> runCatching { java.io.File(file).readLines() }.getOrDefault(emptyList()) }
        return parse(lines, uid)
    }

    fun parse(lines: List<String>, uid: Int): List<Int> {
        val ports = linkedSetOf<Int>()
        for (line in lines) {
            val columns = line.trim().split(Regex("\\s+"))
            if (columns.size < 10) continue
            val local = columns[1]
            val state = columns[3]
            val columnUid = columns[7].toIntOrNull() ?: continue
            if (columnUid != uid) continue
            if (state != "07") continue
            val host = local.substringBeforeLast(':')
            if (host != "00000000" && host != "00000000000000000000000000000000") continue
            val port = local.substringAfterLast(':').toIntOrNull(16) ?: continue
            if (port > 1024 && port != 5353) {
                ports.add(port)
            }
        }
        return ports.sorted().take(24)
    }
}
