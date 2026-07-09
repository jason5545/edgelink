package com.edgelink.app

import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import com.edgelink.core.ClipboardSetBody
import com.edgelink.core.CtrlGlobalBody
import com.edgelink.core.CtrlKeyBody
import com.edgelink.core.CtrlPointerBody
import com.edgelink.core.CtrlTextBody
import com.edgelink.core.DeviceId
import com.edgelink.core.EmptyBody
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.InputKeyBody
import com.edgelink.core.InputPointerBody
import com.edgelink.core.InputTextBody
import com.edgelink.core.LocalIdentity
import com.edgelink.core.NotificationPostBody
import com.edgelink.core.NotificationRemoveBody
import com.edgelink.core.PairConfirmRequest
import com.edgelink.core.Pairing
import com.edgelink.core.PairingTypes
import com.edgelink.core.PairingWire
import com.edgelink.core.PinnedPeer
import com.edgelink.core.RtcIceBody
import com.edgelink.core.RtcSdpBody
import com.edgelink.core.ScreenViewerVisibilityBody
import com.edgelink.core.SodiumHandshakeCrypto
import com.edgelink.core.SmsMessageBody
import com.edgelink.core.SmsSendBody
import com.edgelink.core.SmsSendResultBody
import com.edgelink.core.WorkerDeviceRegistrar
import com.edgelink.transport.ByteChannel
import com.edgelink.transport.PairingTransport
import com.edgelink.transport.RelayTransport
import com.edgelink.transport.SecureSessionClient
import com.edgelink.ui.EdgeLinkActions
import com.edgelink.ui.EdgeLinkUiState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.coroutineContext
import java.time.Instant
import java.util.Base64
import java.util.concurrent.atomic.AtomicInteger

private const val HANDSHAKE_TIMEOUT_MS = 4_000L
private const val RELAY_CONNECT_TIMEOUT_MS = 8_000L
private const val MAX_AUTO_RECONNECT_DELAY_MS = 5_000L
private const val PING_INTERVAL_MS = 5_000L
private const val PONG_TIMEOUT_MS = 15_000L
private const val DEBUG_SMS_SEND_TIMEOUT_MS = 12_000L

private fun elapsedMs(startedAtNanos: Long, endedAtNanos: Long = SystemClock.elapsedRealtimeNanos()): Long =
    (endedAtNanos - startedAtNanos) / 1_000_000L

class EdgeLinkController(context: Context) : EdgeLinkActions {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val crypto = SodiumHandshakeCrypto()
    private val connectivityManager = appContext.getSystemService(ConnectivityManager::class.java)
    private val identityStore = SharedPreferencesIdentityStore(appContext)
    private val pairingStore = SharedPreferencesPairingStore(appContext)
    private val settingsStore = SharedPreferencesSettingsStore(appContext)
    private val registrar = WorkerDeviceRegistrar(EdgeLinkConfig.workerBaseUrl)
    private val relayTransport = RelayTransport(crypto = crypto)
    private val pairingTransport = PairingTransport()
    private val clipboardSync = AndroidClipboardSync(appContext)
    private val notificationPresenter = AndroidNotificationPresenter(appContext)
    private val smsSync = AndroidSmsSync(appContext, settingsStore)
    private val screenSession = AndroidScreenSession(appContext, ::sendPlaintext)
    @Volatile
    private var lastPongElapsedMs = 0L
    private val stateFlow = MutableStateFlow(
        EdgeLinkUiState(
            autoReconnectEnabled = settingsStore.autoReconnectEnabled(),
            notificationSyncEnabled = settingsStore.notificationSyncEnabled(),
            remoteInputAccessGranted = RemoteInputService.isEnabled(appContext),
            notificationAccessGranted = isNotificationListenerEnabled(),
            notificationPostGranted = AndroidNotificationPresenter.canPostNotifications(appContext),
            screenDimmingAccessGranted = AndroidScreenPowerGuard.hasRequiredScreenPowerAccess(appContext),
            smsAccessGranted = smsSync.smsAccessGranted()
        )
    )
    private val dispatcher = AndroidCommandDispatcher(
        clipboardSync = clipboardSync,
        notificationPresenter = notificationPresenter,
        screenSession = screenSession,
        smsSync = smsSync,
        onPong = {
            lastPongElapsedMs = SystemClock.elapsedRealtime()
            stateFlow.update { it.copy(connectionStatus = "Connected") }
        },
        onSmsSendResult = { result ->
            sendEnvelope(EnvelopeTypes.SMS_SEND_RESULT, result)
        }
    )

    val state: StateFlow<EdgeLinkUiState> = stateFlow

    @Volatile
    private var session: SecureSessionClient? = null
    private var localIdentity: LocalIdentity? = null
    private var currentPeer: PinnedPeer? = null
    private var connectionJob: Job? = null
    private var pairingJob: Job? = null
    private var smsPendingDrainJob: Job? = null
    private var pendingPairing: PendingPairing? = null
    @Volatile
    private var manuallyDisconnected = false
    private val connectionGeneration = AtomicInteger(0)
    private val autoReconnectWakeups = Channel<Unit>(Channel.CONFLATED)
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            EdgeLinkLog.info("relay.android.network_available")
            signalAutoReconnect("network_available")
        }
    }

    init {
        EdgeLinkLog.configure(appContext)
        screenSession.setControlDataChannelHandler(::handleScreenControlDataChannel)
        runCatching {
            connectivityManager.registerDefaultNetworkCallback(networkCallback)
        }.onFailure { error ->
            EdgeLinkLog.error("relay.android.network_callback_failed", error)
        }
        scope.launch {
            run()
        }
    }

    fun close() {
        runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
        screenSession.setControlDataChannelHandler(null)
        screenSession.shutdown()
        session?.close()
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

    override fun onReconnect() {
        val identity = localIdentity
        val peer = currentPeer
        EdgeLinkLog.info(
            "relay.android.reconnect_requested hasIdentity=${identity != null} hasPeer=${peer != null}"
        )
        if (identity == null || peer == null) {
            stateFlow.update { it.copy(connectionStatus = "No paired Mac", isConnected = false) }
            return
        }
        startConnection(identity, peer, reason = "manual")
    }

    override fun onDisconnect() {
        EdgeLinkLog.info("relay.android.disconnect_requested")
        manuallyDisconnected = true
        connectionGeneration.incrementAndGet()
        connectionJob?.cancel()
        connectionJob = null
        session?.close()
        session = null
        screenSession.stop()
        stateFlow.update { it.copy(connectionStatus = "Disconnected", isConnected = false) }
    }

    override fun onQuit() {
        EdgeLinkLog.info("runtime.android.quit_requested")
        onDisconnect()
        appContext.stopService(Intent(appContext, EdgeLinkForegroundService::class.java))
    }

    override fun onAutoReconnectChange(enabled: Boolean) {
        settingsStore.saveAutoReconnectEnabled(enabled)
        EdgeLinkLog.info("relay.android.auto_reconnect enabled=$enabled")
        stateFlow.update { it.copy(autoReconnectEnabled = enabled) }
        if (enabled && !stateFlow.value.isConnected) {
            signalAutoReconnect("auto_reconnect_enabled")
            onReconnect()
        }
    }

    override fun onNotificationSyncChange(enabled: Boolean) {
        settingsStore.saveNotificationSyncEnabled(enabled)
        EdgeLinkLog.info("notification.android.sync_enabled enabled=$enabled")
        stateFlow.update {
            it.copy(
                notificationSyncEnabled = enabled,
                notificationAccessGranted = isNotificationListenerEnabled(),
                notificationPostGranted = AndroidNotificationPresenter.canPostNotifications(appContext),
                smsAccessGranted = smsSync.smsAccessGranted()
            )
        }
    }

    override fun onOpenNotificationSettings() {
        EdgeLinkLog.info("notification.android.open_settings")
        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        appContext.startActivity(intent)
    }

    override fun onOpenRemoteInputSettings() {
        EdgeLinkLog.info("remote_input.android.open_settings")
        RemoteInputService.openSettings(appContext)
    }

    override fun onOpenScreenDimmingSettings() {
        EdgeLinkLog.info("screen.android.dimming_open_settings")
        val action = if (!AndroidScreenPowerGuard.canWriteSettings(appContext)) {
            Settings.ACTION_MANAGE_WRITE_SETTINGS
        } else {
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION
        }
        val intent = Intent(action)
            .setData(Uri.parse("package:${appContext.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        appContext.startActivity(intent)
    }

    override fun onOpenSmsSettings() {
        EdgeLinkLog.info("sms.android.permission_request")
    }

    fun refreshNotificationAccess() {
        stateFlow.update {
            it.copy(
                remoteInputAccessGranted = RemoteInputService.isEnabled(appContext),
                notificationAccessGranted = isNotificationListenerEnabled(),
                notificationPostGranted = AndroidNotificationPresenter.canPostNotifications(appContext),
                screenDimmingAccessGranted = AndroidScreenPowerGuard.hasRequiredScreenPowerAccess(appContext),
                smsAccessGranted = smsSync.smsAccessGranted()
            )
        }
    }

    fun isNotificationListenerEnabled(): Boolean {
        val componentName = ComponentName(appContext, AndroidNotificationListenerService::class.java)
        val enabledListeners = Settings.Secure.getString(
            appContext.contentResolver,
            "enabled_notification_listeners"
        ).orEmpty()
        return enabledListeners.split(':').any { it == componentName.flattenToString() }
    }

    fun onLocalNotificationPosted(body: NotificationPostBody) {
        if (!stateFlow.value.notificationSyncEnabled) {
            return
        }
        val sourceDeviceId = localIdentity?.deviceId
        val outbound = body.copy(sourceDeviceId = sourceDeviceId)
        EdgeLinkLog.info("notification.android.local_post id=${body.id} app=${body.app} hasSession=${session != null}")
        sendEnvelope(EnvelopeTypes.NOTIFICATION_POST, outbound)
    }

    fun onLocalNotificationRemoved(body: NotificationRemoveBody) {
        if (!stateFlow.value.notificationSyncEnabled) {
            return
        }
        val outbound = body.copy(sourceDeviceId = localIdentity?.deviceId)
        EdgeLinkLog.info("notification.android.local_remove id=${body.id} hasSession=${session != null}")
        sendEnvelope(EnvelopeTypes.NOTIFICATION_REMOVE, outbound)
    }

    fun onSmsReceivedFromBroadcast(address: String, text: String, timestampMs: Long) {
        onSmsInbound(
            address = address,
            text = text,
            timestampMs = timestampMs,
            markSeen = true,
            logName = "sms.android.received"
        )
    }

    fun onDebugSmsInjected(address: String, text: String, timestampMs: Long) {
        onSmsInbound(
            address = address,
            text = text,
            timestampMs = timestampMs,
            markSeen = false,
            logName = "sms.android.debug_injected"
        )
    }

    fun onSmsPendingAvailable(reason: String) {
        launchSmsPendingDrain(reason)
    }

    private fun onSmsInbound(
        address: String,
        text: String,
        timestampMs: Long,
        markSeen: Boolean,
        logName: String
    ) {
        val body = smsSync.messageFromBroadcast(
            sourceDeviceId = localIdentity?.deviceId,
            address = address,
            text = text,
            timestampMs = timestampMs
        )
        val activeSession = session
        if (activeSession == null) {
            EdgeLinkLog.info("${logName}_deferred id=${body.id} addressFp=${AndroidSmsSync.fingerprint(address)}")
            if (!markSeen) {
                scope.launch(Dispatchers.IO) {
                    val lateSession = waitForSession(DEBUG_SMS_SEND_TIMEOUT_MS)
                    if (lateSession == null) {
                        EdgeLinkLog.warn("${logName}_dropped_no_session id=${body.id}")
                        return@launch
                    }
                    EdgeLinkLog.info("${logName}_retry id=${body.id}")
                    sendSmsMessage(lateSession, body, logName, markSeenTimestampMs = null)
                }
            }
            return
        }
        EdgeLinkLog.info("$logName id=${body.id} addressFp=${AndroidSmsSync.fingerprint(address)}")
        scope.launch(Dispatchers.IO) {
            sendSmsMessage(
                activeSession = activeSession,
                body = body,
                logName = logName,
                markSeenTimestampMs = timestampMs.takeIf { markSeen }
            )
        }
    }

    private suspend fun waitForSession(timeoutMs: Long): SecureSessionClient? {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline && coroutineContext.isActive) {
            session?.let { return it }
            delay(250)
        }
        return session
    }

    private suspend fun sendSmsMessage(
        activeSession: SecureSessionClient,
        body: SmsMessageBody,
        logName: String,
        markSeenTimestampMs: Long?
    ) {
        runCatching {
            activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.SMS_MESSAGE, body))
        }.onSuccess {
            markSeenTimestampMs?.let(smsSync::markBroadcastSeen)
        }.onFailure { error ->
            EdgeLinkLog.error("${logName}_send_failed id=${body.id}", error)
        }
    }

    fun onScreenCapturePermissionGranted(resultCode: Int, data: Intent) {
        screenSession.startWithPermission(resultCode, data)
    }

    fun onScreenCapturePermissionDenied() {
        EdgeLinkLog.warn("screen.android.permission_denied")
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
            startConnection(identity, peer, reason = "startup")
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
        startConnection(identity, peer, reason = "pairing")
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

    private fun startConnection(identity: LocalIdentity, peer: PinnedPeer, reason: String) {
        currentPeer = peer
        manuallyDisconnected = false
        val generation = connectionGeneration.incrementAndGet()
        EdgeLinkLog.info(
            "relay.android.connection_start reason=$reason hostId=${peer.deviceId} clientId=${identity.deviceId} autoReconnect=${stateFlow.value.autoReconnectEnabled}"
        )
        connectionJob?.cancel()
        screenSession.stop()
        session?.close()
        session = null
        stateFlow.update {
            it.copy(
                connectionStatus = if (reason == "manual") "Reconnecting" else it.connectionStatus,
                isConnected = false
            )
        }
        connectionJob = scope.launch(Dispatchers.IO) {
            connectLoop(identity, peer, generation)
        }
    }

    private suspend fun connectLoop(identity: LocalIdentity, peer: PinnedPeer, generation: Int) {
        var retryDelayMs = 1_000L

        while (coroutineContext.isActive && connectionGeneration.get() == generation) {
            var channel: ByteChannel? = null
            try {
                EdgeLinkLog.info("relay.android.connect_start hostId=${peer.deviceId} clientId=${identity.deviceId}")
                stateFlow.update { it.copy(connectionStatus = "Connecting relay", isConnected = false) }
                channel = withTimeoutOrNull(RELAY_CONNECT_TIMEOUT_MS) {
                    relayTransport.connect(
                        relayUrl = EdgeLinkConfig.relayUrl,
                        hostId = peer.deviceId,
                        identity = identity
                    )
                } ?: run {
                    EdgeLinkLog.warn(
                        "relay.android.connect_timeout hostId=${peer.deviceId} clientId=${identity.deviceId} timeoutMs=$RELAY_CONNECT_TIMEOUT_MS"
                    )
                    error("Relay connect timed out after ${RELAY_CONNECT_TIMEOUT_MS}ms.")
                }
                if (connectionGeneration.get() != generation) {
                    channel.close()
                    return
                }
                val nextSession = SecureSessionClient(
                    channel = channel,
                    identity = identity,
                    peer = peer,
                    crypto = crypto
                )

                stateFlow.update { it.copy(connectionStatus = "Handshaking") }
                val handshakeEstablished = withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) {
                    nextSession.connect()
                    true
                } == true
                if (!handshakeEstablished) {
                    EdgeLinkLog.warn(
                        "relay.android.handshake_timeout hostId=${peer.deviceId} clientId=${identity.deviceId} timeoutMs=$HANDSHAKE_TIMEOUT_MS"
                    )
                    error("Handshake timed out after ${HANDSHAKE_TIMEOUT_MS}ms.")
                }
                if (connectionGeneration.get() != generation) {
                    nextSession.close()
                    return
                }
                EdgeLinkLog.info("relay.android.handshake_ok hostId=${peer.deviceId} clientId=${identity.deviceId}")
                lastPongElapsedMs = SystemClock.elapsedRealtime()
                session = nextSession
                AndroidNotificationListenerService.requestActiveNotificationSync(appContext, "session_connected")
                retryDelayMs = 1_000L
                stateFlow.update { it.copy(connectionStatus = "Connected", isConnected = true) }

                coroutineScope {
                    val pingJob = launch { pingLoop(nextSession) }
                    val clipboardJob = launch { clipboardLoop(nextSession) }
                    val smsPendingJob = launch { drainPendingSms(nextSession, identity, reason = "connected") }
                    try {
                        nextSession.receiveLoop(dispatcher::handle)
                    } finally {
                        pingJob.cancelAndJoin()
                        clipboardJob.cancelAndJoin()
                        smsPendingJob.cancelAndJoin()
                    }
                }
                throw IllegalStateException("Relay receive loop ended.")
            } catch (error: CancellationException) {
                EdgeLinkLog.info("relay.android.connect_cancelled hostId=${peer.deviceId} clientId=${identity.deviceId}")
                throw error
            } catch (error: Throwable) {
                if (!coroutineContext.isActive || connectionGeneration.get() != generation) {
                    EdgeLinkLog.info("relay.android.connect_stale hostId=${peer.deviceId} clientId=${identity.deviceId}")
                    return
                }
                EdgeLinkLog.error("relay.android.disconnected hostId=${peer.deviceId} clientId=${identity.deviceId}", error)
                session = null
                screenSession.stop()
                val autoReconnect = stateFlow.value.autoReconnectEnabled && !manuallyDisconnected
                stateFlow.update {
                    it.copy(
                        connectionStatus = if (autoReconnect) "Reconnecting" else "Disconnected",
                        isConnected = false
                    )
                }
                if (!autoReconnect) {
                    EdgeLinkLog.info("relay.android.auto_reconnect_disabled hostId=${peer.deviceId} clientId=${identity.deviceId}")
                    return
                }
                if (!waitForAutoReconnect(retryDelayMs)) {
                    EdgeLinkLog.info("relay.android.auto_reconnect_stopped hostId=${peer.deviceId} clientId=${identity.deviceId}")
                    stateFlow.update { it.copy(connectionStatus = "Disconnected", isConnected = false) }
                    return
                }
                retryDelayMs = (retryDelayMs * 2).coerceAtMost(MAX_AUTO_RECONNECT_DELAY_MS)
            } finally {
                channel?.close()
            }
        }
    }

    private suspend fun waitForAutoReconnect(delayMs: Long): Boolean {
        if (!stateFlow.value.autoReconnectEnabled) {
            return false
        }
        val woke = withTimeoutOrNull(delayMs) {
            autoReconnectWakeups.receive()
            true
        } == true
        EdgeLinkLog.info("relay.android.auto_reconnect_wait_done delayMs=$delayMs woke=$woke")
        return stateFlow.value.autoReconnectEnabled
    }

    private fun signalAutoReconnect(reason: String) {
        EdgeLinkLog.info("relay.android.auto_reconnect_wakeup reason=$reason")
        autoReconnectWakeups.trySend(Unit)
    }

    private suspend fun pingLoop(activeSession: SecureSessionClient) {
        while (coroutineContext.isActive) {
            val pongAgeMs = SystemClock.elapsedRealtime() - lastPongElapsedMs
            if (lastPongElapsedMs > 0 && pongAgeMs >= PONG_TIMEOUT_MS) {
                EdgeLinkLog.warn("relay.android.pong_timeout ageMs=$pongAgeMs timeoutMs=$PONG_TIMEOUT_MS")
                error("Pong timed out after ${pongAgeMs}ms.")
            }
            activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.STATUS_PING, EmptyBody))
            delay(PING_INTERVAL_MS)
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

    private fun launchSmsPendingDrain(reason: String) {
        val activeSession = session
        val identity = localIdentity
        if (activeSession == null || identity == null) {
            EdgeLinkLog.info(
                "sms.android.pending_deferred reason=$reason hasSession=${activeSession != null} hasIdentity=${identity != null}"
            )
            return
        }
        if (smsPendingDrainJob?.isActive == true) {
            EdgeLinkLog.info("sms.android.pending_drain_already_running reason=$reason")
            return
        }
        smsPendingDrainJob = scope.launch(Dispatchers.IO) {
            drainPendingSms(activeSession, identity, reason)
        }
    }

    private suspend fun drainPendingSms(
        activeSession: SecureSessionClient,
        identity: LocalIdentity,
        reason: String
    ) {
        runCatching {
            val pending = smsSync.pendingBroadcastMessages(sourceDeviceId = identity.deviceId)
            if (pending.isEmpty()) {
                return@runCatching
            }
            var sent = 0
            for (body in pending) {
                activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.SMS_MESSAGE, body))
                smsSync.acknowledgePendingBroadcasts(listOf(body.id))
                sent += 1
            }
            EdgeLinkLog.info("sms.android.pending_sent count=$sent reason=$reason")
        }.onFailure { error ->
            EdgeLinkLog.error("sms.android.pending_send_failed reason=$reason", error)
        }
    }

    private inline fun <reified T> sendEnvelope(type: String, body: T) {
        sendPlaintext(EnvelopeCodec.encode(type, body))
    }

    private fun sendPlaintext(plaintext: ByteArray) {
        val activeSession = session ?: return
        scope.launch(Dispatchers.IO) {
            runCatching {
                activeSession.sendPlaintext(plaintext)
            }
        }
    }

    private fun handleScreenControlDataChannel(plaintext: ByteArray) {
        scope.launch(Dispatchers.Default) {
            runCatching {
                dispatcher.handle(plaintext)
            }.onFailure { error ->
                EdgeLinkLog.error("screen.android.control_data_channel_dispatch_failed", error)
            }
        }
    }
}

private class AndroidCommandDispatcher(
    private val clipboardSync: AndroidClipboardSync,
    private val notificationPresenter: AndroidNotificationPresenter,
    private val screenSession: AndroidScreenSession,
    private val smsSync: AndroidSmsSync,
    private val onPong: () -> Unit,
    private val onSmsSendResult: (SmsSendResultBody) -> Unit
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
            EnvelopeTypes.NOTIFICATION_POST -> {
                val envelope = EnvelopeCodec.decode<NotificationPostBody>(plaintext)
                notificationPresenter.show(envelope.b)
                null
            }
            EnvelopeTypes.NOTIFICATION_REMOVE -> {
                val envelope = EnvelopeCodec.decode<NotificationRemoveBody>(plaintext)
                notificationPresenter.remove(envelope.b)
                null
            }
            EnvelopeTypes.SMS_SEND -> {
                val envelope = EnvelopeCodec.decode<SmsSendBody>(plaintext)
                onSmsSendResult(smsSync.sendSms(envelope.b))
                null
            }
            EnvelopeTypes.SCREEN_START -> {
                screenSession.requestStart()
                null
            }
            EnvelopeTypes.SCREEN_STOP -> {
                screenSession.stop()
                null
            }
            EnvelopeTypes.RTC_ANSWER -> {
                val envelope = EnvelopeCodec.decode<RtcSdpBody>(plaintext)
                screenSession.handleAnswer(envelope.b)
                null
            }
            EnvelopeTypes.RTC_ICE -> {
                val envelope = EnvelopeCodec.decode<RtcIceBody>(plaintext)
                screenSession.handleIce(envelope.b)
                null
            }
            EnvelopeTypes.SCREEN_VIEWER_VISIBILITY -> {
                val envelope = EnvelopeCodec.decode<ScreenViewerVisibilityBody>(plaintext)
                screenSession.setViewerVisible(envelope.b.visible)
                null
            }
            EnvelopeTypes.CTRL_POINTER -> {
                val envelope = EnvelopeCodec.decode<CtrlPointerBody>(plaintext)
                ControlTimeline.mark()
                if (envelope.b.action == "down") {
                    screenSession.boostForIncomingInput()
                }
                if (envelope.b.action != "move") {
                    screenSession.noteControlEvent("pointer:${envelope.b.action}")
                }
                if (envelope.b.action != "move") {
                    EdgeLinkLog.info("control.android.pointer_in action=${envelope.b.action} bytes=${plaintext.size}")
                }
                RemoteInputService.dispatchPointer(envelope.b)
                null
            }
            EnvelopeTypes.CTRL_GLOBAL -> {
                val startedAt = SystemClock.elapsedRealtimeNanos()
                val envelope = EnvelopeCodec.decode<CtrlGlobalBody>(plaintext)
                ControlTimeline.mark()
                screenSession.boostForIncomingInput()
                screenSession.noteControlEvent("global:${envelope.b.action}")
                EdgeLinkLog.info("control.android.global_in action=${envelope.b.action} bytes=${plaintext.size}")
                RemoteInputService.dispatchGlobal(envelope.b)
                EdgeLinkLog.info(
                    "control.android.global_queued action=${envelope.b.action} durationMs=${elapsedMs(startedAt)}"
                )
                null
            }
            EnvelopeTypes.CTRL_TEXT -> {
                val envelope = EnvelopeCodec.decode<CtrlTextBody>(plaintext)
                ControlTimeline.mark()
                screenSession.noteControlEvent("text")
                RemoteInputService.dispatchText(envelope.b)
                null
            }
            EnvelopeTypes.CTRL_KEY -> {
                val envelope = EnvelopeCodec.decode<CtrlKeyBody>(plaintext)
                ControlTimeline.mark()
                screenSession.noteControlEvent("key:${envelope.b.key}:${envelope.b.down}")
                RemoteInputService.dispatchKey(envelope.b)
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
