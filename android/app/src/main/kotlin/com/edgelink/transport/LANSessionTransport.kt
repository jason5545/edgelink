package com.edgelink.transport

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import com.edgelink.app.EdgeLinkLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LANSessionTransport(context: Context) {
    data class Endpoint(val host: String, val port: Int, val resolvedAtMs: Long)

    private val endpointCache = LanEndpointCache()
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    @Volatile
    private var activeNetworkKey: String? = null

    @Volatile
    private var networkCallbackRegistered = false

    // NSD stopServiceDiscovery is asynchronous: discoverServices on the same
    // listener before onDiscoveryStopped throws "listener already in use",
    // which used to leave discovery dead until the next network change (live
    // 2026-08-10: LAN control never came up after 22:25). All transitions are
    // serialized through discoveryState; retries run on a single-thread
    // scheduler with backoff, plus a watchdog that revives a silently dead
    // discovery whenever LAN control is desired.
    private enum class DiscoveryState { IDLE, STARTING, ACTIVE, STOPPING }

    private val discoveryLock = Any()
    private var discoveryState = DiscoveryState.IDLE
    private var discoveryDesired = false
    private var startPendingAfterStop = false
    private var startRetryAttempt = 0
    private val retryScheduler = Executors.newSingleThreadScheduledExecutor()

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            EdgeLinkLog.warn("lan.android.discovery_failed error=$errorCode")
            // NSD requires a stop after start-failure before the listener is
            // reusable. If that stop itself throws, drop straight to IDLE so
            // the retry can start fresh instead of wedging in STOPPING.
            synchronized(discoveryLock) {
                discoveryState = DiscoveryState.STOPPING
                startPendingAfterStop = true
            }
            runCatching { nsdManager.stopServiceDiscovery(this) }
                .onFailure {
                    synchronized(discoveryLock) {
                        discoveryState = DiscoveryState.IDLE
                    }
                }
            scheduleStartRetry("start_failed_$errorCode")
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            // The listener is wedged; treat it as stopped so the state
            // machine can try a fresh start instead of staying stuck.
            EdgeLinkLog.warn("lan.android.discovery_stop_failed error=$errorCode")
            synchronized(discoveryLock) {
                discoveryState = DiscoveryState.IDLE
                if (startPendingAfterStop) {
                    startPendingAfterStop = false
                    startDiscoveryLocked("stop_failed_recover")
                }
            }
        }

        override fun onDiscoveryStarted(serviceType: String) {
            synchronized(discoveryLock) {
                discoveryState = DiscoveryState.ACTIVE
                startRetryAttempt = 0
            }
            EdgeLinkLog.info("lan.android.discovery_started type=$serviceType")
        }

        override fun onDiscoveryStopped(serviceType: String) {
            synchronized(discoveryLock) {
                discoveryState = DiscoveryState.IDLE
                if (startPendingAfterStop) {
                    startPendingAfterStop = false
                    startDiscoveryLocked("restart_after_stop")
                }
            }
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    EdgeLinkLog.warn("lan.android.resolve_failed error=$errorCode")
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    val candidates = resolveCandidates(info)
                    val host = selectPreferredAddress(candidates) ?: return
                    endpointCache.put(host, info.port, currentNetworkKey())
                    EdgeLinkLog.info(
                        "lan.android.endpoint_found host=$host port=${info.port} " +
                            "name=${info.serviceName} candidates=${candidates.joinToString(",")}"
                    )
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
        synchronized(discoveryLock) {
            discoveryDesired = true
            startDiscoveryLocked("start_discovery")
        }
        retryScheduler.scheduleWithFixedDelay(
            {
                synchronized(discoveryLock) {
                    if (discoveryDesired && discoveryState == DiscoveryState.IDLE) {
                        EdgeLinkLog.warn("lan.android.discovery_watchdog_restart")
                        startDiscoveryLocked("watchdog")
                    }
                }
            },
            DISCOVERY_WATCHDOG_INTERVAL_MS,
            DISCOVERY_WATCHDOG_INTERVAL_MS,
            TimeUnit.MILLISECONDS
        )
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
        synchronized(discoveryLock) {
            restartDiscoveryLocked("network_changed")
        }
    }

    // Caller must hold discoveryLock.
    private fun startDiscoveryLocked(reason: String) {
        if (!discoveryDesired) {
            return
        }
        when (discoveryState) {
            DiscoveryState.IDLE -> {
                discoveryState = DiscoveryState.STARTING
                runCatching {
                    nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
                }.onFailure { error ->
                    discoveryState = DiscoveryState.IDLE
                    EdgeLinkLog.warn(
                        "lan.android.discovery_start_failed reason=$reason error=${error.message}"
                    )
                    scheduleStartRetry("start_threw")
                }
            }
            DiscoveryState.STARTING, DiscoveryState.ACTIVE -> Unit
            DiscoveryState.STOPPING -> startPendingAfterStop = true
        }
    }

    // Caller must hold discoveryLock.
    private fun restartDiscoveryLocked(reason: String) {
        when (discoveryState) {
            DiscoveryState.IDLE -> startDiscoveryLocked(reason)
            DiscoveryState.STARTING -> {
                // A start is already in flight; let it finish. The watchdog
                // covers a start that never completes.
            }
            DiscoveryState.ACTIVE -> {
                discoveryState = DiscoveryState.STOPPING
                startPendingAfterStop = true
                runCatching { nsdManager.stopServiceDiscovery(discoveryListener) }
                    .onFailure {
                        discoveryState = DiscoveryState.IDLE
                        startDiscoveryLocked("stop_threw")
                    }
            }
            DiscoveryState.STOPPING -> startPendingAfterStop = true
        }
    }

    private fun scheduleStartRetry(trigger: String) {
        val attempt = synchronized(discoveryLock) {
            startRetryAttempt = (startRetryAttempt + 1).coerceAtMost(MAX_START_RETRY_ATTEMPT)
            startRetryAttempt
        }
        val delayMs = (START_RETRY_BASE_MS shl (attempt - 1)).coerceAtMost(START_RETRY_MAX_MS)
        EdgeLinkLog.info("lan.android.discovery_start_retry trigger=$trigger attempt=$attempt delayMs=$delayMs")
        retryScheduler.schedule({
            synchronized(discoveryLock) {
                if (discoveryDesired && discoveryState == DiscoveryState.IDLE) {
                    startDiscoveryLocked("retry_$attempt")
                }
            }
        }, delayMs, TimeUnit.MILLISECONDS)
    }

    companion object {
        const val SERVICE_TYPE = "_edgelink._tcp"
        private const val CONNECT_TIMEOUT_MS = 3_000
        private const val START_RETRY_BASE_MS = 1_000L
        private const val START_RETRY_MAX_MS = 30_000L
        private const val MAX_START_RETRY_ATTEMPT = 8
        private const val DISCOVERY_WATCHDOG_INTERVAL_MS = 10_000L

        // Visible for tests: pick the address the phone should dial. Prefer
        // routable IPv4 (the Mac's Wi-Fi address); link-local IPv6 needs a
        // scope id and has proven flaky through NSD.
        fun selectPreferredAddress(candidates: List<InetAddress>): String? {
            fun rank(address: InetAddress): Int = when {
                address is Inet4Address && !address.isLinkLocalAddress -> 0
                address is Inet4Address -> 1
                !address.isLinkLocalAddress -> 2
                else -> 3
            }
            return candidates.minByOrNull(::rank)?.hostAddress
        }

        fun resolveCandidates(info: NsdServiceInfo): List<InetAddress> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                info.hostAddresses
            } else {
                listOfNotNull(info.host)
            }
    }
}
