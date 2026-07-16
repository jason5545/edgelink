package com.edgelink.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import com.edgelink.core.AndroidMicStatusBody
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
import com.edgelink.core.MiLinkCommandBody
import com.edgelink.core.MiLinkFrameBody
import com.edgelink.core.MiLinkStatusBody
import com.edgelink.core.NotificationPostBody
import com.edgelink.core.NotificationRemoveBody
import com.edgelink.core.PairConfirmRequest
import com.edgelink.core.Pairing
import com.edgelink.core.PairingTypes
import com.edgelink.core.PairingWire
import com.edgelink.core.PhoneActionBody
import com.edgelink.core.PhoneActionResultBody
import com.edgelink.core.PhoneCallStatusBody
import com.edgelink.core.PhoneRelayEndpointBody
import com.edgelink.core.PhoneRelayStartRequestBody
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
import com.edgelink.transport.TurnCredentialTransport
import com.edgelink.transport.TurnCredentialsResponse
import com.edgelink.ui.ConnectionPhase
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
import rikka.shizuku.Shizuku
import kotlin.coroutines.coroutineContext
import java.time.Instant
import java.util.Base64
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

private const val HANDSHAKE_TIMEOUT_MS = 4_000L
private const val RELAY_CONNECT_TIMEOUT_MS = 8_000L
private const val MAX_AUTO_RECONNECT_DELAY_MS = 5_000L
private const val PING_INTERVAL_MS = 5_000L
private const val PONG_TIMEOUT_MS = 15_000L
private const val DEBUG_SMS_SEND_TIMEOUT_MS = 12_000L
private const val CALL_RELAY_BRIDGE_DIAL_DELAY_MS = 2_000L
private const val CALL_RELAY_BRIDGE_ANSWER_DELAY_MS = 750L
private const val CALL_RELAY_SELECTION_LATCH_TTL_MS = 30_000L
private const val CALL_RELAY_SELECTION_REQUEST_TIMEOUT_MS = 10_000L

private fun elapsedMs(startedAtNanos: Long, endedAtNanos: Long = SystemClock.elapsedRealtimeNanos()): Long =
    (endedAtNanos - startedAtNanos) / 1_000_000L

private enum class PendingShizukuAction {
    Notification,
    RemoteInput,
    Screen,
    Sms,
    MiLinkProbe
}

internal enum class ShizukuAutoRepairTarget {
    Notification,
    RemoteInput,
    Screen,
    Sms
}

internal fun shizukuAutoRepairTargets(state: EdgeLinkUiState): List<ShizukuAutoRepairTarget> =
    buildList {
        if (state.notificationSyncEnabled && (!state.notificationAccessGranted || !state.notificationPostGranted)) {
            add(ShizukuAutoRepairTarget.Notification)
        }
        if (!state.remoteInputAccessGranted) {
            add(ShizukuAutoRepairTarget.RemoteInput)
        }
        if (!state.screenDimmingAccessGranted) {
            add(ShizukuAutoRepairTarget.Screen)
        }
        if (!state.smsAccessGranted) {
            add(ShizukuAutoRepairTarget.Sms)
        }
    }

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
    private val turnCredentialTransport = TurnCredentialTransport(crypto = crypto)
    private val pairingTransport = PairingTransport()
    private val clipboardSync = AndroidClipboardSync(appContext)
    private val notificationPresenter = AndroidNotificationPresenter(appContext)
    private val smsSync = AndroidSmsSync(appContext, settingsStore)
    private val phoneCallController = AndroidPhoneCallController(appContext)
    private val miLinkCommandBridge = AndroidMiLinkCommandBridge(appContext)
    private val micActivityMonitor = AndroidMicActivityMonitor(appContext) { status: AndroidMicStatusBody ->
        sendEnvelope(EnvelopeTypes.ANDROID_MIC_STATUS, status)
    }
    private val screenSession = AndroidScreenSession(
        context = appContext,
        sendPlaintext = ::sendPlaintext,
        screenSharePrivacyEnabled = settingsStore::screenSharePrivacyEnabled,
        iceServerProvider = ::currentScreenIceServerConfigs
    )
    private val initialShizukuState = AndroidShizukuSupport.currentState()
    @Volatile
    private var lastPongElapsedMs = 0L
    private val stateFlow = MutableStateFlow(
        EdgeLinkUiState(
            autoReconnectEnabled = settingsStore.autoReconnectEnabled(),
            notificationSyncEnabled = settingsStore.notificationSyncEnabled(),
            screenSharePrivacyEnabled = settingsStore.screenSharePrivacyEnabled(),
            screenSharePrivacyControlAvailable = AndroidScreenShareProtectionGuard.canControl(appContext),
            remoteInputAccessGranted = RemoteInputService.isEnabled(appContext),
            notificationAccessGranted = isNotificationListenerEnabled(),
            notificationPostGranted = AndroidNotificationPresenter.canPostNotifications(appContext),
            screenDimmingAccessGranted = AndroidScreenPowerGuard.hasRequiredScreenPowerAccess(appContext),
            smsAccessGranted = smsSync.smsAccessGranted(),
            shizukuAvailable = initialShizukuState.available,
            shizukuSupported = initialShizukuState.supported,
            shizukuPermissionGranted = initialShizukuState.permissionGranted,
            shizukuPermissionRequestBlocked = initialShizukuState.permissionRequestBlocked,
            shizukuUid = initialShizukuState.uid,
            xiaomiMiLinkProbeStatus = if (initialShizukuState.canUse) "尚未測試" else null
        )
    )
    private val dispatcher = AndroidCommandDispatcher(
        clipboardSync = clipboardSync,
        notificationPresenter = notificationPresenter,
        screenSession = screenSession,
        smsSync = smsSync,
        phoneCallController = phoneCallController,
        miLinkCommandBridge = miLinkCommandBridge,
        onPong = {
            lastPongElapsedMs = SystemClock.elapsedRealtime()
            stateFlow.update {
                it.copy(
                    connectionStatus = "Connected",
                    connectionPhase = ConnectionPhase.Connected
                )
            }
        },
        onSmsSendResult = { result ->
            sendEnvelope(EnvelopeTypes.SMS_SEND_RESULT, result)
        },
        onScreenStartReceived = {
            ensureTurnCredentials("screen_start")
        },
        onPhoneActionReceived = { body ->
            if (body.action == "dial" || body.action == "answer") {
                refreshTurnCredentials("phone_action_${body.action}")
            }
            if (body.action == "hangup") {
                phoneRelayCallSessionActive = false
                pendingCallRelayBridgeJob?.cancel()
                pendingCallRelayBridgeJob = null
                AndroidCallRelayBridge.stop("phone_action_hangup")
            }
        },
        onPhoneActionResult = { body, result ->
            handlePhoneActionRelayBridgeResult(body, result)
            sendEnvelope(EnvelopeTypes.PHONE_ACTION_RESULT, result)
        },
        onPhoneRelayEndpoint = { body ->
            handlePhoneRelayEndpoint(body)
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
    private var shizukuAutoRepairJob: Job? = null
    private var turnCredentialJob: Job? = null
    private var pendingCallRelayBridgeJob: Job? = null
    private var pendingPhoneRelaySelectionRequestId: String? = null
    private var pendingPhoneRelaySelectionTimeoutJob: Job? = null
    private var pendingPairing: PendingPairing? = null
    private var pendingShizukuAction: PendingShizukuAction? = null
    @Volatile
    private var latestMiLinkStatus: MiLinkStatusBody? = null
    @Volatile
    private var latestTurnCredentials: TurnCredentialsResponse? = null
    @Volatile
    private var phoneRelayCallSessionActive = false
    private var miLinkRootProbeAttempted = false
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
    private val shizukuBinderReceivedListener = Shizuku.OnBinderReceivedListener {
        onShizukuStateChanged("binder_received")
    }
    private val shizukuBinderDeadListener = Shizuku.OnBinderDeadListener {
        onShizukuStateChanged("binder_dead")
    }
    private val shizukuPermissionResultListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode != AndroidShizukuSupport.requestCode) {
                return@OnRequestPermissionResultListener
            }
            EdgeLinkLog.info("shizuku.android.permission_result granted=${grantResult == PackageManager.PERMISSION_GRANTED}")
            if (grantResult == PackageManager.PERMISSION_GRANTED) {
                val shizukuState = AndroidShizukuSupport.currentState()
                if (shizukuState.uid == 0) {
                    pendingShizukuAction = null
                    runShizukuAutoRepairIfReady("permission_granted")
                } else {
                    runPendingShizukuAction()
                }
            } else {
                pendingShizukuAction = null
                refreshNotificationAccess()
            }
        }

    init {
        EdgeLinkLog.configure(appContext)
        Shizuku.addBinderReceivedListenerSticky(shizukuBinderReceivedListener)
        Shizuku.addBinderDeadListener(shizukuBinderDeadListener)
        Shizuku.addRequestPermissionResultListener(shizukuPermissionResultListener)
        screenSession.setControlDataChannelHandler(::handleScreenControlDataChannel)
        EdgeLinkInCallService.setCallsIdleListener { reason ->
            scope.launch {
                handleInCallServiceCallsIdle(reason)
            }
        }
        EdgeLinkInCallService.setCallStatusListener { status ->
            scope.launch {
                handlePhoneCallStatus(status)
            }
        }
        micActivityMonitor.start()
        runCatching {
            connectivityManager.registerDefaultNetworkCallback(networkCallback)
        }.onFailure { error ->
            EdgeLinkLog.error("relay.android.network_callback_failed", error)
        }
        scope.launch {
            run()
        }
        runShizukuAutoRepairIfReady("init")
        runMiLinkRootProbeIfReady("init")
    }

    fun close() {
        runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
        Shizuku.removeBinderReceivedListener(shizukuBinderReceivedListener)
        Shizuku.removeBinderDeadListener(shizukuBinderDeadListener)
        Shizuku.removeRequestPermissionResultListener(shizukuPermissionResultListener)
        screenSession.setControlDataChannelHandler(null)
        EdgeLinkInCallService.setCallsIdleListener(null)
        EdgeLinkInCallService.setCallStatusListener(null)
        micActivityMonitor.stop()
        screenSession.shutdown()
        turnCredentialJob?.cancel()
        pendingCallRelayBridgeJob?.cancel()
        pendingPhoneRelaySelectionTimeoutJob?.cancel()
        pendingCallRelayBridgeJob = null
        pendingPhoneRelaySelectionRequestId = null
        pendingPhoneRelaySelectionTimeoutJob = null
        latestTurnCredentials = null
        session?.close()
        scope.cancel()
    }

    private fun handlePhoneActionRelayBridgeResult(body: PhoneActionBody, result: PhoneActionResultBody) {
        when (body.action) {
            "dial", "answer" -> {
                if (result.success) {
                    phoneRelayCallSessionActive = true
                    scheduleCallRelayBridgeStart(body)
                } else {
                    phoneRelayCallSessionActive = false
                    pendingCallRelayBridgeJob?.cancel()
                    pendingCallRelayBridgeJob = null
                    AndroidCallRelayBridge.stop("phone_action_failed_${body.action}")
                }
            }
            "hangup" -> {
                phoneRelayCallSessionActive = false
                pendingCallRelayBridgeJob?.cancel()
                pendingCallRelayBridgeJob = null
                AndroidCallRelayBridge.stop("phone_action_hangup_result")
            }
        }
    }

    private fun handleInCallServiceCallsIdle(reason: String) {
        if (!phoneRelayCallSessionActive) {
            EdgeLinkLog.info("phone.android.remote_hangup_ignored reason=$reason inactive_relay_call")
            return
        }
        phoneRelayCallSessionActive = false
        pendingCallRelayBridgeJob?.cancel()
        pendingCallRelayBridgeJob = null
        AndroidCallRelayBridge.stop("incall_service_idle_$reason")
        scope.launch(Dispatchers.IO) {
            runCatching {
                AndroidShizukuSupport.clearPhoneCallRelay(appContext)
            }.onSuccess { result ->
                EdgeLinkLog.info(
                    "phone.android.relay_latch_clear_after_remote_end " +
                        "success=${result.success} message=${result.message}"
                )
            }.onFailure { error ->
                EdgeLinkLog.warn("phone.android.relay_latch_clear_after_remote_end_failed", error)
            }
        }
        val result = PhoneActionResultBody(
            requestId = "remote-ended-${SystemClock.elapsedRealtime()}",
            action = "hangup",
            success = true,
            ts = Instant.now().epochSecond
        )
        EdgeLinkLog.info("phone.android.remote_hangup_detected reason=$reason requestId=${result.requestId}")
        sendEnvelope(EnvelopeTypes.PHONE_ACTION_RESULT, result)
    }

    private fun handlePhoneCallStatus(status: PhoneCallStatusBody) {
        EdgeLinkLog.info(
            "phone.android.call_status_out callId=${status.callId} state=${status.state} " +
                "direction=${status.direction ?: "unknown"} canAnswer=${status.canAnswer} reason=${status.reason}"
        )
        sendEnvelope(EnvelopeTypes.PHONE_CALL_STATUS, status)
    }

    fun onPhoneRelaySelectedFromInCallUi(reason: String) {
        val callState = EdgeLinkInCallService.diagnosticState()
        if (!EdgeLinkInCallService.hasOngoingCall()) {
            EdgeLinkLog.warn("phone.android.relay_selection_ignored reason=$reason no_ongoing_call $callState")
            return
        }
        if (session == null || !stateFlow.value.isConnected) {
            EdgeLinkLog.warn("phone.android.relay_selection_ignored reason=$reason not_connected $callState")
            return
        }
        val pendingRequestId = pendingPhoneRelaySelectionRequestId
        if (pendingRequestId != null) {
            EdgeLinkLog.info(
                "phone.android.relay_selection_ignored reason=$reason pendingRequestId=$pendingRequestId $callState"
            )
            return
        }

        val requestId = UUID.randomUUID().toString()
        pendingPhoneRelaySelectionRequestId = requestId
        pendingPhoneRelaySelectionTimeoutJob?.cancel()
        pendingPhoneRelaySelectionTimeoutJob = scope.launch {
            delay(CALL_RELAY_SELECTION_REQUEST_TIMEOUT_MS)
            if (pendingPhoneRelaySelectionRequestId == requestId) {
                pendingPhoneRelaySelectionRequestId = null
                EdgeLinkLog.warn("phone.android.relay_selection_timeout requestId=$requestId reason=$reason")
            }
        }

        val body = PhoneRelayStartRequestBody(
            requestId = requestId,
            reason = reason,
            ts = Instant.now().epochSecond
        )
        EdgeLinkLog.info("phone.android.relay_selection_requested requestId=$requestId reason=$reason $callState")
        sendEnvelope(EnvelopeTypes.PHONE_RELAY_START, body)
    }

    private suspend fun handlePhoneRelayEndpoint(body: PhoneRelayEndpointBody) {
        val pendingRequestId = pendingPhoneRelaySelectionRequestId
        if (pendingRequestId != body.requestId) {
            EdgeLinkLog.warn(
                "phone.android.relay_endpoint_ignored requestId=${body.requestId} pendingRequestId=${pendingRequestId ?: "none"}"
            )
            return
        }
        pendingPhoneRelaySelectionRequestId = null
        pendingPhoneRelaySelectionTimeoutJob?.cancel()
        pendingPhoneRelaySelectionTimeoutJob = null

        if (!body.success) {
            EdgeLinkLog.warn(
                "phone.android.relay_endpoint_failed requestId=${body.requestId} error=${body.error ?: "unknown"}"
            )
            return
        }
        val relayPort = body.relayPort?.takeIf { it in 1..65_535 }
        if (relayPort == null) {
            notifyPhoneRelaySelectionFailed(body.requestId, "invalid_relay_port")
            return
        }
        val identity = localIdentity
        if (identity == null) {
            notifyPhoneRelaySelectionFailed(body.requestId, "no_identity")
            return
        }
        if (!EdgeLinkInCallService.hasOngoingCall()) {
            notifyPhoneRelaySelectionFailed(body.requestId, "call_ended_before_relay")
            return
        }

        val configureResult = runCatching {
            AndroidShizukuSupport.configurePhoneCallRelayHooks(
                appContext,
                relayHost = body.relayHost,
                relayPort = relayPort
            )
        }.getOrElse { error ->
            EdgeLinkLog.warn("phone.android.relay_selection_configure_failed requestId=${body.requestId}", error)
            notifyPhoneRelaySelectionFailed(body.requestId, relaySelectionErrorMessage(error))
            return
        }
        if (!configureResult.success) {
            notifyPhoneRelaySelectionFailed(body.requestId, configureResult.message)
            return
        }

        val latchResult = runCatching {
            AndroidShizukuSupport.armPhoneCallRelay(appContext, CALL_RELAY_SELECTION_LATCH_TTL_MS)
        }.getOrElse { error ->
            EdgeLinkLog.warn("phone.android.relay_selection_latch_failed requestId=${body.requestId}", error)
            notifyPhoneRelaySelectionFailed(body.requestId, relaySelectionErrorMessage(error))
            return
        }
        if (!latchResult.success) {
            notifyPhoneRelaySelectionFailed(body.requestId, latchResult.message)
            return
        }

        phoneRelayCallSessionActive = true
        pendingCallRelayBridgeJob?.cancel()
        pendingCallRelayBridgeJob = null
        val relayBody = PhoneActionBody(
            requestId = body.requestId,
            action = "answer",
            relayHost = body.relayHost,
            relayPort = relayPort,
            relaySessionId = body.relaySessionId,
            relayControlPort = body.relayControlPort
        )
        AndroidCallRelayBridge.start(identity, relayBody, reason = "incallui_relay_selected")
        pokePhoneContinuityRelaySelection(body.requestId)
        EdgeLinkLog.info(
            "phone.android.relay_selection_active requestId=${body.requestId} " +
                "relay=${body.relayHost ?: "none"}:$relayPort sessionId=${body.relaySessionId ?: "none"}"
        )
    }

    private fun notifyPhoneRelaySelectionFailed(requestId: String, error: String) {
        phoneRelayCallSessionActive = false
        pendingCallRelayBridgeJob?.cancel()
        pendingCallRelayBridgeJob = null
        AndroidCallRelayBridge.stop("incallui_relay_selection_failed")
        EdgeLinkLog.warn("phone.android.relay_selection_failed requestId=$requestId error=$error")
        sendEnvelope(
            EnvelopeTypes.PHONE_ACTION_RESULT,
            PhoneActionResultBody(
                requestId = requestId,
                action = "answer",
                success = false,
                error = error,
                ts = Instant.now().epochSecond
            )
        )
    }

    private suspend fun pokePhoneContinuityRelaySelection(requestId: String) {
        runCatching {
            AndroidMiLinkPhoneContinuityBridge.probe(appContext)
        }.onSuccess { result ->
            EdgeLinkLog.info(
                "phone.android.relay_selection_continuity_poked requestId=$requestId " +
                    "success=${result.success} remoteDevices=${result.remoteDeviceCount} " +
                    "mediaRelayCandidates=${result.mediaRelayCandidateCount}"
            )
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.relay_selection_continuity_poke_failed requestId=$requestId", error)
        }
    }

    private fun relaySelectionErrorMessage(error: Throwable): String =
        "${error.javaClass.simpleName}:${error.message.orEmpty()}"

    private fun scheduleCallRelayBridgeStart(body: PhoneActionBody) {
        val identity = localIdentity
        if (identity == null) {
            EdgeLinkLog.warn("callrelay.android.bridge_start_skipped action=${body.action} no_identity")
            return
        }
        pendingCallRelayBridgeJob?.cancel()
        val delayMs = when (body.action) {
            "answer" -> CALL_RELAY_BRIDGE_ANSWER_DELAY_MS
            else -> CALL_RELAY_BRIDGE_DIAL_DELAY_MS
        }
        pendingCallRelayBridgeJob = scope.launch {
            EdgeLinkLog.info("callrelay.android.bridge_start_delayed action=${body.action} delayMs=$delayMs")
            delay(delayMs)
            AndroidCallRelayBridge.start(identity, body, reason = "phone_action_result_${body.action}")
            pendingCallRelayBridgeJob = null
        }
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
            stateFlow.update {
                it.copy(
                    connectionStatus = "Invalid Mac ID",
                    connectionPhase = ConnectionPhase.Idle
                )
            }
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
                stateFlow.update {
                    it.copy(
                        canConfirmPairing = false,
                        connectionStatus = "Waiting for Mac",
                        connectionPhase = ConnectionPhase.Idle
                    )
                }
            }.onFailure { error ->
                EdgeLinkLog.error("pair.android.confirm failed hostId=${pending.hostId} clientId=${pending.clientId}", error)
                stateFlow.update {
                    it.copy(
                        connectionStatus = "Pairing failed",
                        connectionPhase = ConnectionPhase.Idle,
                        isPairing = false,
                        canConfirmPairing = false
                    )
                }
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
            stateFlow.update {
                it.copy(
                    connectionStatus = "No paired Mac",
                    connectionPhase = ConnectionPhase.Idle,
                    isConnected = false
                )
            }
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
        turnCredentialJob?.cancel()
        turnCredentialJob = null
        latestTurnCredentials = null
        session?.close()
        session = null
        screenSession.stop()
        stateFlow.update {
            it.copy(
                connectionStatus = "Disconnected",
                connectionPhase = ConnectionPhase.Disconnected,
                isConnected = false
            )
        }
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

    override fun onScreenSharePrivacyChange(enabled: Boolean) {
        settingsStore.saveScreenSharePrivacyEnabled(enabled)
        stateFlow.update { it.copy(screenSharePrivacyEnabled = enabled) }
        EdgeLinkLog.info("screen.android.privacy_preference enabled=$enabled")
        screenSession.onPrivacyPreferenceChanged()
    }

    override fun onOpenNotificationSettings() {
        if (tryHandleNotificationAccessWithShizuku()) {
            return
        }
        openNotificationSettingsDirect()
    }

    private fun openNotificationSettingsDirect() {
        EdgeLinkLog.info("notification.android.open_settings")
        val intent = if (!AndroidNotificationPresenter.canPostNotifications(appContext)) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, appContext.packageName)
        } else {
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        }
        intent
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        appContext.startActivity(intent)
    }

    override fun onOpenRemoteInputSettings() {
        if (tryRunOrRequestShizuku(PendingShizukuAction.RemoteInput)) {
            return
        }
        openRemoteInputSettingsDirect()
    }

    private fun openRemoteInputSettingsDirect() {
        EdgeLinkLog.info("remote_input.android.open_settings")
        RemoteInputService.openSettings(appContext)
    }

    override fun onOpenScreenDimmingSettings() {
        if (tryRunOrRequestShizuku(PendingShizukuAction.Screen)) {
            return
        }
        openScreenDimmingSettingsDirect()
    }

    private fun openScreenDimmingSettingsDirect() {
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
        tryHandleSmsAccessWithShizuku()
    }

    override fun onRequestShizukuPermission() {
        pendingShizukuAction = null
        if (!AndroidShizukuSupport.requestPermission()) {
            EdgeLinkLog.warn("shizuku.android.permission_request_skipped")
        }
        refreshNotificationAccess()
    }

    override fun onProbeMiLink() {
        miLinkRootProbeAttempted = false
        if (!tryRunOrRequestShizuku(PendingShizukuAction.MiLinkProbe)) {
            stateFlow.update {
                it.copy(xiaomiMiLinkProbeStatus = "需要 Shizuku root")
            }
        }
    }

    fun tryHandleNotificationAccessWithShizuku(): Boolean =
        tryRunOrRequestShizuku(PendingShizukuAction.Notification)

    fun tryHandleSmsAccessWithShizuku(): Boolean =
        tryRunOrRequestShizuku(PendingShizukuAction.Sms)

    private fun tryRunOrRequestShizuku(action: PendingShizukuAction): Boolean {
        val state = AndroidShizukuSupport.currentState()
        return when {
            state.canUse -> {
                runShizukuAction(action)
                true
            }
            state.canRequestPermission -> {
                pendingShizukuAction = action
                val requested = AndroidShizukuSupport.requestPermission()
                if (!requested) {
                    pendingShizukuAction = null
                }
                requested
            }
            else -> false
        }
    }

    private fun runPendingShizukuAction() {
        val action = pendingShizukuAction ?: run {
            refreshNotificationAccess()
            return
        }
        pendingShizukuAction = null
        runShizukuAction(action)
    }

    private fun runShizukuAction(action: PendingShizukuAction) {
        scope.launch {
            val result = runCatching {
                when (action) {
                    PendingShizukuAction.Notification -> AndroidShizukuSupport.enableNotificationAccess(appContext)
                    PendingShizukuAction.RemoteInput -> AndroidShizukuSupport.enableRemoteInput(appContext)
                    PendingShizukuAction.Screen -> AndroidShizukuSupport.prepareScreenAccess(appContext)
                    PendingShizukuAction.Sms -> AndroidShizukuSupport.grantSmsPermissions(appContext)
                    PendingShizukuAction.MiLinkProbe -> {
                        val status = probeMiLinkStatus()
                        latestMiLinkStatus = status
                        sendEnvelope(EnvelopeTypes.MILINK_STATUS, status)
                        ShizukuOperationResult(
                            success = status.available,
                            message = status.summary
                        )
                    }
                }
            }.getOrElse { error ->
                EdgeLinkLog.warn("shizuku.android.action_exception action=$action", error)
                ShizukuOperationResult(success = false, message = error.message.orEmpty())
            }

            if (action == PendingShizukuAction.MiLinkProbe) {
                stateFlow.update {
                    it.copy(xiaomiMiLinkProbeStatus = result.message)
                }
            }
            if (result.success) {
                EdgeLinkLog.info("shizuku.android.action_ok action=$action message=${result.message}")
            } else {
                EdgeLinkLog.warn("shizuku.android.action_failed action=$action message=${result.message}")
            }
            refreshNotificationAccess()
            fallbackAfterShizukuAction(action)
        }
    }

    private suspend fun probeMiLinkStatus(): MiLinkStatusBody {
        val rootProbe = AndroidShizukuSupport.probeMiLinkRoot(appContext)
        val attributionProbe = AndroidShizukuSupport.probeMiLinkAttributionSpoof(appContext)
        val messengerTransportProbe = AndroidMiLinkMessengerTransport.probe(appContext)
        val castServiceProbe = AndroidMiLinkCastServiceBridge.probe(appContext)
        val phoneContinuityProbe = AndroidMiLinkPhoneContinuityBridge.probe(appContext)
        val serviceCatalog = AndroidMiLinkServiceCatalog.probe(
            appContext,
            messengerTransportOk = messengerTransportProbe.success,
            castServiceOk = castServiceProbe.success,
            mirrorRemoteDeviceCount = phoneContinuityProbe.remoteDeviceCount
        )
        val summary = "${rootProbe.message}; ${attributionProbe.message}; " +
            messengerTransportProbe.message +
            "; ${castServiceProbe.message}; services=" +
            serviceCatalog.services.count { it.available } +
            "/" +
            serviceCatalog.services.size +
            "; ${phoneContinuityProbe.message}"
        return MiLinkStatusBody(
            sourceDeviceId = localIdentity?.deviceId,
            available = rootProbe.success ||
                attributionProbe.success ||
                messengerTransportProbe.success ||
                castServiceProbe.success ||
                phoneContinuityProbe.success ||
                serviceCatalog.services.any { it.available },
            rootProbeOk = rootProbe.success,
            attributionProbeOk = attributionProbe.success,
            messengerTransportOk = messengerTransportProbe.success,
            castServiceOk = castServiceProbe.success,
            phoneContinuityOk = phoneContinuityProbe.success,
            phoneCallRelayServiceOk = phoneContinuityProbe.callRelayServiceOk,
            phoneMediaRelayCallbackOk = phoneContinuityProbe.mediaRelayCallbackOk,
            phoneRemoteDeviceCount = phoneContinuityProbe.remoteDeviceCount,
            phoneMediaRelayCandidateCount = phoneContinuityProbe.mediaRelayCandidateCount,
            services = serviceCatalog.services,
            preferredRoutes = serviceCatalog.preferredRoutes,
            summary = summary,
            ts = System.currentTimeMillis() / 1_000L
        )
    }

    private fun fallbackAfterShizukuAction(action: PendingShizukuAction) {
        val state = stateFlow.value
        when (action) {
            PendingShizukuAction.Notification -> {
                if (state.notificationSyncEnabled && (!state.notificationAccessGranted || !state.notificationPostGranted)) {
                    openNotificationSettingsDirect()
                }
            }
            PendingShizukuAction.RemoteInput -> {
                if (!state.remoteInputAccessGranted) {
                    openRemoteInputSettingsDirect()
                }
            }
            PendingShizukuAction.Screen -> {
                if (!state.screenDimmingAccessGranted) {
                    openScreenDimmingSettingsDirect()
                }
            }
            PendingShizukuAction.Sms,
            PendingShizukuAction.MiLinkProbe -> Unit
        }
    }

    private fun onShizukuStateChanged(reason: String) {
        EdgeLinkLog.info("shizuku.android.state_changed reason=$reason available=${AndroidShizukuSupport.currentState().available}")
        refreshNotificationAccess()
        if (AndroidShizukuSupport.hasPermission()) {
            runPendingShizukuAction()
            runShizukuAutoRepairIfReady(reason)
            runMiLinkRootProbeIfReady(reason)
        }
    }

    private fun runShizukuAutoRepairIfReady(reason: String) {
        val shizukuState = AndroidShizukuSupport.currentState()
        if (!shizukuState.canUse || shizukuState.uid != 0) {
            EdgeLinkLog.info(
                "shizuku.android.auto_repair_skip reason=$reason canUse=${shizukuState.canUse} uid=${shizukuState.uid}"
            )
            return
        }
        if (shizukuAutoRepairJob?.isActive == true) {
            EdgeLinkLog.info("shizuku.android.auto_repair_skip reason=$reason already_running=true")
            return
        }

        refreshNotificationAccess()
        val targets = shizukuAutoRepairTargets(stateFlow.value)
        if (targets.isEmpty()) {
            EdgeLinkLog.info("shizuku.android.auto_repair_skip reason=$reason missing=none")
            return
        }

        shizukuAutoRepairJob = scope.launch {
            EdgeLinkLog.info(
                "shizuku.android.auto_repair_start reason=$reason targets=${targets.joinToString()}"
            )
            val results = targets.map { target ->
                val result = runCatching {
                    when (target) {
                        ShizukuAutoRepairTarget.Notification ->
                            AndroidShizukuSupport.enableNotificationAccess(appContext)
                        ShizukuAutoRepairTarget.RemoteInput ->
                            AndroidShizukuSupport.enableRemoteInput(appContext)
                        ShizukuAutoRepairTarget.Screen ->
                            AndroidShizukuSupport.prepareScreenAccess(appContext)
                        ShizukuAutoRepairTarget.Sms ->
                            AndroidShizukuSupport.grantSmsPermissions(appContext)
                    }
                }.getOrElse { error ->
                    EdgeLinkLog.warn("shizuku.android.auto_repair_exception target=$target", error)
                    ShizukuOperationResult(success = false, message = error.message.orEmpty())
                }
                target to result
            }

            refreshNotificationAccess()
            val remaining = shizukuAutoRepairTargets(stateFlow.value)
            val failures = results.filterNot { (_, result) -> result.success }
            if (failures.isEmpty() && remaining.isEmpty()) {
                EdgeLinkLog.info(
                    "shizuku.android.auto_repair_ok reason=$reason repaired=${targets.joinToString()}"
                )
            } else {
                EdgeLinkLog.warn(
                    "shizuku.android.auto_repair_incomplete reason=$reason " +
                        "failed=${failures.joinToString { (target, result) -> "$target:${result.message}" }} " +
                        "remaining=${remaining.joinToString()}"
                )
            }
        }
    }

    private fun runMiLinkRootProbeIfReady(reason: String) {
        val state = AndroidShizukuSupport.currentState()
        if (!state.canUse || miLinkRootProbeAttempted) {
            EdgeLinkLog.info(
                "xiaomi.milink.root_probe_skip reason=$reason canUse=${state.canUse} " +
                    "uid=${state.uid} attempted=$miLinkRootProbeAttempted"
            )
            return
        }
        miLinkRootProbeAttempted = true
        EdgeLinkLog.info("xiaomi.milink.root_probe_start reason=$reason uid=${state.uid}")
        runShizukuAction(PendingShizukuAction.MiLinkProbe)
    }

    fun refreshNotificationAccess() {
        val shizukuState = AndroidShizukuSupport.currentState()
        stateFlow.update {
            it.copy(
                remoteInputAccessGranted = RemoteInputService.isEnabled(appContext),
                notificationAccessGranted = isNotificationListenerEnabled(),
                notificationPostGranted = AndroidNotificationPresenter.canPostNotifications(appContext),
                screenDimmingAccessGranted = AndroidScreenPowerGuard.hasRequiredScreenPowerAccess(appContext),
                screenSharePrivacyControlAvailable = AndroidScreenShareProtectionGuard.canControl(appContext),
                smsAccessGranted = smsSync.smsAccessGranted(),
                shizukuAvailable = shizukuState.available,
                shizukuSupported = shizukuState.supported,
                shizukuPermissionGranted = shizukuState.permissionGranted,
                shizukuPermissionRequestBlocked = shizukuState.permissionRequestBlocked,
                shizukuUid = shizukuState.uid,
                xiaomiMiLinkProbeStatus = if (shizukuState.canUse) {
                    it.xiaomiMiLinkProbeStatus ?: "尚未測試"
                } else {
                    null
                }
            )
        }
    }

    fun isNotificationListenerEnabled(): Boolean {
        return AndroidNotificationListenerService.isConnected()
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
        screenSession.onPermissionDenied()
    }

    private suspend fun run() {
        try {
            stateFlow.update {
                it.copy(
                    connectionStatus = "Registering",
                    connectionPhase = ConnectionPhase.Idle
                )
            }
            val identity = loadOrRegisterIdentity()
            localIdentity = identity
            stateFlow.update { it.copy(localDeviceId = DeviceId.display(identity.deviceId)) }
            EdgeLinkLog.info("runtime.android.identity deviceId=${identity.deviceId} pkfp=${EdgeLinkLog.fingerprint(identity.publicKey)}")

            val peer = pairingStore.loadPeers().firstOrNull()
            if (peer == null) {
                EdgeLinkLog.info("runtime.android.no_paired_peer")
                stateFlow.update {
                    it.copy(
                        connectionStatus = "No paired Mac",
                        connectionPhase = ConnectionPhase.Idle
                    )
                }
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
                it.copy(
                    connectionStatus = "Setup failed",
                    connectionPhase = ConnectionPhase.Disconnected,
                    isConnected = false
                )
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
                connectionStatus = "Opening pairing",
                connectionPhase = ConnectionPhase.Idle
            )
        }

        val channel = runCatching {
            pairingTransport.connect(EdgeLinkConfig.pairingWebSocketUrl, hostId)
        }.getOrElse { error ->
            EdgeLinkLog.error("pair.android.ws_connect_failed hostId=$hostId", error)
            stateFlow.update { state ->
                state.copy(
                    connectionStatus = "Pairing failed",
                    connectionPhase = ConnectionPhase.Idle,
                    isPairing = false
                )
            }
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
                                connectionStatus = "Compare code",
                                connectionPhase = ConnectionPhase.Idle
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
            stateFlow.update {
                it.copy(
                    connectionStatus = "Pairing failed",
                    connectionPhase = ConnectionPhase.Idle,
                    isPairing = false,
                    canConfirmPairing = false
                )
            }
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
                connectionStatus = "Paired",
                connectionPhase = ConnectionPhase.Idle
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
                connectionPhase = if (reason == "manual") ConnectionPhase.Reconnecting else it.connectionPhase,
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
                stateFlow.update {
                    it.copy(
                        connectionStatus = "Connecting relay",
                        connectionPhase = ConnectionPhase.Connecting,
                        isConnected = false
                    )
                }
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

                stateFlow.update {
                    it.copy(
                        connectionStatus = "Handshaking",
                        connectionPhase = ConnectionPhase.Handshaking
                    )
                }
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
                refreshTurnCredentials("relay_connected")
                sendLatestMiLinkStatus(nextSession, identity)
                micActivityMonitor.sendCurrent("session_connected")
                AndroidNotificationListenerService.requestActiveNotificationSync(appContext, "session_connected")
                retryDelayMs = 1_000L
                stateFlow.update {
                    it.copy(
                        connectionStatus = "Connected",
                        connectionPhase = ConnectionPhase.Connected,
                        isConnected = true
                    )
                }

                coroutineScope {
                    val pingJob = launch { pingLoop(nextSession) }
                    val clipboardJob = launch { clipboardLoop(nextSession) }
                    val smsPendingJob = launch { drainPendingSms(nextSession, identity, reason = "connected") }
                    val miLinkStatusJob = launch {
                        refreshAndSendMiLinkStatus(nextSession, identity, reason = "connected")
                    }
                    val miLinkMessengerJob = launch { miLinkMessengerLoop(nextSession, identity) }
                    try {
                        nextSession.receiveLoop(dispatcher::handle)
                    } finally {
                        pingJob.cancelAndJoin()
                        clipboardJob.cancelAndJoin()
                        smsPendingJob.cancelAndJoin()
                        miLinkStatusJob.cancelAndJoin()
                        miLinkMessengerJob.cancelAndJoin()
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
                        connectionPhase = if (autoReconnect) ConnectionPhase.Reconnecting else ConnectionPhase.Disconnected,
                        isConnected = false
                    )
                }
                if (!autoReconnect) {
                    EdgeLinkLog.info("relay.android.auto_reconnect_disabled hostId=${peer.deviceId} clientId=${identity.deviceId}")
                    return
                }
                if (!waitForAutoReconnect(retryDelayMs)) {
                    EdgeLinkLog.info("relay.android.auto_reconnect_stopped hostId=${peer.deviceId} clientId=${identity.deviceId}")
                    stateFlow.update {
                        it.copy(
                            connectionStatus = "Disconnected",
                            connectionPhase = ConnectionPhase.Disconnected,
                            isConnected = false
                        )
                    }
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

    private fun currentScreenIceServerConfigs(): List<AndroidScreenIceServerConfig> {
        val credentials = latestTurnCredentials ?: return emptyList()
        if (!credentials.isFresh()) {
            return emptyList()
        }
        val iceServers = credentials.iceServers
            .takeIf { it.isNotEmpty() }
            ?.map { server ->
                AndroidScreenIceServerConfig(
                    urls = server.urls,
                    username = server.username,
                    credential = server.credential
                )
            }
            ?: listOf(
                AndroidScreenIceServerConfig(
                    urls = credentials.urls,
                    username = credentials.username,
                    credential = credentials.credential
                )
            )
        return iceServers.filter { it.urls.isNotEmpty() }
    }

    private suspend fun ensureTurnCredentials(reason: String): TurnCredentialsResponse? {
        latestTurnCredentials?.takeIf { it.isFresh() }?.let { credentials ->
            EdgeLinkLog.info("turn.android.credentials_reuse reason=$reason ${credentials.diagnosticSummary()}")
            return credentials
        }
        val activeJob = turnCredentialJob
        if (activeJob?.isActive == true) {
            EdgeLinkLog.info("turn.android.credentials_join_inflight reason=$reason")
            activeJob.join()
            latestTurnCredentials?.takeIf { it.isFresh() }?.let { credentials ->
                EdgeLinkLog.info("turn.android.credentials_reuse_after_join reason=$reason ${credentials.diagnosticSummary()}")
                return credentials
            }
        }
        return fetchAndStoreTurnCredentials(reason)
    }

    private suspend fun fetchAndStoreTurnCredentials(reason: String): TurnCredentialsResponse? {
        val identity = localIdentity
        val peer = currentPeer
        if (identity == null || peer == null) {
            EdgeLinkLog.warn("turn.android.credentials_ignored reason=$reason hasIdentity=${identity != null} hasPeer=${peer != null}")
            return null
        }
        val generation = connectionGeneration.get()
        EdgeLinkLog.info("turn.android.credentials_fetch_start reason=$reason hostId=${peer.deviceId}")
        val result = runCatching {
            turnCredentialTransport.fetch(
                workerBaseUrl = EdgeLinkConfig.workerBaseUrl,
                hostId = peer.deviceId,
                identity = identity
            )
        }
        if (connectionGeneration.get() != generation) {
            EdgeLinkLog.warn("turn.android.credentials_discarded_stale reason=$reason hostId=${peer.deviceId}")
            return null
        }
        return result
            .onSuccess { credentials ->
                latestTurnCredentials = credentials
                EdgeLinkLog.info("turn.android.credentials_ready reason=$reason hostId=${peer.deviceId} ${credentials.diagnosticSummary()}")
            }
            .onFailure { error ->
                latestTurnCredentials = null
                EdgeLinkLog.error("turn.android.credentials_fetch_failed reason=$reason hostId=${peer.deviceId}", error)
            }
            .getOrNull()
    }

    private fun refreshTurnCredentials(reason: String) {
        latestTurnCredentials?.takeIf { it.isFresh() }?.let { credentials ->
            EdgeLinkLog.info("turn.android.credentials_reuse reason=$reason ${credentials.diagnosticSummary()}")
            return
        }
        if (turnCredentialJob?.isActive == true) {
            EdgeLinkLog.info("turn.android.credentials_join_inflight reason=$reason")
            return
        }
        turnCredentialJob = scope.launch {
            fetchAndStoreTurnCredentials(reason)
            turnCredentialJob = null
        }
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

    private suspend fun sendLatestMiLinkStatus(activeSession: SecureSessionClient, identity: LocalIdentity) {
        val status = latestMiLinkStatus ?: return
        sendMiLinkStatus(activeSession, identity, status, reason = "cached")
    }

    private suspend fun refreshAndSendMiLinkStatus(
        activeSession: SecureSessionClient,
        identity: LocalIdentity,
        reason: String
    ) {
        val status = runCatching {
            probeMiLinkStatus()
        }.getOrElse { error ->
            EdgeLinkLog.warn("milink.android.status_refresh_failed reason=$reason", error)
            return
        }
        latestMiLinkStatus = status
        stateFlow.update {
            it.copy(xiaomiMiLinkProbeStatus = status.summary)
        }
        sendMiLinkStatus(activeSession, identity, status, reason = reason)
    }

    private suspend fun sendMiLinkStatus(
        activeSession: SecureSessionClient,
        identity: LocalIdentity,
        status: MiLinkStatusBody,
        reason: String
    ) {
        val sourcedStatus = status.copy(sourceDeviceId = identity.deviceId)
        latestMiLinkStatus = sourcedStatus
        runCatching {
            activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.MILINK_STATUS, sourcedStatus))
            EdgeLinkLog.info(
                "milink.android.status_sent reason=$reason available=${sourcedStatus.available} " +
                    "messenger=${sourcedStatus.messengerTransportOk} cast=${sourcedStatus.castServiceOk} " +
                    "services=${sourcedStatus.services.count { it.available }}/${sourcedStatus.services.size} " +
                    "preferredRoutes=${sourcedStatus.preferredRoutes} " +
                    "phoneContinuity=${sourcedStatus.phoneContinuityOk} " +
                    "callRelay=${sourcedStatus.phoneCallRelayServiceOk} " +
                    "mediaRelayCallback=${sourcedStatus.phoneMediaRelayCallbackOk} " +
                    "phoneDevices=${sourcedStatus.phoneRemoteDeviceCount} " +
                    "mediaRelayCandidates=${sourcedStatus.phoneMediaRelayCandidateCount}"
            )
        }.onFailure { error ->
            EdgeLinkLog.error("milink.android.status_send_failed", error)
        }
    }

    private suspend fun miLinkMessengerLoop(activeSession: SecureSessionClient, identity: LocalIdentity) {
        var registeredClient: AndroidMiLinkMessengerTransport.RegisteredClient? = null
        var sequence = 0
        try {
            val registerResult = AndroidMiLinkMessengerTransport.register(appContext)
            val client = registerResult.client ?: run {
                EdgeLinkLog.warn("milink.android.messenger_bridge_register_failed code=${registerResult.code}")
                return
            }
            registeredClient = client
            EdgeLinkLog.info("milink.android.messenger_bridge_registered clientNo=${client.clientNo}")

            while (coroutineContext.isActive) {
                val poll = AndroidMiLinkMessengerTransport.poll(appContext, client.clientNo)
                if (poll.code != 0) {
                    EdgeLinkLog.warn(
                        "milink.android.messenger_bridge_poll_failed clientNo=${client.clientNo} code=${poll.code}"
                    )
                    delay(1_000)
                    continue
                }

                val data = poll.data
                if (data != null && data.isNotEmpty()) {
                    sequence += 1
                    val body = MiLinkFrameBody(
                        sourceDeviceId = identity.deviceId,
                        clientNo = client.clientNo,
                        sequence = sequence,
                        dataBase64 = Base64.getEncoder().encodeToString(data),
                        bytes = data.size,
                        hasNext = poll.hasNext,
                        ts = System.currentTimeMillis() / 1_000L
                    )
                    activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.MILINK_FRAME, body))
                    EdgeLinkLog.info(
                        "milink.android.frame_sent clientNo=${client.clientNo} " +
                            "seq=$sequence bytes=${data.size} hasNext=${poll.hasNext}"
                    )
                }

                if (!poll.hasNext) {
                    delay(1_000)
                }
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            EdgeLinkLog.error("milink.android.messenger_bridge_failed", error)
        } finally {
            registeredClient?.let { client ->
                val result = runCatching {
                    AndroidMiLinkMessengerTransport.unregister(appContext, client)
                }.getOrElse { error ->
                    "${error.javaClass.simpleName}:${error.message}"
                }
                EdgeLinkLog.info("milink.android.messenger_bridge_unregistered clientNo=${client.clientNo} result=$result")
            }
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
    private val phoneCallController: AndroidPhoneCallController,
    private val miLinkCommandBridge: AndroidMiLinkCommandBridge,
    private val onPong: () -> Unit,
    private val onSmsSendResult: (SmsSendResultBody) -> Unit,
    private val onScreenStartReceived: suspend () -> Unit,
    private val onPhoneActionReceived: (PhoneActionBody) -> Unit,
    private val onPhoneActionResult: (PhoneActionBody, PhoneActionResultBody) -> Unit,
    private val onPhoneRelayEndpoint: suspend (PhoneRelayEndpointBody) -> Unit
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
            EnvelopeTypes.PHONE_ACTION -> {
                val envelope = EnvelopeCodec.decode<PhoneActionBody>(plaintext)
                onPhoneActionReceived(envelope.b)
                val result = phoneCallController.handle(envelope.b)
                onPhoneActionResult(envelope.b, result)
                null
            }
            EnvelopeTypes.PHONE_RELAY_ENDPOINT -> {
                val envelope = EnvelopeCodec.decode<PhoneRelayEndpointBody>(plaintext)
                onPhoneRelayEndpoint(envelope.b)
                null
            }
            EnvelopeTypes.MILINK_COMMAND -> {
                val envelope = EnvelopeCodec.decode<MiLinkCommandBody>(plaintext)
                val result = miLinkCommandBridge.handle(envelope.b)
                EnvelopeCodec.encode(EnvelopeTypes.MILINK_COMMAND_RESULT, result)
            }
            EnvelopeTypes.SCREEN_START -> {
                onScreenStartReceived()
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
    const val callRelayGatewayHost = "172.238.24.219"
    const val callRelayGatewayControlPort = 17104
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
