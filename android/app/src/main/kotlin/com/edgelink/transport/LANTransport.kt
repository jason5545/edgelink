package com.edgelink.transport

import com.edgelink.app.EdgeLinkLog
import com.edgelink.core.PhoneActionBody
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket

object LANTransport {
    const val SERVICE_TYPE = "_edgelink._tcp"
    const val REACHABILITY_PROBE_PORT = 7_103

    private const val PROBE_REQUEST = "EDGELINK-LAN-PROBE/1\n"
    private const val PROBE_RESPONSE = "EDGELINK-LAN-OK/1\n"
    private const val PROBE_TIMEOUT_MS = 750

    // The phone's own LAN IPv4 (wlan0 preferred), null on loopback-only.
    fun preferredLocalIPv4Address(): String? =
        runCatching {
            val interfaces = NetworkInterface.getNetworkInterfaces() ?: return@runCatching null
            var fallback: String? = null
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                if (!networkInterface.isUp || networkInterface.isLoopback) {
                    continue
                }
                val addresses = networkInterface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    if (address is Inet4Address && !address.isLoopbackAddress) {
                        val host = address.hostAddress
                        if (networkInterface.name == "wlan0") {
                            return@runCatching host
                        }
                        if (fallback == null) {
                            fallback = host
                        }
                    }
                }
            }
            fallback
        }.getOrNull()

    suspend fun preferLAN(body: PhoneActionBody): PhoneActionBody {
        val lanHost = body.lanHost?.trim()?.takeIf { it.isNotEmpty() } ?: return body
        val lanPort = body.lanPort?.takeIf { it in 1..65_535 } ?: return body
        val probePort = body.lanProbePort?.takeIf { it in 1..65_535 } ?: return body
        val reachable = isReachable(lanHost, probePort)
        if (!reachable) {
            EdgeLinkLog.info(
                "lan.android.route_selected transport=cloudflare host=$lanHost " +
                    "mediaPort=$lanPort probePort=$probePort"
            )
            return body
        }
        EdgeLinkLog.info(
            "lan.android.route_selected transport=lan host=$lanHost " +
                "mediaPort=$lanPort probePort=$probePort"
        )
        return selectPhoneRelayRoute(body, lanReachable = true)
    }

    internal fun selectPhoneRelayRoute(
        body: PhoneActionBody,
        lanReachable: Boolean
    ): PhoneActionBody {
        val lanHost = body.lanHost?.trim()?.takeIf { it.isNotEmpty() } ?: return body
        val lanPort = body.lanPort?.takeIf { it in 1..65_535 } ?: return body
        if (!lanReachable) {
            return body
        }
        return body.copy(
            relayHost = lanHost,
            relayPort = lanPort,
            relaySessionId = null,
            relayControlPort = null
        )
    }

    // Plain TCP connect check (no probe protocol) — used to verify the
    // phone's own WFD source actually listens on its LAN address before
    // telling the Mac to dial it (lan_direct).
    suspend fun isTcpConnectable(host: String?, port: Int?, timeoutMs: Int = 300): Boolean {
        val normalizedHost = host?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val normalizedPort = port?.takeIf { it in 1..65_535 } ?: return false
        return withContext(Dispatchers.IO) {
            runCatching {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(normalizedHost, normalizedPort), timeoutMs)
                }
                true
            }.getOrDefault(false)
        }
    }

    suspend fun isReachable(host: String?, port: Int?): Boolean {
        val normalizedHost = host?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val normalizedPort = port?.takeIf { it in 1..65_535 } ?: return false
        return withContext(Dispatchers.IO) {
            runCatching {
                val address = InetAddress.getByName(normalizedHost)
                if (!isPermittedLANAddress(address)) {
                    return@runCatching false
                }
                Socket().use { socket ->
                    socket.tcpNoDelay = true
                    socket.soTimeout = PROBE_TIMEOUT_MS
                    socket.connect(InetSocketAddress(address, normalizedPort), PROBE_TIMEOUT_MS)
                    socket.getOutputStream().write(PROBE_REQUEST.toByteArray(Charsets.UTF_8))
                    socket.getOutputStream().flush()
                    val expected = PROBE_RESPONSE.toByteArray(Charsets.UTF_8)
                    val received = ByteArray(expected.size)
                    var offset = 0
                    while (offset < received.size) {
                        val count = socket.getInputStream().read(received, offset, received.size - offset)
                        if (count < 0) {
                            return@use false
                        }
                        offset += count
                    }
                    received.contentEquals(expected)
                }
            }.onFailure { error ->
                EdgeLinkLog.info(
                    "lan.android.probe_unreachable host=$normalizedHost port=$normalizedPort " +
                        "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                )
            }.getOrDefault(false)
        }
    }

    internal fun isPermittedLANAddress(address: InetAddress): Boolean =
        !address.isAnyLocalAddress &&
            !address.isLoopbackAddress &&
            (address.isSiteLocalAddress || address.isLinkLocalAddress)
}
