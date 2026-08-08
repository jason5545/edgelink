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

    // `ss -ulpn` output maps each listening UDP socket to its owning process.
    // All the Xiaomi Lyra processes share android.uid.system, so the UID
    // filter alone mixes the mesh service's dial port with sockets owned by
    // the Mirror app (and the mi_connect_service:idm child) — and the
    // numerically-smallest port wins by accident. Observed on device:
    // 50426 = main mi_connect_service (the real mesh dial), 55683 = :idm,
    // 9876/42034 = com.xiaomi.mirror. The relay-cast dial MUST target the
    // main-process port; ordering here puts it first. Process names in ss are
    // truncated to 15 chars, so match by suffix.
    fun parseSs(lines: List<String>): List<Int> {
        data class Entry(val port: Int, val rank: Int)
        val entries = linkedMapOf<Int, Entry>()
        val processPattern = Regex("""users:\(\("([^"]+)"""")
        for (line in lines) {
            val columns = line.trim().split(Regex("\\s+"))
            if (columns.size < 5) continue
            val local = columns.find { it.contains(':') && it.substringAfterLast(':').toIntOrNull() != null }
                ?: continue
            val port = local.substringAfterLast(':').toIntOrNull() ?: continue
            if (port <= 1024 || port == 5353) continue
            val process = processPattern.find(line)?.groupValues?.get(1).orEmpty()
            val rank = when {
                // Main mi_connect_service process (truncates to
                // "connect_service" / "i_connect_service"); the :idm child
                // truncates to "ect_service:idm" and is NOT the mesh dial.
                process.endsWith("connect_service") && !process.endsWith(":idm") -> 0
                process.endsWith("connect_service:idm") || process.endsWith("service:idm") -> 1
                else -> 2
            }
            val existing = entries[port]
            if (existing == null || rank < existing.rank) {
                entries[port] = Entry(port, rank)
            }
        }
        return entries.values.sortedWith(compareBy<Entry> { it.rank }.thenBy { it.port })
            .map { it.port }
            .take(24)
    }
}
