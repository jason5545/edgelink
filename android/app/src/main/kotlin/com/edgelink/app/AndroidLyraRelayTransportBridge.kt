package com.edgelink.app

import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.RelayDatagram
import com.edgelink.core.RelayDatagramBody
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress

/**
 * Phone-side relay transport bridge.
 *
 * Carries the phone's native Xiaomi mesh + channel datagrams over the EdgeLink
 * E2EE relay session so the Mac's production announce / relayCall / cast logic
 * runs unchanged when the phone is only reachable through the cloud relay.
 *
 * Semantics mirror the Mac `LyraRelayTransportBridge` + the fake-phone roles
 * (`LyraPhoneMeshServer` / `LyraRelayCallRole` / `LyraCastRole`): indexed
 * mesh flows + one channel flow per peer, ordered datagrams, KCP sn/una +
 * acks preserved. Each mesh flow index binds its own UDP socket, so the
 * phone's Xiaomi mesh service sees a distinct peer per flow — the announce /
 * relayCall dial (flow 0) and the cast trust dial (flow 1) each get a fresh
 * source port, exactly like separate LAN sockets. The bridge relays
 * datagrams verbatim between the relay session and the phone's local Xiaomi
 * endpoints (mesh service / cast channel); it does not terminate KCP — the
 * real Xiaomi service on the phone does.
 *
 * When the relay session is down, the Mac reaches these endpoints over LAN
 * directly (the existing path); this bridge is only active while connected via
 * relay.
 */
class AndroidLyraRelayTransportBridge(
    private val scope: CoroutineScope,
    private val sendEnvelope: suspend (String, Any) -> Unit,
    private val log: (String) -> Unit = { EdgeLinkLog.info(it) },
    // Fired (once per target) when a mesh flow's target produces its first
    // inbound datagram — the controller persists it as the known-good mesh
    // port and prefers it on later dials.
    private val onMeshTargetResponsive: (Int) -> Unit = {}
) {
    private val lock = Any()
    private var meshTarget: Pair<String, Int>? = null
    private var meshProbePorts: List<Int> = emptyList()
    private val meshFlows = HashMap<Int, DatagramFlow>()
    // Cast flow indexes retired by the fresh-dial replacement in meshFlow().
    // Late datagrams of a dead dial (relay reordering) must not recreate its
    // flow — the recreation would kill the LIVE dial's socket, and the two
    // dials' interleaved envelopes then kill each other in a loop (live
    // 2026-08-09: flows 480906435/735712576 flip-flopped within 300ms).
    private val retiredCastFlowIndexes = ArrayDeque<Int>()
    private val channelFlow = DatagramFlow(EnvelopeTypes.RELAY_CHANNEL_DATAGRAM, 0, scope, ::emitDatagram, log)

    // Per-flow traffic counters for the wrong-port watchdog: a cast dial
    // (flow 1) with outbound datagrams but zero inbound means the mesh target
    // is a dead endpoint (e.g. the Mirror app's socket, not the mesh service).
    data class MeshFlowStats(val flowIndex: Int, val outboundCount: Long, val inboundCount: Long)

    companion object {
        fun handles(type: String): Boolean =
            type == EnvelopeTypes.RELAY_MESH_DATAGRAM || type == EnvelopeTypes.RELAY_CHANNEL_DATAGRAM
    }

    suspend fun handleEnvelope(type: String, body: JsonObject) {
        val relayBody = runCatching {
            EnvelopeCodec.json.decodeFromJsonElement<RelayDatagramBody>(body)
        }.getOrNull() ?: return
        val data = RelayDatagram.decode(relayBody) ?: return
        val index = relayBody.f ?: 0
        when (type) {
            EnvelopeTypes.RELAY_MESH_DATAGRAM -> meshFlow(index, ensureStarted = true)?.deliver(data)
            EnvelopeTypes.RELAY_CHANNEL_DATAGRAM -> {
                // The Mac stamps the Xiaomi channel port it dialed ("p") onto
                // channel envelopes; bind (or rebind, when the cast channel
                // port differs from the relayCall one) before delivering.
                val port = relayBody.p
                if (port != null) channelFlow.startOrRebind("127.0.0.1", port)
                channelFlow.deliver(data)
            }
        }
    }

    // Binds a mesh flow to the phone's local Xiaomi mesh endpoint. Called when
    // the relay session is up and the mesh port is known (milink status). The
    // target is remembered so later flows (the cast dial on flow 1) can start
    // lazily when their first datagram arrives. Flows that buffered datagrams
    // while the target was unknown start now.
    fun startMesh(host: String, port: Int, index: Int = 0) {
        val pendingFlows = synchronized(lock) {
            meshTarget = host to port
            meshFlows.values.filter { it.hasPending }
        }
        meshFlow(index, ensureStarted = false)?.start(host, port)
        pendingFlows.forEach { it.start(host, port) }
    }

    // Wrong-port recovery: retarget every mesh flow at once.
    fun rebindMesh(host: String, port: Int) {
        val flows = synchronized(lock) {
            meshTarget = host to port
            meshFlows.values.toList()
        }
        log("xiaomi.relaybridge.android.mesh_rebind target=$host:$port flows=${flows.size}")
        flows.forEach { it.startOrRebind(host, port) }
    }

    fun meshFlowStats(): List<MeshFlowStats> = synchronized(lock) {
        meshFlows.map { (index, flow) ->
            MeshFlowStats(index, flow.outboundCount, flow.inboundCount)
        }
    }

    // Candidate mesh ports for the unlocked dial (probe fan-out). Ordered by
    // preference (last-responsive first); the flow dials all of them until
    // one answers.
    fun setMeshProbePorts(ports: List<Int>) = synchronized(lock) {
        meshProbePorts = ports
        meshFlows.values.forEach { it.setProbePorts(ports) }
    }

    // Binds the channel flow to the phone's cast channel endpoint (from the
    // cast negotiation).
    fun startChannel(host: String, port: Int) = channelFlow.start(host, port)

    fun stop() {
        synchronized(lock) {
            meshFlows.values.forEach { it.stop() }
            meshFlows.clear()
            meshTarget = null
        }
        channelFlow.stop()
    }

    private fun meshFlow(index: Int, ensureStarted: Boolean): DatagramFlow? = synchronized(lock) {
        if (index != 0 && !meshFlows.containsKey(index)) {
            if (retiredCastFlowIndexes.contains(index)) {
                // Zombie datagram of an already-replaced cast dial: drop it.
                return null
            }
            // A previously unseen non-zero flow index is a fresh cast dial:
            // the Mac randomizes the index per session because the Xiaomi
            // mesh service ignores phys sync from a source endpoint it has
            // seen before. Each flow owns one UDP socket (= one peer), so
            // the previous cast flows' sockets must be dropped, not reused
            // (live 2026-08-08: redials on the reused flow-1 socket got only
            // KCP ACKs, never a phys sync reply).
            val stale = meshFlows.keys.filter { it != 0 }
            stale.forEach { meshFlows.remove(it)?.stop() }
            if (stale.isNotEmpty()) {
                retiredCastFlowIndexes.addAll(stale)
                while (retiredCastFlowIndexes.size > 8) retiredCastFlowIndexes.removeFirst()
                log("xiaomi.relaybridge.android.cast_flow_replaced stale=$stale new=$index")
            }
        }
        val flow = meshFlows.getOrPut(index) {
            DatagramFlow(EnvelopeTypes.RELAY_MESH_DATAGRAM, index, scope, ::emitDatagram, log) { port ->
                onMeshTargetResponsive(port)
            }.also { it.setProbePorts(meshProbePorts) }
        }
        if (ensureStarted) {
            val target = meshTarget
            if (target != null) flow.start(target.first, target.second)
        }
        flow
    }

    private suspend fun emitDatagram(type: String, flow: Int, datagram: ByteArray) {
        sendEnvelope(type, RelayDatagram.encode(datagram, flow))
    }

    /**
     * A single datagram flow bound to one local Xiaomi endpoint. Each flow
     * owns its UDP socket (distinct source port), so the phone's mesh service
     * treats each flow index as a separate peer. Datagrams arriving from the
     * relay are written to the endpoint in order; responses from the endpoint
     * are emitted back over the relay in order, tagged with the flow index.
     */
    private class DatagramFlow(
        private val envelopeType: String,
        private val flowIndex: Int,
        private val scope: CoroutineScope,
        private val emit: suspend (String, Int, ByteArray) -> Unit,
        private val log: (String) -> Unit,
        private val onResponsive: (Int) -> Unit = {}
    ) {
        private var socket: DatagramSocket? = null
        private var targetHost: String? = null
        private var targetPort: Int = 0
        private var receiveJob: Job? = null
        private var sendJob: Job? = null
        @Volatile
        var inboundCount: Long = 0
            private set
        @Volatile
        var outboundCount: Long = 0
            private set
        private var responsiveReported = false
        // Candidate-port probing: until the target produces inbound traffic
        // (locked), outbound datagrams are fanned out to every candidate port
        // over per-port probe sockets. The first port that answers wins: its
        // probe socket (and its source port, which the answering service now
        // keys the peer session on) is promoted to the flow's main socket.
        // Replaces blind timed rotation — the Lyra probe list mixes every
        // Lyra process's sockets (all share android.uid.system) and only one
        // of them is the real mesh dial.
        private var probePorts: List<Int> = emptyList()
        private val probeSockets = HashMap<Int, DatagramSocket>()
        private val probeJobs = HashMap<Int, Job>()
        private var lockedToTarget = false
        // Relay -> local writes are serialized to preserve KCP segment order.
        private val outbound = Channel<ByteArray>(Channel.UNLIMITED)
        // Datagrams that arrived before the flow had a target (relay session
        // reconnects before the milink status re-announces the mesh port) —
        // buffered instead of dropped, flushed on start, so the peer's
        // handshake survives the startup window.
        private val pending = ArrayDeque<ByteArray>()
        private var pendingDropped = 0

        companion object {
            const val PENDING_CAPACITY = 64
            // Lyra KCP segment command offset/values (header: conv4 cmd1 …).
            private const val KCP_COMMAND_OFFSET = 4
            private const val KCP_COMMAND_PUSH: Byte = 0x51

            fun isLyraDataSegment(data: ByteArray, offset: Int, length: Int): Boolean =
                length > KCP_COMMAND_OFFSET && data[offset + KCP_COMMAND_OFFSET] == KCP_COMMAND_PUSH
        }

        val hasPending: Boolean
            @Synchronized get() = socket == null && pending.isNotEmpty()

        @Synchronized
        fun setProbePorts(ports: List<Int>) {
            if (lockedToTarget) return
            probePorts = ports.filter { it != targetPort }
            val stale = probeSockets.keys.filter { it !in probePorts }
            stale.forEach { port ->
                probeJobs.remove(port)?.cancel()
                try { probeSockets.remove(port)?.close() } catch (_: Exception) {}
            }
        }

        @Synchronized
        fun start(host: String, port: Int) {
            if (socket != null) return
            val sock = try {
                DatagramSocket(null).apply {
                    reuseAddress = true
                    bind(null)
                    connect(InetSocketAddress(host, port))
                }
            } catch (e: Exception) {
                log("xiaomi.relaybridge.android.flow_bind_failed type=$envelopeType flow=$flowIndex error=${e.message}")
                return
            }
            socket = sock
            targetHost = host
            targetPort = port
            responsiveReported = false
            sendJob = scope.launch(Dispatchers.IO) { drainOutbound(sock) }
            receiveJob = scope.launch(Dispatchers.IO) { receiveLoop(sock, port, isProbe = false) }
            flushPendingLocked()
            log(
                "xiaomi.relaybridge.android.flow_started type=$envelopeType flow=$flowIndex " +
                    "target=$host:$port localPort=${sock.localPort}"
            )
        }

        private fun flushPendingLocked() {
            val buffered = pending.size
            val dropped = pendingDropped
            pendingDropped = 0
            while (pending.isNotEmpty()) {
                outbound.trySend(pending.removeFirst())
            }
            if (buffered > 0 || dropped > 0) {
                log(
                    "xiaomi.relaybridge.android.flow_flush type=$envelopeType flow=$flowIndex " +
                        "buffered=$buffered dropped=$dropped"
                )
            }
        }

        // Like start(), but retargets a running flow when the peer dialed a
        // different local port (relayCall vs cast channel listeners).
        @Synchronized
        fun startOrRebind(host: String, port: Int) {
            if (socket != null && targetPort == port) return
            stopLocked(keepTarget = true)
            start(host, port)
        }

        fun deliver(datagram: ByteArray) {
            val restartTarget: Pair<String, Int>? = synchronized(this) {
                if (socket != null && lockedToTarget) {
                    outbound.trySend(datagram)
                    null
                } else if (!lockedToTarget && probePorts.isNotEmpty()) {
                    // Unlocked: fan this datagram out to every candidate port
                    // (the main socket covers the first candidate). The first
                    // responder promotes its socket to the flow.
                    ensureProbesLocked()
                    for (sock in probeSockets.values) {
                        try {
                            sock.send(DatagramPacket(datagram, datagram.size))
                            outboundCount++
                        } catch (e: Exception) {
                            log("xiaomi.relaybridge.android.flow_probe_send_failed type=$envelopeType flow=$flowIndex error=${e.message}")
                        }
                    }
                    if (socket != null) {
                        outbound.trySend(datagram)
                    }
                    null
                } else if (socket != null) {
                    outbound.trySend(datagram)
                    null
                } else {
                    if (pending.size >= PENDING_CAPACITY) {
                        pending.removeFirst()
                        pendingDropped++
                        log(
                            "xiaomi.relaybridge.android.flow_pending_overflow type=$envelopeType " +
                                "flow=$flowIndex dropped=$pendingDropped"
                        )
                    }
                    pending.addLast(datagram)
                    val host = targetHost
                    if (host != null && targetPort != 0) host to targetPort else null
                }
            }
            // Self-heal: the previous socket died (send/recv failure) — rebind
            // against the remembered target, flushing the buffered datagrams.
            if (restartTarget != null) {
                start(restartTarget.first, restartTarget.second)
            }
        }

        private fun ensureProbesLocked() {
            val host = targetHost ?: "127.0.0.1"
            for (port in probePorts) {
                if (probeSockets.containsKey(port)) continue
                val sock = try {
                    DatagramSocket(null).apply {
                        reuseAddress = true
                        bind(null)
                        connect(InetSocketAddress(host, port))
                    }
                } catch (e: Exception) {
                    log("xiaomi.relaybridge.android.flow_probe_bind_failed type=$envelopeType flow=$flowIndex port=$port error=${e.message}")
                    continue
                }
                probeSockets[port] = sock
                probeJobs[port] = scope.launch(Dispatchers.IO) { receiveLoop(sock, port, isProbe = true) }
            }
        }

        // The winning probe becomes the flow's main socket — same source port,
        // so the answering service keeps the peer session it just created.
        private fun promoteProbeLocked(winnerPort: Int) {
            val winner = probeSockets.remove(winnerPort) ?: return
            val winnerJob = probeJobs.remove(winnerPort)
            for ((port, sock) in probeSockets) {
                probeJobs[port]?.cancel()
                try { sock.close() } catch (_: Exception) {}
            }
            probeSockets.clear()
            probeJobs.clear()
            try { socket?.close() } catch (_: Exception) {}
            sendJob?.cancel()
            socket = winner
            if (targetHost == null) targetHost = "127.0.0.1"
            targetPort = winnerPort
            lockedToTarget = true
            receiveJob = winnerJob
            sendJob = scope.launch(Dispatchers.IO) { drainOutbound(winner) }
            flushPendingLocked()
            if (!responsiveReported) {
                responsiveReported = true
                onResponsive(winnerPort)
            }
            log(
                "xiaomi.relaybridge.android.flow_probe_locked type=$envelopeType flow=$flowIndex " +
                    "target=${targetHost}:$winnerPort localPort=${winner.localPort}"
            )
        }

        @Synchronized
        fun stop() {
            stopLocked(keepTarget = false)
        }

        // Socket death: tear the flow down but keep the target so the next
        // deliver() rebinds (the relay session outlives local socket errors).
        private fun handleSocketDeath(dead: DatagramSocket) {
            synchronized(this) {
                if (socket === dead) {
                    stopLocked(keepTarget = true)
                } else {
                    val port = probeSockets.entries.firstOrNull { it.value === dead }?.key
                    if (port != null) {
                        probeJobs.remove(port)?.cancel()
                        probeSockets.remove(port)
                        try { dead.close() } catch (_: Exception) {}
                    }
                }
            }
        }

        private fun stopLocked(keepTarget: Boolean) {
            receiveJob?.cancel()
            sendJob?.cancel()
            receiveJob = null
            sendJob = null
            for ((port, job) in probeJobs) {
                job.cancel()
                try { probeSockets[port]?.close() } catch (_: Exception) {}
            }
            probeJobs.clear()
            probeSockets.clear()
            try { socket?.close() } catch (_: Exception) {}
            socket = null
            lockedToTarget = false
            if (!keepTarget) {
                targetHost = null
                targetPort = 0
            }
        }

        private suspend fun drainOutbound(sock: DatagramSocket) {
            for (datagram in outbound) {
                if (!scope.coroutineContext.isActive) break
                try {
                    sock.send(DatagramPacket(datagram, datagram.size))
                    outboundCount++
                } catch (e: Exception) {
                    log("xiaomi.relaybridge.android.flow_send_failed type=$envelopeType flow=$flowIndex error=${e.message}")
                    handleSocketDeath(sock)
                    break
                }
            }
        }

        private suspend fun receiveLoop(sock: DatagramSocket, port: Int, isProbe: Boolean) {
            val buffer = ByteArray(65_535)
            while (scope.coroutineContext.isActive) {
                val packet = DatagramPacket(buffer, buffer.size)
                val read = try {
                    sock.receive(packet)
                    packet.length
                } catch (_: Exception) {
                    handleSocketDeath(sock)
                    break
                }
                if (read <= 0) continue
                inboundCount++
                // A bare KCP ACK only proves some Lyra service listens on
                // the port — the real mesh dial answers phys sync with a
                // DATA segment. Locking onto an ACK-only port strands the
                // cast dial (live 2026-08-09: ports 37067/56666/57777 ACKed
                // and won the probe; phys sync was never answered).
                val isData = envelopeType != EnvelopeTypes.RELAY_MESH_DATAGRAM ||
                    isLyraDataSegment(packet.data, packet.offset, read)
                val promote = synchronized(this) {
                    if (!lockedToTarget && probeSockets[port] === sock) {
                        if (isData) {
                            promoteProbeLocked(port)
                            true
                        } else {
                            false
                        }
                    } else {
                        if (!isProbe && !responsiveReported && isData) {
                            responsiveReported = true
                            lockedToTarget = true
                            val current = targetPort
                            if (current != 0) onResponsive(current)
                        }
                        false
                    }
                }
                if (promote) {
                    log("xiaomi.relaybridge.android.flow_probe_winner type=$envelopeType flow=$flowIndex port=$port")
                }
                val datagram = packet.data.copyOfRange(packet.offset, packet.offset + read)
                try {
                    emit(envelopeType, flowIndex, datagram)
                } catch (e: Exception) {
                    log("xiaomi.relaybridge.android.flow_emit_failed type=$envelopeType flow=$flowIndex error=${e.message}")
                }
            }
        }
    }
}
