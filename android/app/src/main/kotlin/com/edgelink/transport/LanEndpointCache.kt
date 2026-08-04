package com.edgelink.transport

class LanEndpointCache {
    data class Entry(
        val host: String,
        val port: Int,
        val networkKey: String?,
        val resolvedAtMs: Long
    )

    private var entry: Entry? = null

    @Synchronized
    fun put(host: String, port: Int, networkKey: String?, nowMs: Long = System.currentTimeMillis()): Entry {
        val next = Entry(host, port, networkKey, nowMs)
        entry = next
        return next
    }

    @Synchronized
    fun get(currentNetworkKey: String?): Entry? {
        val cached = entry ?: return null
        if (currentNetworkKey != null && cached.networkKey != null && cached.networkKey != currentNetworkKey) {
            entry = null
            return null
        }
        return cached
    }

    @Synchronized
    fun invalidate() {
        entry = null
    }

    @Synchronized
    fun invalidateIfMatches(host: String, port: Int) {
        val cached = entry ?: return
        if (cached.host == host && cached.port == port) {
            entry = null
        }
    }
}
