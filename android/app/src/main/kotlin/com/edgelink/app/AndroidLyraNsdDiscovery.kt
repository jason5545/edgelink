package com.edgelink.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import kotlinx.coroutines.delay
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

class AndroidLyraNsdDiscovery(
    context: Context
) {
    private val appContext = context.applicationContext

    suspend fun discover(timeoutMs: Long): NsdDiscoveryResult {
        val nsdManager = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
        val services = ConcurrentHashMap<String, NsdSeenService>()
        val events = CopyOnWriteArrayList<String>()
        val multicastLock = acquireMulticastLock()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                events += "started:$serviceType"
                EdgeLinkLog.info("xiaomi.mishare.nsd_started type=$serviceType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val seen = serviceInfo.toSeenService()
                services[seen.serviceName] = seen
                events += "found:${seen.serviceName}"
                EdgeLinkLog.info(
                    "xiaomi.mishare.nsd_found name=${seen.serviceName} " +
                        "type=${seen.serviceType} port=${seen.port}"
                )
                resolveService(nsdManager, serviceInfo, services, events)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                val serviceName = serviceInfo.serviceName.orEmpty()
                services.remove(serviceName)
                events += "lost:$serviceName"
                EdgeLinkLog.info("xiaomi.mishare.nsd_lost name=$serviceName")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                events += "stopped:$serviceType"
                EdgeLinkLog.info("xiaomi.mishare.nsd_stopped type=$serviceType")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                events += "startFailed:$serviceType:$errorCode"
                EdgeLinkLog.warn("xiaomi.mishare.nsd_start_failed type=$serviceType code=$errorCode")
                runCatching { nsdManager.stopServiceDiscovery(this) }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                events += "stopFailed:$serviceType:$errorCode"
                EdgeLinkLog.warn("xiaomi.mishare.nsd_stop_failed type=$serviceType code=$errorCode")
                runCatching { nsdManager.stopServiceDiscovery(this) }
            }
        }

        return try {
            nsdManager.discoverServices(lyraServiceType, NsdManager.PROTOCOL_DNS_SD, listener)
            delay(timeoutMs)
            NsdDiscoveryResult(
                services = services.values.sortedBy { it.serviceName },
                events = events.toList()
            )
        } finally {
            runCatching { nsdManager.stopServiceDiscovery(listener) }
            runCatching { multicastLock?.release() }
        }
    }

    private fun acquireMulticastLock(): WifiManager.MulticastLock? {
        val wifiManager = appContext.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return null
        return runCatching {
            wifiManager.createMulticastLock("EdgeLinkLyraNsdDiscovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        }.getOrElse { error ->
            EdgeLinkLog.warn("xiaomi.mishare.nsd_multicast_lock_failed", error)
            null
        }
    }

    private fun resolveService(
        nsdManager: NsdManager,
        serviceInfo: NsdServiceInfo,
        services: ConcurrentHashMap<String, NsdSeenService>,
        events: CopyOnWriteArrayList<String>
    ) {
        runCatching {
            nsdManager.resolveService(
                serviceInfo,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        val serviceName = serviceInfo.serviceName.orEmpty()
                        events += "resolveFailed:$serviceName:$errorCode"
                        EdgeLinkLog.warn(
                            "xiaomi.mishare.nsd_resolve_failed " +
                                "name=${serviceName.forNsdLog()} code=$errorCode"
                        )
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        val seen = serviceInfo.toSeenService()
                        services[seen.serviceName] = seen
                        events += "resolved:${seen.serviceName}"
                        EdgeLinkLog.info(
                            "xiaomi.mishare.nsd_resolved name=${seen.serviceName.forNsdLog()} " +
                                "type=${seen.serviceType.forNsdLog()} host=${seen.hostAddress ?: "-"} " +
                                "port=${seen.port} txt=${seen.txtSummary().forNsdLog()}"
                        )
                    }
                }
            )
        }.onFailure { error ->
            val serviceName = serviceInfo.serviceName.orEmpty()
            events += "resolveException:$serviceName:${error.javaClass.simpleName}"
            EdgeLinkLog.warn("xiaomi.mishare.nsd_resolve_exception name=${serviceName.forNsdLog()}", error)
        }
    }

    private fun NsdServiceInfo.toSeenService(): NsdSeenService =
        NsdSeenService(
            serviceName = serviceName.orEmpty(),
            serviceType = serviceType.orEmpty(),
            hostAddress = host?.hostAddress,
            port = port,
            attributes = attributes.mapValues { (_, value) -> value.toDiagnosticText() }
        )

    private fun ByteArray.toDiagnosticText(): String {
        if (isEmpty()) return ""
        return if (all { it.toInt() in 0x20..0x7E }) {
            String(this, Charsets.UTF_8)
        } else {
            joinToString(separator = "", prefix = "0x") { "%02X".format(it) }
        }
    }

    data class NsdDiscoveryResult(
        val services: List<NsdSeenService>,
        val events: List<String>
    )

    data class NsdSeenService(
        val serviceName: String,
        val serviceType: String,
        val hostAddress: String?,
        val port: Int,
        val attributes: Map<String, String>
    ) {
        fun compactSummary(): String =
            listOf(
                serviceName,
                serviceType.takeIf { it.isNotBlank() },
                hostAddress?.takeIf { it.isNotBlank() }?.let { "host=$it" },
                port.takeIf { it > 0 }?.let { "port=$it" }
            ).filterNotNull().plus(
                attributes.toSortedMap().entries
                    .take(4)
                    .map { "${it.key}=${it.value.forNsdLog(220)}" }
            ).filterNotNull().joinToString(" ")

        fun txtSummary(): String =
            attributes.toSortedMap().entries.joinToString(",") { "${it.key}=${it.value}" }
    }

    private companion object {
        const val lyraServiceType = "_lyra-mdns._udp."
    }
}

private fun String.forNsdLog(maxLength: Int = 600): String =
    replace('\n', ' ').replace('\r', ' ').take(maxLength)
