package com.edgelink.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import com.edgelink.app.EdgeLinkLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.EOFException
import java.net.InetSocketAddress
import java.net.Socket

class LANSessionTransport(context: Context) {
    data class Endpoint(val host: String, val port: Int, val resolvedAtMs: Long)

    @Volatile
    private var endpoint: Endpoint? = null

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
                    endpoint = Endpoint(host, info.port, System.currentTimeMillis())
                    EdgeLinkLog.info("lan.android.endpoint_found host=$host port=${info.port} name=${info.serviceName}")
                }
            })
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            EdgeLinkLog.info("lan.android.endpoint_lost name=${serviceInfo.serviceName}")
            endpoint = null
        }
    }

    fun startDiscovery() {
        runCatching {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        }.onFailure { error ->
            EdgeLinkLog.warn("lan.android.discovery_start_failed error=${error.message}")
        }
    }

    fun currentEndpoint(): Endpoint? = endpoint

    suspend fun connect(host: String, port: Int): ByteChannel = withContext(Dispatchers.IO) {
        val socket = Socket()
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        EdgeLinkLog.info("lan.android.transport_connected host=$host port=$port")
        LANTCPByteChannel(socket, host, port)
    }

    private class LANTCPByteChannel(
        private val socket: Socket,
        private val host: String,
        private val port: Int
    ) : ByteChannel {
        private val input = DataInputStream(socket.getInputStream())
        private val output = socket.getOutputStream()
        private val sendLock = Any()

        override suspend fun send(bytes: ByteArray) = withContext(Dispatchers.IO) {
            synchronized(sendLock) {
                output.write(bytes.size shr 24 and 0xFF)
                output.write(bytes.size shr 16 and 0xFF)
                output.write(bytes.size shr 8 and 0xFF)
                output.write(bytes.size and 0xFF)
                output.write(bytes)
                output.flush()
            }
        }

        override suspend fun receive(): ByteArray? = withContext(Dispatchers.IO) {
            try {
                val length = input.readInt()
                if (length < 0 || length > MAX_FRAME_BYTES) {
                    EdgeLinkLog.warn("lan.android.frame_invalid host=$host port=$port length=$length")
                    close()
                    return@withContext null
                }
                val payload = ByteArray(length)
                input.readFully(payload)
                payload
            } catch (error: EOFException) {
                null
            } catch (error: Throwable) {
                EdgeLinkLog.info("lan.android.receive_ended host=$host port=$port error=${error.javaClass.simpleName}")
                null
            }
        }

        override fun close() {
            runCatching { socket.close() }
        }
    }

    companion object {
        const val SERVICE_TYPE = "_edgelink._tcp"
        private const val CONNECT_TIMEOUT_MS = 3_000
        private const val MAX_FRAME_BYTES = 4 * 1024 * 1024
    }
}
