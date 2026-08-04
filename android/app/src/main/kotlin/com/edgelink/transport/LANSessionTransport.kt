package com.edgelink.transport

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import com.edgelink.app.EdgeLinkLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket

class LANSessionTransport(context: Context) {
    data class Endpoint(val host: String, val port: Int, val resolvedAtMs: Long)

    private val endpointCache = LanEndpointCache()
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    @Volatile
    private var activeNetworkKey: String? = null

    @Volatile
    private var discoveryStarted = false

    @Volatile
    private var networkCallbackRegistered = false

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            EdgeLinkLog.warn("lan.android.discovery_failed error=$errorCode")
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

        override fun onDiscoveryStarted(serviceType: String) {
            EdgeLinkLog.info("lan.android.discovery_started type=$serviceType")
        }

        override fun onDiscoveryStopped(serviceType: String) = Unit

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    EdgeLinkLog.warn("lan.android.resolve_failed error=$errorCode")
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    val host = info.host?.hostAddress ?: return
                    endpointCache.put(host, info.port, currentNetworkKey())
                    EdgeLinkLog.info("lan.android.endpoint_found host=$host port=${info.port} name=${info.serviceName}")
                }
            })
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            EdgeLinkLog.info("lan.android.endpoint_lost name=${serviceInfo.serviceName}")
            endpointCache.invalidate()
        }
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            handleNetworkChange(network.toString(), "available")
        }

        override fun onLost(network: Network) {
            handleNetworkChange(null, "lost")
        }
    }

    fun startDiscovery() {
        registerNetworkCallbackOnce()
        restartDiscovery()
    }

    fun currentEndpoint(): Endpoint? = cachedEndpoint()

    suspend fun awaitEndpoint(timeoutMs: Long): Endpoint? {
        val deadlineMs = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadlineMs) {
            cachedEndpoint()?.let { return it }
            kotlinx.coroutines.delay(50)
        }
        return cachedEndpoint()
    }

    suspend fun connect(host: String, port: Int): ByteChannel = withContext(Dispatchers.IO) {
        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        } catch (error: Throwable) {
            endpointCache.invalidateIfMatches(host, port)
            EdgeLinkLog.warn("lan.android.connect_failed_endpoint_invalidated host=$host port=$port")
            runCatching { socket.close() }
            throw error
        }
        EdgeLinkLog.info("lan.android.transport_connected host=$host port=$port")
        LANTCPByteChannel(socket, host, port)
    }

    private fun cachedEndpoint(): Endpoint? =
        endpointCache.get(currentNetworkKey())?.let { Endpoint(it.host, it.port, it.resolvedAtMs) }

    private fun currentNetworkKey(): String? =
        activeNetworkKey ?: connectivityManager.activeNetwork?.toString()

    private fun registerNetworkCallbackOnce() {
        if (networkCallbackRegistered) {
            return
        }
        networkCallbackRegistered = true
        activeNetworkKey = connectivityManager.activeNetwork?.toString()
        runCatching {
            connectivityManager.registerDefaultNetworkCallback(networkCallback)
        }.onFailure { error ->
            EdgeLinkLog.warn("lan.android.network_callback_failed error=${error.message}")
        }
    }

    private fun handleNetworkChange(networkKey: String?, reason: String) {
        val previous = activeNetworkKey
        if (reason == "available" && previous != null && previous == networkKey) {
            return
        }
        activeNetworkKey = networkKey
        endpointCache.invalidate()
        EdgeLinkLog.info("lan.android.network_changed reason=$reason from=${previous ?: "-"} to=${networkKey ?: "-"}")
        if (discoveryStarted) {
            restartDiscovery()
        }
    }

    private fun restartDiscovery() {
        if (discoveryStarted) {
            runCatching { nsdManager.stopServiceDiscovery(discoveryListener) }
        }
        runCatching {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            discoveryStarted = true
        }.onFailure { error ->
            EdgeLinkLog.warn("lan.android.discovery_start_failed error=${error.message}")
        }
    }

    companion object {
        const val SERVICE_TYPE = "_edgelink._tcp"
        private const val CONNECT_TIMEOUT_MS = 3_000
    }
}
