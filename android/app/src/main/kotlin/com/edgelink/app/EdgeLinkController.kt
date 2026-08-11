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
import com.edgelink.core.BatteryStatusBody
import com.edgelink.core.ClipboardBlobChunkBody
import com.edgelink.core.ClipboardBlobReassembler
import com.edgelink.core.ClipboardBlobRequestBody
import com.edgelink.core.ClipboardBlobTransfer
import com.edgelink.core.ClipboardHistoryItemBody
import com.edgelink.core.ClipboardHistoryRequestBody
import com.edgelink.core.ClipboardHistoryResponseBody
import com.edgelink.core.ClipboardKind
import com.edgelink.core.ClipboardSetBody
import com.edgelink.core.StatusCapsBody
import com.edgelink.core.StatusPingBody
import com.edgelink.core.StatusPongBody
import com.edgelink.core.PhoneLockStateBody
import com.edgelink.core.RelayDatagramBody
import com.edgelink.core.CtrlGlobalBody
import com.edgelink.core.CtrlKeyBody
import com.edgelink.core.CtrlPointerBody
import com.edgelink.core.CtrlTextBody
import com.edgelink.core.DeviceId
import com.edgelink.core.EmptyBody
import com.edgelink.core.XiaomiTrustStatusBody
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.InputKeyBody
import com.edgelink.core.InputPointerBody
import com.edgelink.core.InputTextBody
import com.edgelink.core.LocalIdentity
import com.edgelink.core.MiLinkCommandBody
import com.edgelink.core.MiLinkCommandResultBody
import com.edgelink.core.MiLinkFrameBody
import com.edgelink.core.TunnelCloseBody
import com.edgelink.core.TunnelDataBody
import com.edgelink.core.TunnelErrorBody
import com.edgelink.core.TunnelFlowBody
import com.edgelink.core.TunnelOpenBody
import com.edgelink.core.TunnelOpenResultBody
import com.edgelink.core.MiLinkMirrorMediaBody
import com.edgelink.core.MiLinkMirrorRtcIceBody
import com.edgelink.core.MiLinkMirrorRtcOfferBody
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
import com.edgelink.core.PhoneRelayMediaBody
import com.edgelink.core.PhotoAckBody
import com.edgelink.core.PhotoBeginBody
import com.edgelink.core.PhotoChunkBody
import com.edgelink.core.PhotoManifestBody
import com.edgelink.core.PhotoManifestItemBody
import com.edgelink.core.PhotoRequestBody
import com.edgelink.core.PhotoStatusBody
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
import com.edgelink.transport.LANSessionTransport
import com.edgelink.transport.LANTransport
import com.edgelink.transport.PairingTransport
import com.edgelink.transport.PresenceTransport
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
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeoutOrNull
import rikka.shizuku.Shizuku
import kotlin.coroutines.coroutineContext
import java.time.Instant
import java.util.Base64
import java.util.concurrent.atomic.AtomicInteger

private const val HANDSHAKE_TIMEOUT_MS = 4_000L
private const val RELAY_CONNECT_TIMEOUT_MS = 8_000L
private const val LAN_CONNECT_TIMEOUT_MS = 4_000L
private const val LAN_DISCOVERY_WAIT_MS = 2_000L
private const val MAX_AUTO_RECONNECT_DELAY_MS = 5_000L
private const val PING_INTERVAL_MS = 5_000L
private const val PONG_TIMEOUT_MS = 15_000L
private const val MAC_SLEEP_PRESENCE_POLL_INTERVAL_MS = 2 * 60_000L
private const val MAC_SLEEP_UNKNOWN_POLLS_BEFORE_PROBE = 5
private const val MAC_PRESENCE_FRESH_SECONDS = 1_800L
private const val MILINK_COMMAND_MIRROR_START_MAIN_DISPLAY = "xiaomi.mirror.startMainDisplay"
private const val MILINK_COMMAND_MIRROR_SOURCE_RECOVERY = "xiaomi.mirror.requestSourceRecovery"
private const val MESH_PORT_PREFS = "edgelink_mesh_ports"
private const val KEY_LAST_RESPONSIVE_MESH_PORT = "lastResponsiveMeshPort"
private const val DEBUG_SMS_SEND_TIMEOUT_MS = 12_000L
private const val CALL_RELAY_BRIDGE_DIAL_DELAY_MS = 2_000L
private const val CALL_RELAY_BRIDGE_ANSWER_DELAY_MS = 750L
private const val XIAOMI_MIRROR_CAST_ROUTE = "xiaomi.mirror.cast"
private const val XIAOMI_MIRROR_CAST_CLIENT = "com.xiaomi.mirror/cast"

private fun elapsedMs(startedAtNanos: Long, endedAtNanos: Long = SystemClock.elapsedRealtimeNanos()): Long =
    (endedAtNanos - startedAtNanos) / 1_000_000L

private enum class PendingShizukuAction {
    Notification,
    RemoteInput,
    Screen,
    Sms,
    MiLinkProbe
}

private enum class MacPresenceState {
    Awake,
    Sleeping,
    Unknown
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
    private val lanSessionTransport = LANSessionTransport(appContext).also { it.startDiscovery() }
    private val turnCredentialTransport = TurnCredentialTransport(crypto = crypto)
    private val presenceTransport = PresenceTransport(crypto = crypto)
    private val pairingTransport = PairingTransport()
    private val clipboardSync = AndroidClipboardSync(appContext)
    private val clipboardHistoryStore = ClipboardHistoryStore(appContext)
    @Volatile
    private var peerCapabilityHistory = false
    @Volatile
    private var peerCapabilityThumbnail = false
    private var peerCapabilityBlob = false
    @Volatile
    private var peerCapabilityMirrorTurn = false
    private var mirrorTurnSession: AndroidMirrorTurnSession? = null
    private val clipboardBlobReassembler = ClipboardBlobReassembler()
    private var pendingClipboardBlobId: String? = null
    private var pendingClipboardBlobCallback: ((Boolean) -> Unit)? = null
    private var pendingClipboardBlobTimeoutJob: Job? = null
    private val notificationPresenter = AndroidNotificationPresenter(appContext)
    private val smsSync = AndroidSmsSync(appContext, settingsStore)
    private val photoSync = AndroidPhotoSync(appContext, settingsStore)
    private val phoneCallController = AndroidPhoneCallController(appContext)
    private val miLinkCommandBridge = AndroidMiLinkCommandBridge(
        appContext,
        onMirrorCloudBridgeRequested = { request ->
            startMiLinkMirrorCloudBridge(request)
        },
        onMirrorCloudBridgeStopRequested = { reason ->
            AndroidMiLinkMirrorMediaBridge.stop(reason)
        },
        peerMirrorTurnDataChannelSupported = { peerCapabilityMirrorTurn }
    )
    private val miLinkScreenPowerGuard = AndroidScreenPowerGuard(appContext)
    private val micActivityMonitor = AndroidMicActivityMonitor(appContext) { status: AndroidMicStatusBody ->
        sendEnvelope(EnvelopeTypes.ANDROID_MIC_STATUS, status)
    }
    private val batteryReporter = AndroidBatteryReporter(appContext) { status: BatteryStatusBody ->
        sendEnvelope(EnvelopeTypes.BATTERY_STATUS, status)
    }
    private val lockStateReporter = AndroidLockStateReporter(appContext) { body: PhoneLockStateBody ->
        sendEnvelope(EnvelopeTypes.PHONE_LOCK_STATE, body)
    }
    private val xiaomiMirrorScreenConfigReporter = EdgeLinkXiaomiMirrorScreenConfigReporter(
        context = appContext,
        onFrame = ::onXiaomiMirrorCastFrame
    )
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
            xiaomiMiLinkProbeStatus = if (initialShizukuState.canUse) appContext.getString(R.string.milink_probe_not_tested) else null
        )
    )
    private val dispatcher = AndroidCommandDispatcher(
        context = appContext,
        clipboardSync = clipboardSync,
        clipboardHistoryStore = clipboardHistoryStore,
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
        onScreenStopReceived = {
            stopMiLinkScreenPowerGuard()
        },
        onMirrorTurnSessionStop = {
            closeMirrorTurnSession("screen_stop")
        },
        onMiLinkCommandResult = { body, result ->
            handleMiLinkCommandResult(body, result)
        },
        onPhoneActionReceived = { body ->
            if (body.action == "dial" || body.action == "answer") {
                refreshTurnCredentials("phone_action_${body.action}")
                startCallRelayBridge(body, reason = "phone_action_received_${body.action}")
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
        onPhoneRelayMedia = { body ->
            AndroidCallRelayBridge.handleMedia(body)
        },
        onMacSleep = {
            handleMacSleep()
        },
        onMacAwake = {
            handleMacAwake()
        },
        onMiLinkMirrorRtcOffer = { body ->
            handleMiLinkMirrorRtcOffer(body)
        },
        onMiLinkMirrorRtcIce = { body ->
            mirrorTurnSession?.handleIce(body)
        },
        onTunnelEnvelope = { type, body ->
            tunnelManager.handleEnvelope(type, body)
        },
        onLyraRelayDatagram = { type, body ->
            lyraRelayBridge.handleEnvelope(type, body)
        },
        onStatusCaps = { caps ->
            handleStatusCaps(caps)
        },
        onClipboardHistoryResponse = { response ->
            handleClipboardHistoryResponse(response)
        },
        onClipboardBlobRequest = { request ->
            handleClipboardBlobRequest(request)
        },
        onClipboardBlobChunk = { chunk ->
            handleClipboardBlobChunk(chunk)
        },
        onClipboardSetApplied = {
            refreshClipboardHistory()
        },
        onPhotoRequest = { body ->
            handlePhotoRequest(body)
        },
        onPhotoAck = { body ->
            handlePhotoAck(body)
        },
        onPhotoSyncRequest = {
            launchPhotoSync("manual_remote")
        },
        onXiaomiTrustStatus = { body ->
            stateFlow.update { it.copy(xiaomiTrustPaired = body.paired) }
        }
    )

    private val tunnelManager = AndroidTunnelManager(
        scope = scope,
        sendEnvelope = { type, body ->
            sendTunnelEnvelope(type, body)
        }
    )

    // Native Xiaomi mesh/channel datagrams carried over the relay session.
    // Active only while connected via the cloud relay; on LAN the Mac reaches
    // the phone's Xiaomi endpoints directly.
    private val lyraRelayBridge = AndroidLyraRelayTransportBridge(
        scope = scope,
        sendEnvelope = { type, body ->
            sendLyraRelayEnvelope(type, body)
        },
        onMeshTargetResponsive = { port ->
            recordResponsiveMeshPort(port)
        },
        // Present the relay-carried cast channel from the phone's LAN address
        // (when it has one) so MirrorControl binds its WFD RTSP source to the
        // LAN interface — that keeps lan_direct media viable even though the
        // control session rides the cloud relay. Loopback when there is no
        // LAN (true remote case), matching the pre-LAN behavior.
        channelTargetHost = { LANTransport.preferredLocalIPv4Address() ?: "127.0.0.1" }
    )

    val state: StateFlow<EdgeLinkUiState> = stateFlow

    @Volatile
    private var session: SecureSessionClient? = null
    private var localIdentity: LocalIdentity? = null
    private var currentPeer: PinnedPeer? = null
    private var connectionJob: Job? = null
    private var pairingJob: Job? = null
    private var smsPendingDrainJob: Job? = null
    private var photoSyncJob: Job? = null
    private var photoSendJob: Job? = null
    @Volatile
    private var pendingPhotoItems: Map<String, AndroidPhotoSync.MediaItem> = emptyMap()
    private var shizukuAutoRepairJob: Job? = null
    private var turnCredentialJob: Job? = null
    private var pendingCallRelayBridgeJob: Job? = null
    private var pendingPairing: PendingPairing? = null
    private var pendingShizukuAction: PendingShizukuAction? = null
    @Volatile
    private var latestMiLinkStatus: MiLinkStatusBody? = null
    @Volatile
    private var latestXiaomiMirrorCastFrame: ByteArray? = null
    private val xiaomiMirrorCastSequence = AtomicInteger(0)
    @Volatile
    private var latestTurnCredentials: TurnCredentialsResponse? = null
    @Volatile
    private var phoneRelayCallSessionActive = false
    private var miLinkRootProbeAttempted = false
    @Volatile
    private var manuallyDisconnected = false
    @Volatile
    private var macSleepSuppressed = false
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
        batteryReporter.start()
        lockStateReporter.start()
        xiaomiMirrorScreenConfigReporter.start()
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
        batteryReporter.stop()
        lockStateReporter.stop()
        xiaomiMirrorScreenConfigReporter.stop()
        screenSession.shutdown()
        turnCredentialJob?.cancel()
        pendingCallRelayBridgeJob?.cancel()
        pendingCallRelayBridgeJob = null
        latestTurnCredentials = null
        closeMirrorTurnSession("shutdown")
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

    fun onXiaomiMirrorCastFrame(frame: ByteArray) {
        val retainedFrame = frame.copyOf()
        latestXiaomiMirrorCastFrame = retainedFrame
        EdgeLinkLog.info("xiaomi.mirror.cast_frame_received bytes=${retainedFrame.size}")
        val identity = localIdentity ?: return
        sendXiaomiMirrorCastFrame(retainedFrame, identity, reason = "live")
    }

    private fun scheduleCallRelayBridgeStart(body: PhoneActionBody) {
        pendingCallRelayBridgeJob?.cancel()
        val delayMs = when (body.action) {
            "answer" -> CALL_RELAY_BRIDGE_ANSWER_DELAY_MS
            else -> CALL_RELAY_BRIDGE_DIAL_DELAY_MS
        }
        pendingCallRelayBridgeJob = scope.launch {
            EdgeLinkLog.info("callrelay.android.bridge_start_delayed action=${body.action} delayMs=$delayMs")
            delay(delayMs)
            startCallRelayBridge(body, reason = "phone_action_result_${body.action}")
            pendingCallRelayBridgeJob = null
        }
    }

    private fun startCallRelayBridge(body: PhoneActionBody, reason: String) {
        AndroidCallRelayBridge.start(body, reason) { media ->
            val activeSession = session ?: return@start
            runCatching {
                activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.PHONE_RELAY_MEDIA, media))
            }.onFailure { error ->
                EdgeLinkLog.warn(
                    "callrelay.android.media_send_failed kind=${media.kind} " +
                        "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                )
            }
        }
    }

    private fun startMiLinkMirrorCloudBridge(request: AndroidMiLinkMirrorCloudBridgeRequest) {
        if (!request.turnMode) {
            closeMirrorTurnSession("cloud_bridge_ws_mode")
        }
        AndroidMiLinkMirrorMediaBridge.start(request) { media: MiLinkMirrorMediaBody ->
            val activeSession = session ?: return@start
            runCatching {
                activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.MILINK_MIRROR_MEDIA, media))
            }.onFailure { error ->
                EdgeLinkLog.warn(
                    "xiaomi.mirror.android.cloudflare_media_send_failed kind=${media.kind} " +
                        "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                )
            }
        }
    }

    private fun closeMirrorTurnSession(reason: String) {
        val active = mirrorTurnSession
        mirrorTurnSession = null
        active?.close(reason)
    }

    private suspend fun handleMiLinkMirrorRtcOffer(body: MiLinkMirrorRtcOfferBody) {
        closeMirrorTurnSession("replace")
        val credentials = ensureTurnCredentials("mirror_turn_offer")
        if (credentials == null || !credentials.isFresh()) {
            EdgeLinkLog.warn("mirror.turn.dc_failed sessionId=${body.sessionId} reason=no_turn_credentials")
            AndroidMiLinkMirrorMediaBridge.switchToWebSocketFallback("no_turn_credentials")
            return
        }
        val turnSessionRef = arrayOfNulls<AndroidMirrorTurnSession>(1)
        val turnSession = AndroidMirrorTurnSession(
            context = appContext,
            sessionId = body.sessionId,
            iceServers = currentScreenIceServerConfigs(),
            sendPlaintext = ::sendPlaintext,
            onDatagram = { data ->
                AndroidMiLinkMirrorMediaBridge.handleTurnDatagram(data)
            },
            onDataChannelOpen = {
                val attached = AndroidMiLinkMirrorMediaBridge.attachTurnDataChannel(
                    sessionId = body.sessionId,
                    sendDatagram = { data -> mirrorTurnSession?.send(data) ?: false },
                    dcBufferedBytes = { mirrorTurnSession?.bufferedAmount() ?: 0L },
                    dcPathIsRelay = { mirrorTurnSession?.isRelayPath() }
                )
                if (!attached) {
                    mirrorTurnSession?.close("bridge_attach_rejected")
                }
            },
            onFailed = { reason ->
                // Guard against stale sessions: when a new cloud session
                // replaces this one, close() fires dc_failed asynchronously;
                // by then the bridge is retargeted to the new session and a
                // fallback signal here would poison it (live 2026-08-08:
                // the old dc's close flipped the retargeted bridge into WS
                // fallback and its fresh TURN channel was attach_rejected).
                if (mirrorTurnSession === turnSessionRef[0]) {
                    AndroidMiLinkMirrorMediaBridge.switchToWebSocketFallback("signal_$reason")
                } else {
                    EdgeLinkLog.info(
                        "mirror.turn.dc_failed_stale sessionId=${body.sessionId} reason=$reason"
                    )
                }
            }
        )
        mirrorTurnSession = turnSession
        turnSessionRef[0] = turnSession
        turnSession.handleOffer(body)
    }

    private fun handleMiLinkCommandResult(body: MiLinkCommandBody, result: MiLinkCommandResultBody) {
        val startPending = (body.command == MILINK_COMMAND_MIRROR_START_MAIN_DISPLAY ||
            body.command == MILINK_COMMAND_MIRROR_SOURCE_RECOVERY) &&
            result.route == "xiaomi.mirror.pending"
        if (!result.success && !startPending) {
            return
        }
        // The mirror now runs the native path end to end (cast channel
        // OPEN_MIRROR_SCREEN + the phone's real WFD source); HyperOS owns the
        // screen/dim/hangup behavior. Do NOT engage the EdgeLink screen power
        // guard here: its 5s dim throttles the MirrorControl encoder into slow
        // motion (observed 0.5x media clock + video starvation on the relay
        // path), and its rapid start/stop raced ScreenPowerForegroundService
        // into FGS-timeout crashes.
    }

    private fun stopMiLinkScreenPowerGuard() {
        scope.launch {
            miLinkScreenPowerGuard.onSharingStopped()
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
        macSleepSuppressed = false
        connectionGeneration.incrementAndGet()
        connectionJob?.cancel()
        connectionJob = null
        turnCredentialJob?.cancel()
        turnCredentialJob = null
        latestTurnCredentials = null
        session?.close()
        session = null
        lyraRelayBridge.stop()
        AndroidMiLinkMirrorMediaBridge.stop("disconnect")
        closeMirrorTurnSession("disconnect")
        stopMiLinkScreenPowerGuard()
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

    override fun onPhotoSyncChange(enabled: Boolean) {
        settingsStore.savePhotoSyncEnabled(enabled)
        stateFlow.update {
            it.copy(
                photoSyncEnabled = enabled,
                photoMediaAccessGranted = photoSync.hasPermission()
            )
        }
        EdgeLinkLog.info("photo.android.sync_enabled enabled=$enabled")
        if (enabled) {
            launchPhotoSync("toggle_on")
        }
    }

    override fun onPhotoSyncNow() {
        refreshPhotoAccess()
        launchPhotoSync("manual_button")
    }

    override fun onRequestPhotoAccess() {
        refreshPhotoAccess()
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

    override fun onXiaomiTrustPair() {
        sendEnvelope(EnvelopeTypes.XIAOMI_TRUST_BIND, EmptyBody)
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

    private suspend fun probeLyraMeshPorts(): List<Int> {
        val uid = LyraMeshPortProbe.uid(appContext) ?: return emptyList()
        val hasShizuku = AndroidShizukuSupport.hasPermission()
        val result = if (hasShizuku) {
            AndroidShizukuSupport.runShellCommand(
                appContext,
                arrayOf("sh", "-c", "cat /proc/net/udp /proc/net/udp6")
            )
        } else {
            null
        }
        EdgeLinkLog.info(
            "lyra.android.mesh_ports_probe hasShizuku=$hasShizuku resultExit=${result?.exitCode} " +
                "stdoutLen=${result?.stdout?.length} stderr=${result?.stderr?.take(80)}"
        )
        if (result != null && result.success) {
            val uidPorts = LyraMeshPortProbe.parse(result.stdout.lines(), uid)
            // The UID filter can't tell the Lyra processes apart (all share
            // android.uid.system): rank by owning process via ss so the main
            // mi_connect_service mesh dial sorts first. 2026-08-08: the
            // Mirror app's 9876/10158 sockets out-sorted the real mesh port
            // 50426 and the relay-cast phys sync went to a dead endpoint.
            val ssResult = AndroidShizukuSupport.runShellCommand(
                appContext,
                arrayOf("sh", "-c", "ss -ulpn")
            )
            val ranked = if (ssResult != null && ssResult.success) {
                LyraMeshPortProbe.parseSs(ssResult.stdout.lines())
            } else {
                emptyList()
            }
            val ports = ranked.filter { it in uidPorts } + uidPorts.filter { it !in ranked }
            EdgeLinkLog.info("lyra.android.mesh_ports source=shizuku ports=$ports")
            return ports
        }
        val fallback = LyraMeshPortProbe.probeWildcardUdpPorts(appContext)
        EdgeLinkLog.info("lyra.android.mesh_ports source=proc ports=$fallback")
        return fallback
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
            lyraMeshPorts = probeLyraMeshPorts(),
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
            photoSyncEnabled = settingsStore.photoSyncEnabled(),
            photoMediaAccessGranted = photoSync.hasPermission(),
                shizukuAvailable = shizukuState.available,
                shizukuSupported = shizukuState.supported,
                shizukuPermissionGranted = shizukuState.permissionGranted,
                shizukuPermissionRequestBlocked = shizukuState.permissionRequestBlocked,
                shizukuUid = shizukuState.uid,
                xiaomiMiLinkProbeStatus = if (shizukuState.canUse) {
                    it.xiaomiMiLinkProbeStatus ?: appContext.getString(R.string.milink_probe_not_tested)
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
        macSleepSuppressed = false
        val generation = connectionGeneration.incrementAndGet()
        EdgeLinkLog.info(
            "relay.android.connection_start reason=$reason hostId=${peer.deviceId} clientId=${identity.deviceId} autoReconnect=${stateFlow.value.autoReconnectEnabled}"
        )
        connectionJob?.cancel()
        AndroidMiLinkMirrorMediaBridge.stop("connection_restart")
        closeMirrorTurnSession("connection_restart")
        stopMiLinkScreenPowerGuard()
        screenSession.stop()
        session?.close()
        session = null
        lyraRelayBridge.stop()
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

        if (stateFlow.value.autoReconnectEnabled && !macSleepSuppressed &&
            fetchMacPresence(identity, peer) == MacPresenceState.Sleeping
        ) {
            EdgeLinkLog.info("relay.android.mac_sleep_presence_startup hostId=${peer.deviceId}")
            macSleepSuppressed = true
            stateFlow.update {
                it.copy(
                    connectionStatus = "Mac sleeping",
                    connectionPhase = ConnectionPhase.Disconnected,
                    isConnected = false
                )
            }
            if (!waitForMacAwake(identity, peer, generation)) {
                EdgeLinkLog.info("relay.android.mac_sleep_wait_stopped hostId=${peer.deviceId} clientId=${identity.deviceId}")
                stateFlow.update {
                    it.copy(
                        connectionStatus = "Disconnected",
                        connectionPhase = ConnectionPhase.Disconnected,
                        isConnected = false
                    )
                }
                return
            }
        }

        while (coroutineContext.isActive && connectionGeneration.get() == generation) {
            var channel: ByteChannel? = null
            try {
                EdgeLinkLog.info("relay.android.connect_start hostId=${peer.deviceId} clientId=${identity.deviceId}")
                if (!macSleepSuppressed) {
                    stateFlow.update {
                        it.copy(
                            connectionStatus = "Connecting relay",
                            connectionPhase = ConnectionPhase.Connecting,
                            isConnected = false
                        )
                    }
                }
                channel = withTimeoutOrNull(LAN_CONNECT_TIMEOUT_MS) {
                    val endpoint = lanSessionTransport.currentEndpoint()
                        ?: lanSessionTransport.awaitEndpoint(LAN_DISCOVERY_WAIT_MS)
                    endpoint?.let {
                        EdgeLinkLog.info("lan.android.connect_start host=${it.host} port=${it.port}")
                        runCatching {
                            lanSessionTransport.connect(it.host, it.port)
                        }.onFailure { error ->
                            EdgeLinkLog.warn(
                                "lan.android.connect_failed host=${it.host} port=${it.port} " +
                                    "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                            )
                        }.getOrNull()
                    }
                }
                if (channel == null) {
                    EdgeLinkLog.info("lan.android.unavailable_fallback_relay hostId=${peer.deviceId}")
                }
                if (channel == null) {
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

                if (!macSleepSuppressed) {
                    stateFlow.update {
                        it.copy(
                            connectionStatus = "Handshaking",
                            connectionPhase = ConnectionPhase.Handshaking
                        )
                    }
                }
                val handshakeEstablished = coroutineScope {
                    val handshake = async { nextSession.connect() }
                    val completed = withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) {
                        handshake.await()
                        true
                    } == true
                    if (!completed) {
                        nextSession.close()
                        handshake.cancelAndJoin()
                    }
                    completed
                }
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
                macSleepSuppressed = false
                session = nextSession
                refreshTurnCredentials("relay_connected")
                sendLatestMiLinkStatus(nextSession, identity)
                latestXiaomiMirrorCastFrame?.let { frame ->
                    sendXiaomiMirrorCastFrame(frame, identity, reason = "cached")
                }
                micActivityMonitor.sendCurrent("session_connected")
                batteryReporter.sendCurrent("session_connected")
                lockStateReporter.sendCurrent("session_connected")
                sendStatusCapsAndRequestHistory(identity)
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
                    val clipboardJob = launch { clipboardLoop(nextSession, identity) }
                    val smsSyncJob = launch {
                        val backfilledKeys = runSmsBackfill(nextSession, identity)
                        drainPendingSms(nextSession, identity, reason = "connected", skipKeys = backfilledKeys)
                    }
                    val miLinkStatusJob = launch {
                        refreshAndSendMiLinkStatus(nextSession, identity, reason = "connected")
                    }
                    val miLinkMessengerJob = launch { miLinkMessengerLoop(nextSession, identity) }
                    try {
                        nextSession.receiveLoop(dispatcher::handle)
                    } finally {
                        pingJob.cancelAndJoin()
                        clipboardJob.cancelAndJoin()
                        smsSyncJob.cancelAndJoin()
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
                // Keep the local mirror bridge and keeper alive across relay
                // reconnects: they own the local RTSP session to the Xiaomi
                // capture source, and tearing it down wedges the encoder
                // (stock startShare cannot revive the fake remote). The bridge
                // send closure no-ops while session is null and re-binds on
                // the next startMainDisplay.
                stopMiLinkScreenPowerGuard()
                screenSession.stop()
                val autoReconnect = stateFlow.value.autoReconnectEnabled && !manuallyDisconnected
                if (autoReconnect && !macSleepSuppressed &&
                    fetchMacPresence(identity, peer) == MacPresenceState.Sleeping
                ) {
                    EdgeLinkLog.info("relay.android.mac_sleep_presence_reconcile hostId=${peer.deviceId}")
                    macSleepSuppressed = true
                }
                val sleepSuppressed = macSleepSuppressed && autoReconnect
                stateFlow.update {
                    it.copy(
                        connectionStatus = when {
                            sleepSuppressed -> "Mac sleeping"
                            autoReconnect -> "Reconnecting"
                            else -> "Disconnected"
                        },
                        connectionPhase = if (autoReconnect && !sleepSuppressed) ConnectionPhase.Reconnecting else ConnectionPhase.Disconnected,
                        isConnected = false
                    )
                }
                if (!autoReconnect) {
                    EdgeLinkLog.info("relay.android.auto_reconnect_disabled hostId=${peer.deviceId} clientId=${identity.deviceId}")
                    return
                }
                if (sleepSuppressed) {
                    if (!waitForMacAwake(identity, peer, generation)) {
                        EdgeLinkLog.info("relay.android.mac_sleep_wait_stopped hostId=${peer.deviceId} clientId=${identity.deviceId}")
                        stateFlow.update {
                            it.copy(
                                connectionStatus = "Disconnected",
                                connectionPhase = ConnectionPhase.Disconnected,
                                isConnected = false
                            )
                        }
                        return
                    }
                } else {
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
                }
            } finally {
                channel?.close()
            }
        }
    }

    private suspend fun waitForAutoReconnect(delayMs: Long): Boolean {
        if (!stateFlow.value.autoReconnectEnabled) {
            return false
        }
        while (autoReconnectWakeups.tryReceive().isSuccess) {
        }
        val woke = withTimeoutOrNull(delayMs) {
            autoReconnectWakeups.receive()
            true
        } == true
        EdgeLinkLog.info("relay.android.auto_reconnect_wait_done delayMs=$delayMs woke=$woke")
        return stateFlow.value.autoReconnectEnabled
    }

    private suspend fun waitForMacAwake(identity: LocalIdentity, peer: PinnedPeer, generation: Int): Boolean {
        var unknownPolls = 0
        while (autoReconnectWakeups.tryReceive().isSuccess) {
        }
        while (coroutineContext.isActive && connectionGeneration.get() == generation && macSleepSuppressed) {
            val woke = withTimeoutOrNull(MAC_SLEEP_PRESENCE_POLL_INTERVAL_MS) {
                autoReconnectWakeups.receive()
                true
            } == true
            if (woke) {
                EdgeLinkLog.info("relay.android.mac_sleep_wait_wakeup")
                return stateFlow.value.autoReconnectEnabled
            }
            if (!stateFlow.value.autoReconnectEnabled || manuallyDisconnected) {
                return false
            }
            when (fetchMacPresence(identity, peer)) {
                MacPresenceState.Awake -> {
                    EdgeLinkLog.info("relay.android.mac_sleep_presence_awake hostId=${peer.deviceId}")
                    return true
                }
                MacPresenceState.Sleeping -> unknownPolls = 0
                MacPresenceState.Unknown -> {
                    unknownPolls += 1
                    if (unknownPolls >= MAC_SLEEP_UNKNOWN_POLLS_BEFORE_PROBE) {
                        EdgeLinkLog.info("relay.android.mac_sleep_presence_unknown_probe hostId=${peer.deviceId}")
                        return true
                    }
                }
            }
        }
        return stateFlow.value.autoReconnectEnabled
    }

    private suspend fun fetchMacPresence(identity: LocalIdentity, peer: PinnedPeer): MacPresenceState {
        return runCatching {
            presenceTransport.fetch(
                workerBaseUrl = EdgeLinkConfig.workerBaseUrl,
                hostId = peer.deviceId,
                identity = identity
            )
        }.onFailure { error ->
            EdgeLinkLog.warn("presence.android.fetch_failed error=${error.message}")
        }.map { response ->
            val ageSeconds = Instant.now().epochSecond - response.updatedAt
            when {
                response.state == "sleeping" -> MacPresenceState.Sleeping
                response.state == "awake" && ageSeconds <= MAC_PRESENCE_FRESH_SECONDS -> MacPresenceState.Awake
                else -> MacPresenceState.Unknown
            }
        }.getOrDefault(MacPresenceState.Unknown)
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

    private fun handleMacSleep() {
        EdgeLinkLog.info("relay.android.mac_sleep_received")
        macSleepSuppressed = true
        stopMiLinkScreenPowerGuard()
        session?.close()
        stateFlow.update {
            it.copy(
                connectionStatus = "Mac sleeping",
                connectionPhase = ConnectionPhase.Disconnected,
                isConnected = false
            )
        }
    }

    private fun handleMacAwake() {
        EdgeLinkLog.info("relay.android.mac_awake_received")
        macSleepSuppressed = false
        signalAutoReconnect("mac_awake")
    }

    fun notifyAppForegrounded() {
        if (macSleepSuppressed) {
            EdgeLinkLog.info("relay.android.mac_sleep_foreground_probe")
            signalAutoReconnect("app_foregrounded")
        }
    }

    private suspend fun pingLoop(activeSession: SecureSessionClient) {
        while (coroutineContext.isActive) {
            val pongAgeMs = SystemClock.elapsedRealtime() - lastPongElapsedMs
            val inboundAgeMs = activeSession.inboundIdleMilliseconds()
            val livenessAgeMs = minOf(pongAgeMs, inboundAgeMs)
            if (lastPongElapsedMs > 0 && livenessAgeMs >= PONG_TIMEOUT_MS) {
                EdgeLinkLog.warn(
                    "relay.android.pong_timeout ageMs=$livenessAgeMs pongAgeMs=$pongAgeMs " +
                        "inboundAgeMs=$inboundAgeMs timeoutMs=$PONG_TIMEOUT_MS"
                )
                error("Secure relay timed out after ${livenessAgeMs}ms without inbound activity.")
            }
            activeSession.sendPlaintext(
                EnvelopeCodec.encode(EnvelopeTypes.STATUS_PING, StatusPingBody(t0 = System.currentTimeMillis()))
            )
            delay(PING_INTERVAL_MS)
        }
    }

    private suspend fun clipboardLoop(activeSession: SecureSessionClient, identity: LocalIdentity) {
        while (coroutineContext.isActive) {
            val snapshot = clipboardSync.pollLocalClip()
            if (snapshot != null) {
                val deviceId = identity.deviceId
                val historyId = "$deviceId#${snapshot.timestampSeconds}-0"
                snapshot.blobData?.let { blobData ->
                    clipboardHistoryStore.saveBlob(historyId, snapshot.blobMime, blobData)
                }
                clipboardHistoryStore.append(
                    ClipboardHistoryItemBody(
                        id = historyId,
                        kind = snapshot.kind.wireName,
                        ts = snapshot.timestampSeconds,
                        hash = snapshot.hash,
                        text = snapshot.text.ifEmpty { null },
                        thumbnailBase64 = snapshot.thumbnailBase64,
                        sourceDeviceId = deviceId
                    )
                )
                clipboardHistoryStore.prune()
                refreshClipboardHistory()

                val shouldSend: Boolean
                val thumbnailForWire: String?
                when (snapshot.kind) {
                    ClipboardKind.TEXT, ClipboardKind.HTML -> {
                        shouldSend = true
                        thumbnailForWire = null
                    }
                    ClipboardKind.IMAGE -> {
                        shouldSend = peerCapabilityThumbnail
                        thumbnailForWire = if (peerCapabilityThumbnail) snapshot.thumbnailBase64 else null
                    }
                    ClipboardKind.FILE -> {
                        shouldSend = peerCapabilityHistory
                        thumbnailForWire = null
                    }
                }
                if (shouldSend) {
                    activeSession.sendPlaintext(
                        EnvelopeCodec.encode(
                            EnvelopeTypes.CLIPBOARD_SET,
                            ClipboardSetBody(
                                text = snapshot.text,
                                ts = snapshot.timestampSeconds,
                                hash = snapshot.hash,
                                kind = snapshot.kind.wireName,
                                thumbnailBase64 = thumbnailForWire,
                                sourceDeviceId = deviceId
                            )
                        )
                    )
                }
            }
            delay(700)
        }
    }

    private fun handleStatusCaps(caps: StatusCapsBody) {
        peerCapabilityHistory = caps.clipboardHistory
        peerCapabilityThumbnail = caps.clipboardThumbnail
        peerCapabilityBlob = caps.clipboardBlob
        peerCapabilityMirrorTurn = caps.mirrorTurnDataChannel
        stateFlow.update { it.copy(peerClipboardBlob = caps.clipboardBlob) }
        EdgeLinkLog.info("clipboard.android.caps_received history=${caps.clipboardHistory} thumbnail=${caps.clipboardThumbnail} blob=${caps.clipboardBlob} mirrorTurn=${caps.mirrorTurnDataChannel}")
    }

    private fun handleClipboardHistoryResponse(response: ClipboardHistoryResponseBody) {
        scope.launch(Dispatchers.IO) {
            val inserted = clipboardHistoryStore.importRemote(response.items)
            clipboardHistoryStore.prune()
            EdgeLinkLog.info(
                "clipboard.android.history_imported count=${response.items.size} inserted=$inserted"
            )
            refreshClipboardHistory()
        }
    }

    override fun onClipboardHistoryRefresh() {
        refreshClipboardHistory()
    }

    override fun onClipboardHistoryItemClick(item: ClipboardHistoryItemBody) {
        scope.launch(Dispatchers.IO) {
            when (ClipboardKind.fromWire(item.kind) ?: ClipboardKind.TEXT) {
                ClipboardKind.TEXT, ClipboardKind.HTML -> {
                    val text = item.text ?: return@launch
                    if (text.isEmpty()) return@launch
                    clipboardSync.applyRemoteText(text, item.hash)
                    stateFlow.update {
                        it.copy(clipboardBlobStatus = appContext.getString(R.string.clipboard_copied))
                    }
                }
                ClipboardKind.IMAGE -> {
                    val blob = clipboardHistoryStore.loadBlob(item.id)
                    if (blob != null && blob.data.isNotEmpty()) {
                        clipboardSync.applyRemoteImage(blob.data, blob.mime)
                        stateFlow.update {
                            it.copy(clipboardBlobStatus = appContext.getString(R.string.clipboard_blob_applied))
                        }
                    } else {
                        if (!peerCapabilityBlob) {
                            stateFlow.update {
                                it.copy(clipboardBlobStatus = appContext.getString(R.string.clipboard_blob_unsupported))
                            }
                            return@launch
                        }
                        stateFlow.update {
                            it.copy(clipboardBlobStatus = appContext.getString(R.string.clipboard_blob_fetching))
                        }
                        requestClipboardBlob(item.id) { success ->
                            stateFlow.update { state ->
                                state.copy(
                                    clipboardBlobStatus = appContext.getString(
                                        if (success) R.string.clipboard_blob_applied
                                        else R.string.clipboard_blob_failed
                                    )
                                )
                            }
                        }
                    }
                }
                ClipboardKind.FILE -> Unit
            }
        }
    }

    private fun refreshClipboardHistory() {
        scope.launch(Dispatchers.IO) {
            val items = clipboardHistoryStore.recent(limit = 50)
            stateFlow.update { it.copy(clipboardHistoryItems = items) }
        }
    }

    fun requestClipboardBlob(id: String, onComplete: (Boolean) -> Unit) {
        if (!peerCapabilityBlob || session == null) {
            EdgeLinkLog.info("clipboard.android.blob_request_unsupported id=$id")
            onComplete(false)
            return
        }
        cancelPendingClipboardBlob(success = false, reason = "superseded")
        clipboardBlobReassembler.reset()
        pendingClipboardBlobId = id
        pendingClipboardBlobCallback = onComplete
        sendEnvelope(EnvelopeTypes.CLIPBOARD_BLOB_REQUEST, ClipboardBlobRequestBody(id = id))
        EdgeLinkLog.info("clipboard.android.blob_request_sent id=$id")
        pendingClipboardBlobTimeoutJob = scope.launch {
            delay(ClipboardBlobTransfer.RECEIVE_TIMEOUT_MS)
            cancelPendingClipboardBlob(success = false, reason = "timeout")
        }
    }

    private fun handleClipboardBlobRequest(request: ClipboardBlobRequestBody) {
        scope.launch(Dispatchers.IO) {
            val blob = clipboardHistoryStore.loadBlob(request.id)
            if (blob != null && blob.data.size <= ClipboardBlobTransfer.MAX_BLOB_BYTES) {
                val chunks = ClipboardBlobTransfer.chunk(blob.data)
                for (chunk in chunks) {
                    sendEnvelope(
                        EnvelopeTypes.CLIPBOARD_BLOB_CHUNK,
                        ClipboardBlobChunkBody(
                            id = request.id,
                            seq = chunk.seq,
                            fin = chunk.fin,
                            hash = if (chunk.seq == 0) blob.hash else null,
                            mime = if (chunk.seq == 0) blob.mime else null,
                            payloadBase64 = chunk.payloadBase64
                        )
                    )
                }
                EdgeLinkLog.info(
                    "clipboard.android.blob_served id=${request.id} chunks=${chunks.size} bytes=${blob.data.size}"
                )
            } else {
                sendEnvelope(
                    EnvelopeTypes.CLIPBOARD_BLOB_CHUNK,
                    ClipboardBlobChunkBody(id = request.id, seq = 0, fin = true, payloadBase64 = "")
                )
                EdgeLinkLog.info("clipboard.android.blob_not_available id=${request.id}")
            }
        }
    }

    private fun handleClipboardBlobChunk(chunk: ClipboardBlobChunkBody) {
        if (chunk.id != pendingClipboardBlobId) return
        when (val outcome = clipboardBlobReassembler.append(
            id = chunk.id,
            seq = chunk.seq,
            fin = chunk.fin,
            hash = chunk.hash,
            mime = chunk.mime,
            payloadBase64 = chunk.payloadBase64
        )) {
            is ClipboardBlobReassembler.AppendOutcome.Pending -> Unit
            is ClipboardBlobReassembler.AppendOutcome.Complete -> {
                val result = outcome.result
                clipboardHistoryStore.saveBlob(chunk.id, result.mime, result.data)
                if (result.mime?.startsWith("image/") == true) {
                    clipboardSync.applyRemoteImage(result.data, result.mime)
                } else {
                    result.data.decodeToString().let { text ->
                        clipboardSync.applyRemoteText(text, ClipboardBlobTransfer.sha256Hex(result.data))
                    }
                }
                EdgeLinkLog.info("clipboard.android.blob_received id=${chunk.id} bytes=${result.data.size}")
                cancelPendingClipboardBlob(success = true, reason = "complete")
            }
            is ClipboardBlobReassembler.AppendOutcome.NotAvailable -> {
                EdgeLinkLog.info("clipboard.android.blob_not_available id=${chunk.id}")
                cancelPendingClipboardBlob(success = false, reason = "not_available")
            }
            is ClipboardBlobReassembler.AppendOutcome.HashMismatch -> {
                EdgeLinkLog.warn("clipboard.android.blob_hash_mismatch id=${chunk.id}")
                cancelPendingClipboardBlob(success = false, reason = "hash_mismatch")
            }
            is ClipboardBlobReassembler.AppendOutcome.InvalidChunk -> {
                EdgeLinkLog.warn("clipboard.android.blob_invalid_chunk id=${chunk.id}")
                cancelPendingClipboardBlob(success = false, reason = "invalid_chunk")
            }
        }
    }

    private fun cancelPendingClipboardBlob(success: Boolean, reason: String) {
        pendingClipboardBlobTimeoutJob?.cancel()
        pendingClipboardBlobTimeoutJob = null
        if (pendingClipboardBlobId == null) return
        if (!success) {
            EdgeLinkLog.info("clipboard.android.blob_request_failed reason=$reason")
        }
        pendingClipboardBlobId = null
        clipboardBlobReassembler.reset()
        val callback = pendingClipboardBlobCallback
        pendingClipboardBlobCallback = null
        callback?.invoke(success)
    }

    private fun sendStatusCapsAndRequestHistory(identity: LocalIdentity) {
        peerCapabilityHistory = false
        peerCapabilityThumbnail = false
        peerCapabilityBlob = false
        peerCapabilityMirrorTurn = false
        stateFlow.update { it.copy(peerClipboardBlob = false) }
        cancelPendingClipboardBlob(success = false, reason = "new_session")
        sendEnvelope(
            EnvelopeTypes.STATUS_CAPS,
            StatusCapsBody(
                clipboardBlob = true,
                photoSync = stateFlow.value.photoSyncEnabled,
                mirrorTurnDataChannel = true
            )
        )
        sendEnvelope(EnvelopeTypes.CLIPBOARD_HISTORY_REQUEST, ClipboardHistoryRequestBody(limit = 50))
        EdgeLinkLog.info("clipboard.android.caps_sent hostId=${identity.deviceId}")
        launchPhotoSync("session_connect")
    }

    private fun launchPhotoSync(reason: String) {
        if (!stateFlow.value.photoSyncEnabled) {
            return
        }
        val activeSession = session
        if (activeSession == null) {
            EdgeLinkLog.info("photo.android.sync_deferred reason=$reason no_session")
            return
        }
        if (!photoSync.hasPermission()) {
            stateFlow.update {
                it.copy(
                    photoMediaAccessGranted = false,
                    photoSyncStatus = appContext.getString(R.string.photo_sync_no_permission)
                )
            }
            EdgeLinkLog.info("photo.android.sync_skipped reason=$reason no_permission")
            return
        }
        if (photoSyncJob?.isActive == true) {
            EdgeLinkLog.info("photo.android.sync_already_running reason=$reason")
            return
        }
        photoSyncJob = scope.launch(Dispatchers.IO) {
            runPhotoManifest(activeSession, reason)
        }
    }

    private suspend fun runPhotoManifest(activeSession: SecureSessionClient, reason: String) {
        runCatching {
            stateFlow.update { it.copy(photoSyncStatus = appContext.getString(R.string.photo_sync_scanning)) }
            val items = photoSync.scanNewItems()
            if (items.isEmpty()) {
                pendingPhotoItems = emptyMap()
                stateFlow.update { it.copy(photoSyncStatus = appContext.getString(R.string.photo_sync_idle)) }
                sendPhotoStatus("idle")
                return@runCatching
            }
            pendingPhotoItems = items.associateBy { it.id }
            val manifest = PhotoManifestBody(
                items = items.map { item ->
                    PhotoManifestItemBody(
                        id = item.id,
                        name = item.name,
                        mime = item.mime,
                        bytes = item.bytes,
                        dateTakenMs = item.dateTakenMs,
                        isVideo = item.isVideo
                    )
                }
            )
            activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.PHOTO_MANIFEST, manifest))
            stateFlow.update {
                it.copy(photoSyncStatus = appContext.getString(R.string.photo_sync_waiting, items.size))
            }
            sendPhotoStatus("manifest", total = items.size)
            EdgeLinkLog.info("photo.android.manifest_sent count=${items.size} reason=$reason")
        }.onFailure { error ->
            EdgeLinkLog.error("photo.android.manifest_failed reason=$reason", error)
        }
    }

    private fun handlePhotoRequest(body: PhotoRequestBody) {
        val activeSession = session ?: return
        val wanted = body.ids.toSet()
        val items = pendingPhotoItems.values.filter { it.id in wanted }.sortedBy { it.dateAddedSec }
        if (items.isEmpty()) {
            EdgeLinkLog.info("photo.android.request_empty requested=${body.ids.size}")
            return
        }
        if (photoSendJob?.isActive == true) {
            EdgeLinkLog.info("photo.android.send_already_running requested=${items.size}")
            return
        }
        photoSendJob = scope.launch(Dispatchers.IO) {
            var done = 0
            for (item in items) {
                val success = runCatching {
                    streamPhotoItem(activeSession, item)
                }.onFailure { error ->
                    EdgeLinkLog.error("photo.android.stream_failed id=${item.id}", error)
                }.isSuccess
                if (success) {
                    done += 1
                    val currentDone = done
                    stateFlow.update {
                        it.copy(photoSyncStatus = appContext.getString(R.string.photo_sync_sending, currentDone, items.size))
                    }
                    sendPhotoStatus("sending", total = items.size, done = done)
                }
            }
            EdgeLinkLog.info("photo.android.send_batch_done sent=$done total=${items.size}")
        }
    }

    private suspend fun streamPhotoItem(activeSession: SecureSessionClient, item: AndroidPhotoSync.MediaItem) {
        activeSession.sendPlaintext(
            EnvelopeCodec.encode(
                EnvelopeTypes.PHOTO_BEGIN,
                PhotoBeginBody(
                    id = item.id,
                    name = item.name,
                    mime = item.mime,
                    bytes = item.bytes,
                    dateTakenMs = item.dateTakenMs,
                    isVideo = item.isVideo
                )
            )
        )
        val digest = AndroidPhotoSync.newDigest()
        val input = photoSync.openItem(item) ?: throw java.io.IOException("open_input_failed id=${item.id}")
        input.use { stream ->
            val buffer = ByteArray(AndroidPhotoSync.CHUNK_BYTES)
            var seq = 0
            var pending: ByteArray? = null
            while (true) {
                val read = stream.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
                pending?.let { chunk ->
                    activeSession.sendPlaintext(
                        EnvelopeCodec.encode(
                            EnvelopeTypes.PHOTO_CHUNK,
                            PhotoChunkBody(
                                id = item.id,
                                seq = seq - 1,
                                fin = false,
                                payloadBase64 = Base64.getEncoder().encodeToString(chunk)
                            )
                        )
                    )
                }
                pending = buffer.copyOf(read)
                seq += 1
            }
            val hash = AndroidPhotoSync.sha256Hex(digest)
            val last = pending
            if (last == null) {
                activeSession.sendPlaintext(
                    EnvelopeCodec.encode(
                        EnvelopeTypes.PHOTO_CHUNK,
                        PhotoChunkBody(id = item.id, seq = 0, fin = true, hash = hash, payloadBase64 = "")
                    )
                )
            } else {
                activeSession.sendPlaintext(
                    EnvelopeCodec.encode(
                        EnvelopeTypes.PHOTO_CHUNK,
                        PhotoChunkBody(
                            id = item.id,
                            seq = seq - 1,
                            fin = true,
                            hash = hash,
                            payloadBase64 = Base64.getEncoder().encodeToString(last)
                        )
                    )
                )
            }
        }
    }

    private fun handlePhotoAck(body: PhotoAckBody) {
        val ackedItems = pendingPhotoItems.values.filter { it.id in body.ids.toSet() }
        photoSync.markAcknowledged(body.ids)
        if (body.failedIds.isEmpty() && ackedItems.isNotEmpty()) {
            photoSync.advanceWatermark(ackedItems)
        }
        val remaining = pendingPhotoItems - body.ids.toSet()
        pendingPhotoItems = remaining
        EdgeLinkLog.info(
            "photo.android.ack received=${body.ids.size} failed=${body.failedIds.size} pending=${remaining.size}"
        )
        stateFlow.update {
            it.copy(photoSyncStatus = appContext.getString(R.string.photo_sync_done, body.ids.size))
        }
        sendPhotoStatus("acked", done = body.ids.size)
    }

    private fun sendPhotoStatus(state: String, total: Int = 0, done: Int = 0) {
        sendEnvelope(
            EnvelopeTypes.PHOTO_STATUS,
            PhotoStatusBody(state = state, total = total, done = done, ts = System.currentTimeMillis() / 1_000L)
        )
    }

    fun refreshPhotoAccess() {
        stateFlow.update { it.copy(photoMediaAccessGranted = photoSync.hasPermission()) }
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
        reason: String,
        skipKeys: Set<String> = emptySet()
    ) {
        runCatching {
            val pending = smsSync.pendingBroadcastMessages(sourceDeviceId = identity.deviceId)
            if (pending.isEmpty()) {
                return@runCatching
            }
            val (covered, toSend) = pending.partition { smsDedupKey(it) in skipKeys }
            if (covered.isNotEmpty()) {
                smsSync.acknowledgePendingBroadcasts(covered.map { it.id })
                EdgeLinkLog.info("sms.android.pending_covered_by_backfill count=${covered.size} reason=$reason")
            }
            var sent = 0
            for (body in toSend) {
                activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.SMS_MESSAGE, body))
                smsSync.acknowledgePendingBroadcasts(listOf(body.id))
                sent += 1
            }
            if (sent > 0) {
                EdgeLinkLog.info("sms.android.pending_sent count=$sent reason=$reason")
            }
        }.onFailure { error ->
            EdgeLinkLog.error("sms.android.pending_send_failed reason=$reason", error)
        }
    }

    private suspend fun runSmsBackfill(activeSession: SecureSessionClient, identity: LocalIdentity): Set<String> {
        return runCatching {
            val batch = smsSync.backfillInbox(sourceDeviceId = identity.deviceId)
            if (batch.messages.isEmpty()) {
                return@runCatching emptySet()
            }
            var sent = 0
            for (body in batch.messages) {
                activeSession.sendPlaintext(EnvelopeCodec.encode(EnvelopeTypes.SMS_MESSAGE, body))
                sent += 1
            }
            batch.marker?.let(smsSync::saveMarkerIfNewer)
            EdgeLinkLog.info("sms.android.backfill_sent count=$sent")
            batch.messages.mapTo(mutableSetOf()) { smsDedupKey(it) }
        }.getOrElse { error ->
            EdgeLinkLog.error("sms.android.backfill_failed", error)
            emptySet()
        }
    }

    private fun smsDedupKey(body: SmsMessageBody): String =
        "${body.address}|${body.ts}|${body.text}"

    private suspend fun sendLatestMiLinkStatus(activeSession: SecureSessionClient, identity: LocalIdentity) {
        val status = latestMiLinkStatus ?: return
        sendMiLinkStatus(activeSession, identity, status, reason = "cached")
    }

    private fun sendXiaomiMirrorCastFrame(frame: ByteArray, identity: LocalIdentity, reason: String) {
        val body = MiLinkFrameBody(
            sourceDeviceId = identity.deviceId,
            route = XIAOMI_MIRROR_CAST_ROUTE,
            clientNo = XIAOMI_MIRROR_CAST_CLIENT,
            sequence = xiaomiMirrorCastSequence.incrementAndGet(),
            dataBase64 = Base64.getEncoder().encodeToString(frame),
            bytes = frame.size,
            hasNext = false,
            ts = System.currentTimeMillis() / 1_000L
        )
        sendEnvelope(EnvelopeTypes.MILINK_FRAME, body)
        EdgeLinkLog.info(
            "xiaomi.mirror.cast_frame_sent reason=$reason seq=${body.sequence} bytes=${body.bytes}"
        )
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
        val sourcedStatus = status.copy(
            sourceDeviceId = identity.deviceId
        )
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
                    "mediaRelayCandidates=${sourcedStatus.phoneMediaRelayCandidateCount} " +
                    "mirrorScreenRemoteActive=${sourcedStatus.mirrorScreenRemoteActive}"
            )
            startLyraRelayMeshFlowIfReady(sourcedStatus)
        }.onFailure { error ->
            EdgeLinkLog.error("milink.android.status_send_failed", error)
        }
    }

    // When the relay session is up and the phone's native mesh port is known,
    // serve it through relay.mesh.datagram envelopes (the Mac dials it over
    // the relay instead of LAN). The probe list mixes every Lyra-process
    // socket (all share android.uid.system), and its order is numeric — the
    // Mirror app's transient ports can sort ahead of the real mesh dial
    // (2026-08-08: 9876/10158 beat 50426 and the cast phys sync went to a
    // dead endpoint). Prefer the port that last produced inbound traffic.
    private fun startLyraRelayMeshFlowIfReady(status: MiLinkStatusBody) {
        val candidates = orderedMeshPortCandidates(status.lyraMeshPorts)
        val meshPort = candidates.firstOrNull() ?: return
        lyraRelayBridge.setMeshProbePorts(candidates)
        lyraRelayBridge.startMesh("127.0.0.1", meshPort)
    }

    private fun orderedMeshPortCandidates(ports: List<Int>): List<Int> {
        val valid = ports.filter { it in 1..65_535 }
        val responsive = lastResponsiveMeshPort()
        return if (responsive != null && responsive in valid) {
            listOf(responsive) + valid.filter { it != responsive }
        } else {
            valid
        }
    }

    private fun lastResponsiveMeshPort(): Int? =
        appContext.getSharedPreferences(MESH_PORT_PREFS, Context.MODE_PRIVATE)
            .getInt(KEY_LAST_RESPONSIVE_MESH_PORT, 0)
            .takeIf { it in 1..65_535 }

    private fun recordResponsiveMeshPort(port: Int) {
        if (port == lastResponsiveMeshPort()) return
        appContext.getSharedPreferences(MESH_PORT_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putInt(KEY_LAST_RESPONSIVE_MESH_PORT, port)
            .apply()
        EdgeLinkLog.info("lyra.android.mesh_port_responsive port=$port")
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

    private suspend fun sendTunnelEnvelope(type: String, body: Any) {
        val json = EnvelopeCodec.json
        val payload = when (body) {
            is TunnelOpenBody -> EnvelopeCodec.encode(type, body)
            is TunnelOpenResultBody -> EnvelopeCodec.encode(type, body)
            is TunnelDataBody -> EnvelopeCodec.encode(type, body)
            is TunnelCloseBody -> EnvelopeCodec.encode(type, body)
            is TunnelErrorBody -> EnvelopeCodec.encode(type, body)
            is TunnelFlowBody -> EnvelopeCodec.encode(type, body)
            else -> return
        }
        sendPlaintext(payload)
    }

    // Relay-carried Xiaomi datagrams must preserve order (KCP sn depends on
    // ordered delivery), so this awaits the session send instead of launching
    // a detached coroutine; the bridge's per-flow receive loop serializes calls.
    private suspend fun sendLyraRelayEnvelope(type: String, body: Any) {
        val payload = when (body) {
            is RelayDatagramBody -> EnvelopeCodec.encode(type, body)
            else -> return
        }
        val activeSession = session ?: return
        runCatching {
            activeSession.sendPlaintext(payload)
        }
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
    private val context: Context,
    private val clipboardSync: AndroidClipboardSync,
    private val clipboardHistoryStore: ClipboardHistoryStore?,
    private val notificationPresenter: AndroidNotificationPresenter,
    private val screenSession: AndroidScreenSession,
    private val smsSync: AndroidSmsSync,
    private val phoneCallController: AndroidPhoneCallController,
    private val miLinkCommandBridge: AndroidMiLinkCommandBridge,
    private val onPong: () -> Unit,
    private val onSmsSendResult: (SmsSendResultBody) -> Unit,
    private val onScreenStartReceived: suspend () -> Unit,
    private val onScreenStopReceived: () -> Unit,
    private val onMirrorTurnSessionStop: () -> Unit = {},
    private val onMiLinkCommandResult: (MiLinkCommandBody, MiLinkCommandResultBody) -> Unit,
    private val onPhoneActionReceived: (PhoneActionBody) -> Unit,
    private val onPhoneActionResult: (PhoneActionBody, PhoneActionResultBody) -> Unit,
    private val onPhoneRelayMedia: suspend (PhoneRelayMediaBody) -> Unit,
    private val onMacSleep: () -> Unit,
    private val onMacAwake: () -> Unit,
    private val onMiLinkMirrorRtcOffer: suspend (MiLinkMirrorRtcOfferBody) -> Unit = {},
    private val onMiLinkMirrorRtcIce: (MiLinkMirrorRtcIceBody) -> Unit = {},
    private val onTunnelEnvelope: suspend (String, kotlinx.serialization.json.JsonObject) -> Unit = { _, _ -> },
    private val onLyraRelayDatagram: suspend (String, kotlinx.serialization.json.JsonObject) -> Unit = { _, _ -> },
    private val onStatusCaps: (StatusCapsBody) -> Unit = {},
    private val onClipboardHistoryResponse: (ClipboardHistoryResponseBody) -> Unit = {},
    private val onClipboardBlobRequest: (ClipboardBlobRequestBody) -> Unit = {},
    private val onClipboardBlobChunk: (ClipboardBlobChunkBody) -> Unit = {},
    private val onClipboardSetApplied: () -> Unit = {},
    private val onPhotoRequest: (PhotoRequestBody) -> Unit = {},
    private val onPhotoAck: (PhotoAckBody) -> Unit = {},
    private val onPhotoSyncRequest: () -> Unit = {},
    private val onXiaomiTrustStatus: (XiaomiTrustStatusBody) -> Unit = {}
) {
    suspend fun handle(plaintext: ByteArray): ByteArray? {
        return when (EnvelopeCodec.type(plaintext)) {
            EnvelopeTypes.STATUS_PING -> {
                val ping = runCatching { EnvelopeCodec.decode<StatusPingBody>(plaintext).b }.getOrNull()
                val receivedAtMs = System.currentTimeMillis()
                EnvelopeCodec.encode(
                    EnvelopeTypes.STATUS_PONG,
                    StatusPongBody(t0 = ping?.t0, ta = receivedAtMs, tb = System.currentTimeMillis())
                )
            }
            EnvelopeTypes.STATUS_PONG -> {
                val pong = runCatching { EnvelopeCodec.decode<StatusPongBody>(plaintext).b }.getOrNull()
                val t0 = pong?.t0
                if (t0 != null && pong.ta != null && pong.tb != null) {
                    val nowMs = System.currentTimeMillis()
                    val rttMs = nowMs - t0
                    val offsetMs = (pong.ta + pong.tb) / 2 - (t0 + rttMs / 2)
                    EdgeLinkLog.info(
                        "relay.android.secure_rtt rttMs=$rttMs offsetMs=$offsetMs " +
                            "peerTa=${pong.ta} peerTb=${pong.tb}"
                    )
                }
                onPong()
                null
            }
            EnvelopeTypes.MAC_SLEEP -> {
                onMacSleep()
                null
            }
            EnvelopeTypes.XIAOMI_TRUST_STATUS -> {
                runCatching { EnvelopeCodec.decode<XiaomiTrustStatusBody>(plaintext).b }
                    .getOrNull()
                    ?.let(onXiaomiTrustStatus)
                null
            }
            EnvelopeTypes.MAC_AWAKE -> {
                onMacAwake()
                null
            }
            EnvelopeTypes.STATUS_CAPS -> {
                val envelope = EnvelopeCodec.decode<StatusCapsBody>(plaintext)
                onStatusCaps(envelope.b)
                null
            }
            EnvelopeTypes.CLIPBOARD_SET -> {
                val envelope = EnvelopeCodec.decode<ClipboardSetBody>(plaintext)
                val body = envelope.b
                val kind = ClipboardKind.fromWire(body.kind) ?: ClipboardKind.TEXT
                if (kind == ClipboardKind.TEXT || kind == ClipboardKind.HTML) {
                    clipboardSync.applyRemoteText(body.text, body.hash)
                }
                if (clipboardHistoryStore != null) {
                    val source = body.sourceDeviceId
                    clipboardHistoryStore.append(
                        ClipboardHistoryItemBody(
                            id = "${source ?: "remote"}#${body.ts}-0",
                            kind = kind.wireName,
                            ts = body.ts,
                            hash = body.hash,
                            text = body.text.ifEmpty { null },
                            thumbnailBase64 = body.thumbnailBase64,
                            sourceDeviceId = source
                        )
                    )
                    clipboardHistoryStore.prune()
                }
                onClipboardSetApplied()
                null
            }
            EnvelopeTypes.CLIPBOARD_HISTORY_REQUEST -> {
                val envelope = EnvelopeCodec.decode<ClipboardHistoryRequestBody>(plaintext)
                if (clipboardHistoryStore != null) {
                    val items = clipboardHistoryStore.recent(
                        sinceTs = envelope.b.sinceTs,
                        limit = envelope.b.limit ?: 50
                    )
                    EnvelopeCodec.encode(
                        EnvelopeTypes.CLIPBOARD_HISTORY_RESPONSE,
                        ClipboardHistoryResponseBody(items = items)
                    )
                } else {
                    null
                }
            }
            EnvelopeTypes.CLIPBOARD_HISTORY_RESPONSE -> {
                val envelope = EnvelopeCodec.decode<ClipboardHistoryResponseBody>(plaintext)
                onClipboardHistoryResponse(envelope.b)
                null
            }
            EnvelopeTypes.CLIPBOARD_BLOB_REQUEST -> {
                val envelope = EnvelopeCodec.decode<ClipboardBlobRequestBody>(plaintext)
                onClipboardBlobRequest(envelope.b)
                null
            }
            EnvelopeTypes.CLIPBOARD_BLOB_CHUNK -> {
                val envelope = EnvelopeCodec.decode<ClipboardBlobChunkBody>(plaintext)
                onClipboardBlobChunk(envelope.b)
                null
            }
            EnvelopeTypes.PHOTO_REQUEST -> {
                val envelope = EnvelopeCodec.decode<PhotoRequestBody>(plaintext)
                onPhotoRequest(envelope.b)
                null
            }
            EnvelopeTypes.PHOTO_ACK -> {
                val envelope = EnvelopeCodec.decode<PhotoAckBody>(plaintext)
                onPhotoAck(envelope.b)
                null
            }
            EnvelopeTypes.PHOTO_SYNC_REQUEST -> {
                onPhotoSyncRequest()
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
                val routedBody = LANTransport.preferLAN(envelope.b)
                onPhoneActionReceived(routedBody)
                val result = phoneCallController.handle(routedBody)
                onPhoneActionResult(routedBody, result)
                null
            }
            EnvelopeTypes.PHONE_RELAY_MEDIA -> {
                val envelope = EnvelopeCodec.decode<PhoneRelayMediaBody>(plaintext)
                onPhoneRelayMedia(envelope.b)
                null
            }
            EnvelopeTypes.MILINK_MIRROR_MEDIA -> {
                val envelope = EnvelopeCodec.decode<MiLinkMirrorMediaBody>(plaintext)
                AndroidMiLinkMirrorMediaBridge.handleMedia(envelope.b)
                null
            }
            EnvelopeTypes.MILINK_MIRROR_RTC_OFFER -> {
                val envelope = EnvelopeCodec.decode<MiLinkMirrorRtcOfferBody>(plaintext)
                onMiLinkMirrorRtcOffer(envelope.b)
                null
            }
            EnvelopeTypes.MILINK_MIRROR_RTC_ICE -> {
                val envelope = EnvelopeCodec.decode<MiLinkMirrorRtcIceBody>(plaintext)
                onMiLinkMirrorRtcIce(envelope.b)
                null
            }
            EnvelopeTypes.MILINK_COMMAND -> {
                val envelope = EnvelopeCodec.decode<MiLinkCommandBody>(plaintext)
                val result = miLinkCommandBridge.handle(envelope.b)
                onMiLinkCommandResult(envelope.b, result)
                EnvelopeCodec.encode(EnvelopeTypes.MILINK_COMMAND_RESULT, result)
            }
            EnvelopeTypes.SCREEN_START -> {
                onScreenStartReceived()
                screenSession.requestStart()
                null
            }
            EnvelopeTypes.SCREEN_STOP -> {
                AndroidMiLinkMirrorMediaBridge.stop("screen_stop")
                onMirrorTurnSessionStop()
                onScreenStopReceived()
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
            EnvelopeTypes.TUNNEL_OPEN, EnvelopeTypes.TUNNEL_OPEN_RESULT,
            EnvelopeTypes.TUNNEL_DATA, EnvelopeTypes.TUNNEL_CLOSE,
            EnvelopeTypes.TUNNEL_ERROR, EnvelopeTypes.TUNNEL_FLOW -> {
                val type = EnvelopeCodec.type(plaintext)
                val envelope = EnvelopeCodec.json.decodeFromString<kotlinx.serialization.json.JsonObject>(plaintext.decodeToString())
                val body = envelope["b"] as? kotlinx.serialization.json.JsonObject ?: kotlinx.serialization.json.JsonObject(emptyMap())
                onTunnelEnvelope(type, body)
                null
            }
            EnvelopeTypes.RELAY_MESH_DATAGRAM, EnvelopeTypes.RELAY_CHANNEL_DATAGRAM -> {
                val type = EnvelopeCodec.type(plaintext)
                val envelope = EnvelopeCodec.json.decodeFromString<kotlinx.serialization.json.JsonObject>(plaintext.decodeToString())
                val body = envelope["b"] as? kotlinx.serialization.json.JsonObject ?: kotlinx.serialization.json.JsonObject(emptyMap())
                onLyraRelayDatagram(type, body)
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
