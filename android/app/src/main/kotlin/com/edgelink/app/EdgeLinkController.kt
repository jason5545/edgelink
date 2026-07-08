package com.edgelink.app

import android.content.Context
import android.os.Build
import com.edgelink.core.ClipboardSetBody
import com.edgelink.core.DeviceId
import com.edgelink.core.EmptyBody
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.InputKeyBody
import com.edgelink.core.InputPointerBody
import com.edgelink.core.InputTextBody
import com.edgelink.core.LocalIdentity
import com.edgelink.core.PairConfirmRequest
import com.edgelink.core.Pairing
import com.edgelink.core.PairingTypes
import com.edgelink.core.PairingWire
import com.edgelink.core.PinnedPeer
import com.edgelink.core.SodiumHandshakeCrypto
import com.edgelink.core.WorkerDeviceRegistrar
import com.edgelink.transport.PairingTransport
import com.edgelink.transport.RelayTransport
import com.edgelink.transport.SecureSessionClient
import com.edgelink.ui.EdgeLinkActions
import com.edgelink.ui.EdgeLinkUiState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext
import java.time.Instant
import java.util.Base64

class EdgeLinkController(context: Context) : EdgeLinkActions {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val crypto = SodiumHandshakeCrypto()
    private val identityStore = SharedPreferencesIdentityStore(appContext)
    private val pairingStore = SharedPreferencesPairingStore(appContext)
    private val registrar = WorkerDeviceRegistrar(EdgeLinkConfig.workerBaseUrl)
    private val relayTransport = RelayTransport(crypto = crypto)
    private val pairingTransport = PairingTransport()
    private val clipboardSync = AndroidClipboardSync(appContext)
    private val stateFlow = MutableStateFlow(EdgeLinkUiState())
    private val dispatcher = AndroidCommandDispatcher(clipboardSync) {
        stateFlow.update { it.copy(connectionStatus = "Connected") }
    }

    val state: StateFlow<EdgeLinkUiState> = stateFlow

    @Volatile
    private var session: SecureSessionClient? = null
    private var localIdentity: LocalIdentity? = null
    private var pairingJob: Job? = null
    private var pendingPairing: PendingPairing? = null

    init {
        EdgeLinkLog.configure(appContext)
        scope.launch {
            run()
        }
    }

    fun close() {
        scope.cancel()
    }

    override fun onPointer(body: InputPointerBody) {
        sendEnvelope(EnvelopeTypes.INPUT_POINTER, body)
    }

    override fun onKey(body: InputKeyBody) {
        sendEnvelope(EnvelopeTypes.INPUT_KEY, body)
    }

    override fun onText(body: InputTextBody) {
        sendEnvelope(EnvelopeTypes.INPUT_TEXT, body)
    }

    override fun onPairDigit(digit: String) {
        stateFlow.update {
            if (it.pairingHostIdInput.length >= 9 || it.canConfirmPairing) {
                it
            } else {
                it.copy(pairingHostIdInput = it.pairingHostIdInput + digit)
            }
        }
    }

    override fun onPairBackspace() {
        stateFlow.update {
            if (it.pairingHostIdInput.isEmpty() || it.canConfirmPairing) {
                it
            } else {
                it.copy(pairingHostIdInput = it.pairingHostIdInput.dropLast(1))
            }
        }
    }

    override fun onStartPairing() {
        val hostId = stateFlow.value.pairingHostIdInput
        EdgeLinkLog.info("pair.android.start requested hostId=$hostId")
        if (!DeviceId.isValid(hostId)) {
            EdgeLinkLog.warn("pair.android.start invalid_host_id hostId=$hostId")
            stateFlow.update { it.copy(connectionStatus = "Invalid Mac ID") }
            return
        }
        pairingJob?.cancel()
        pairingJob = scope.launch {
            runPairing(hostId)
        }
    }

    override fun onConfirmPairing() {
        val pending = pendingPairing ?: return
        EdgeLinkLog.info("pair.android.confirm click hostId=${pending.hostId} clientId=${pending.clientId}")
        scope.launch {
            runCatching {
                pairingTransport.confirm(EdgeLinkConfig.workerBaseUrl, pending.confirmRequest())
            }.onSuccess {
                EdgeLinkLog.info("pair.android.confirm sent hostId=${pending.hostId} clientId=${pending.clientId}")
                stateFlow.update { it.copy(canConfirmPairing = false, connectionStatus = "Waiting for Mac") }
            }.onFailure { error ->
                EdgeLinkLog.error("pair.android.confirm failed hostId=${pending.hostId} clientId=${pending.clientId}", error)
                stateFlow.update { it.copy(connectionStatus = "Pairing failed", isPairing = false, canConfirmPairing = false) }
            }
        }
    }

    private suspend fun run() {
        try {
            stateFlow.update { it.copy(connectionStatus = "Registering") }
            val identity = loadOrRegisterIdentity()
            localIdentity = identity
            stateFlow.update { it.copy(localDeviceId = DeviceId.display(identity.deviceId)) }
            EdgeLinkLog.info("runtime.android.identity deviceId=${identity.deviceId} pkfp=${EdgeLinkLog.fingerprint(identity.publicKey)}")

            val peer = pairingStore.loadPeers().firstOrNull()
            if (peer == null) {
                EdgeLinkLog.info("runtime.android.no_paired_peer")
                stateFlow.update { it.copy(connectionStatus = "No paired Mac") }
                return
            }
            EdgeLinkLog.info("runtime.android.loaded_peer hostId=${peer.deviceId} pkfp=${EdgeLinkLog.fingerprint(peer.publicKey)}")

            stateFlow.update {
                it.copy(
                    peerName = peer.name,
                    peerDeviceId = DeviceId.display(peer.deviceId)
                )
            }
            connectLoop(identity, peer)
        } catch (error: Throwable) {
            EdgeLinkLog.error("runtime.android.setup_failed", error)
            session = null
            stateFlow.update {
                it.copy(connectionStatus = "Setup failed", isConnected = false)
            }
        }
    }

    private suspend fun runPairing(hostId: String) {
        val identity = localIdentity ?: loadOrRegisterIdentity().also { localIdentity = it }
        val nonceC = crypto.randomBytes(32)
        var commitment: ByteArray? = null
        var pairedPeer: PinnedPeer? = null
        EdgeLinkLog.info("pair.android.open hostId=$hostId clientId=${identity.deviceId} clientPkFp=${EdgeLinkLog.fingerprint(identity.publicKey)}")

        stateFlow.update {
            it.copy(
                isPairing = true,
                pairingSas = "",
                pairingPeerName = "",
                canConfirmPairing = false,
                connectionStatus = "Opening pairing"
            )
        }

        val channel = runCatching {
            pairingTransport.connect(EdgeLinkConfig.pairingWebSocketUrl, hostId)
        }.getOrElse { error ->
            EdgeLinkLog.error("pair.android.ws_connect_failed hostId=$hostId", error)
            stateFlow.update { state -> state.copy(connectionStatus = "Pairing failed", isPairing = false) }
            return
        }

        try {
            EdgeLinkLog.info("pair.android.ws_connected hostId=$hostId")
            pairingTransport.claim(EdgeLinkConfig.workerBaseUrl, hostId, identity)
            EdgeLinkLog.info("pair.android.claim_ok hostId=$hostId clientId=${identity.deviceId}")
            channel.send(PairingWire.encodeReady(identity.deviceId))
            EdgeLinkLog.info("pair.android.ready_sent hostId=$hostId clientId=${identity.deviceId}")

            while (coroutineContext.isActive) {
                val text = channel.receive() ?: error("Pairing socket closed.")
                val type = PairingWire.type(text)
                EdgeLinkLog.info("pair.android.message type=$type hostId=$hostId")
                when (type) {
                    PairingTypes.COMMIT -> {
                        commitment = Base64.getDecoder().decode(PairingWire.decodeCommit(text).commit)
                        EdgeLinkLog.info("pair.android.commit_received hostId=$hostId commitFp=${EdgeLinkLog.fingerprint(commitment!!)}")
                        channel.send(PairingWire.encodeRevealClient(identity, nonceC))
                        EdgeLinkLog.info("pair.android.reveal_client_sent hostId=$hostId clientId=${identity.deviceId}")
                    }
                    PairingTypes.REVEAL_HOST -> {
                        val reveal = PairingWire.decodeRevealHost(text)
                        val hostPk = Base64.getDecoder().decode(reveal.hostPk)
                        val nonceH = Base64.getDecoder().decode(reveal.nonceH)
                        val expectedCommitment = Pairing.commitment(hostPk, nonceH)
                        check(commitment?.contentEquals(expectedCommitment) == true) {
                            "Pairing commitment mismatch."
                        }
                        EdgeLinkLog.info("pair.android.commit_verified hostId=${reveal.hostId} hostPkFp=${EdgeLinkLog.fingerprint(hostPk)}")
                        val sas = Pairing.sas(
                            hostPublicKey = hostPk,
                            clientPublicKey = identity.publicKey,
                            hostNonce = nonceH,
                            clientNonce = nonceC
                        )
                        EdgeLinkLog.info("pair.android.sas hostId=${reveal.hostId} clientId=${identity.deviceId} sas=${sas.display}")
                        pendingPairing = PendingPairing(
                            hostId = reveal.hostId,
                            clientId = identity.deviceId,
                            hostPkBase64 = reveal.hostPk,
                            clientPkBase64 = Base64.getEncoder().encodeToString(identity.publicKey),
                            hostName = reveal.name,
                            clientName = identity.name,
                            hostPublicKey = hostPk
                        )
                        stateFlow.update {
                            it.copy(
                                pairingSas = sas.display,
                                pairingPeerName = reveal.name,
                                canConfirmPairing = true,
                                connectionStatus = "Compare code"
                            )
                        }
                    }
                    PairingTypes.COMPLETE -> {
                        val complete = PairingWire.decodeComplete(text)
                        EdgeLinkLog.info("pair.android.complete_received hostId=${complete.hostId} clientId=${complete.clientId}")
                        val pending = pendingPairing
                        if (pending != null && complete.hostId == pending.hostId && complete.clientId == pending.clientId) {
                            val peer = PinnedPeer(
                                deviceId = pending.hostId,
                                name = pending.hostName,
                                publicKey = pending.hostPublicKey,
                                pairedAt = Instant.now()
                            )
                            pairedPeer = peer
                            pairingStore.savePeer(peer)
                            EdgeLinkLog.info("pair.android.peer_saved hostId=${peer.deviceId} pkfp=${EdgeLinkLog.fingerprint(peer.publicKey)}")
                            break
                        } else {
                            EdgeLinkLog.warn("pair.android.complete_mismatch expected=${pending?.hostId}/${pending?.clientId} got=${complete.hostId}/${complete.clientId}")
                        }
                    }
                }
            }
        } catch (error: Throwable) {
            EdgeLinkLog.error("pair.android.failed hostId=$hostId", error)
            stateFlow.update { it.copy(connectionStatus = "Pairing failed", isPairing = false, canConfirmPairing = false) }
        } finally {
            EdgeLinkLog.info("pair.android.ws_close hostId=$hostId")
            channel.close()
        }

        val peer = pairedPeer ?: run {
            EdgeLinkLog.warn("pair.android.no_paired_peer_after_loop hostId=$hostId")
            return
        }
        pendingPairing = null
        stateFlow.update {
            it.copy(
                peerName = peer.name,
                peerDeviceId = DeviceId.display(peer.deviceId),
                pairingHostIdInput = "",
                pairingSas = "",
                pairingPeerName = "",
                isPairing = false,
                canConfirmPairing = false,
                connectionStatus = "Paired"
            )
        }
        EdgeLinkLog.info("pair.android.done hostId=${peer.deviceId} clientId=${identity.deviceId}")
        connectLoop(identity, peer)
    }

    private suspend fun loadOrRegisterIdentity(): LocalIdentity =
        withContext(Dispatchers.IO) {
            identityStore.loadIdentity()?.let {
                EdgeLinkLog.info("runtime.android.identity_loaded deviceId=${it.deviceId}")
                return@withContext it
            }

            val seed = crypto.randomSeed()
            val keyPair = crypto.ed25519KeyPairFromSeed(seed)
            val name = listOf(Build.MANUFACTURER, Build.MODEL)
                .filter { it.isNotBlank() }
                .joinToString(" ")
                .ifBlank { "Android" }
            val deviceId = registrar.register(
                publicKey = keyPair.publicKey,
                name = name,
                platform = "android"
            )
            EdgeLinkLog.info("runtime.android.identity_registered deviceId=$deviceId name=$name pkfp=${EdgeLinkLog.fingerprint(keyPair.publicKey)}")
            LocalIdentity(
                deviceId = deviceId,
                name = name,
                publicKey = keyPair.publicKey,
                privateKeySeed = seed
            ).also(identityStore::saveIdentity)
        }

    private suspend fun connectLoop(identity: LocalIdentity, peer: PinnedPeer) {
        var retryDelayMs = 1_000L

        while (coroutineContext.isActive) {
            try {
                EdgeLinkLog.info("relay.android.connect_start hostId=${peer.deviceId} clientId=${identity.deviceId}")
                stateFlow.update { it.copy(connectionStatus = "Connecting relay", isConnected = false) }
                val channel = relayTransport.connect(
                    relayUrl = EdgeLinkConfig.relayUrl,
                    hostId = peer.deviceId,
                    identity = identity
                )
                val nextSession = SecureSessionClient(
                    channel = channel,
                    identity = identity,
                    peer = peer,
                    crypto = crypto
                )

                stateFlow.update { it.copy(connectionStatus = "Handshaking") }
                nextSession.connect()
                EdgeLinkLog.info("relay.android.handshake_ok hostId=${peer.deviceId} clientId=${identity.deviceId}")
                session = nextSession
                retryDelayMs = 1_000L
                stateFlow.update { it.copy(connectionStatus = "Connected", isConnected = true) }

                coroutineScope {
                    val pingJob = launch { pingLoop(nextSession) }
                    val clipboardJob = launch { clipboardLoop(nextSession) }
                    try {
                        nextSession.receiveLoop(dispatcher::handle)
                    } finally {
                        pingJob.cancelAndJoin()
                        clipboardJob.cancelAndJoin()
                    }
                }
            } catch (error: Throwable) {
                EdgeLinkLog.error("relay.android.disconnected hostId=${peer.deviceId} clientId=${identity.deviceId}", error)
                session = null
                stateFlow.update { it.copy(connectionStatus = "Disconnected", isConnected = false) }
                delay(retryDelayMs)
                retryDelayMs = (retryDelayMs * 2).coerceAtMost(30_000L)
            }
        }
    }

    private suspend fun pingLoop(activeSession: SecureSessionClient) {
        while (coroutineContext.isActive) {
            activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.STATUS_PING, EmptyBody))
            delay(5_000)
        }
    }

    private suspend fun clipboardLoop(activeSession: SecureSessionClient) {
        while (coroutineContext.isActive) {
            val snapshot = clipboardSync.pollLocalText()
            if (snapshot != null) {
                activeSession.sendPlaintext(
                    EnvelopeCodec.encode(
                        EnvelopeTypes.CLIPBOARD_SET,
                        ClipboardSetBody(
                            text = snapshot.text,
                            ts = snapshot.timestampSeconds,
                            hash = snapshot.hash
                        )
                    )
                )
            }
            delay(700)
        }
    }

    private inline fun <reified T> sendEnvelope(type: String, body: T) {
        val activeSession = session ?: return
        scope.launch(Dispatchers.IO) {
            runCatching {
                activeSession.sendPlaintext(EnvelopeCodec.encode(type, body))
            }
        }
    }
}

private class AndroidCommandDispatcher(
    private val clipboardSync: AndroidClipboardSync,
    private val onPong: () -> Unit
) {
    suspend fun handle(plaintext: ByteArray): ByteArray? {
        return when (EnvelopeCodec.type(plaintext)) {
            EnvelopeTypes.STATUS_PING -> EnvelopeCodec.encode(EnvelopeTypes.STATUS_PONG, EmptyBody)
            EnvelopeTypes.STATUS_PONG -> {
                onPong()
                null
            }
            EnvelopeTypes.CLIPBOARD_SET -> {
                val envelope = EnvelopeCodec.decode<ClipboardSetBody>(plaintext)
                clipboardSync.applyRemoteText(envelope.b.text, envelope.b.hash)
                null
            }
            else -> null
        }
    }
}

object EdgeLinkConfig {
    const val workerBaseUrl = "https://edgelink-worker.black-hill-f944.workers.dev"
    const val relayUrl = "wss://edgelink-worker.black-hill-f944.workers.dev/v1/connect"
    const val pairingWebSocketUrl = "wss://edgelink-worker.black-hill-f944.workers.dev/v1/pair/ws"
}

private data class PendingPairing(
    val hostId: String,
    val clientId: String,
    val hostPkBase64: String,
    val clientPkBase64: String,
    val hostName: String,
    val clientName: String,
    val hostPublicKey: ByteArray
) {
    fun confirmRequest(): PairConfirmRequest =
        PairConfirmRequest(
            role = "client",
            hostId = hostId,
            clientId = clientId,
            hostPk = hostPkBase64,
            clientPk = clientPkBase64,
            hostName = hostName,
            clientName = clientName
        )
}
