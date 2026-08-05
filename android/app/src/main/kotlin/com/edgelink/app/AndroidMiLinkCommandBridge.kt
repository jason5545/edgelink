package com.edgelink.app

import android.app.KeyguardManager
import android.content.ComponentName
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Parcel
import com.edgelink.core.MiLinkCommandBody
import com.edgelink.core.MiLinkCommandResultBody
import com.edgelink.transport.LANTransport
import com.xiaomi.mirror.RemoteDeviceInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class AndroidMiLinkMirrorCloudBridgeRequest(
    val sessionId: String,
    val localRtspPorts: List<Int>,
    val reason: String,
    val turnMode: Boolean = false
)

enum class MirrorMediaTransport { CLOUDFLARE, TURN, LAN_DIRECT, LEGACY_DIRECT }

data class MirrorMediaRouteSelection(
    val transport: MirrorMediaTransport,
    val cloudSessionId: String?
)

class AndroidMiLinkCommandBridge(
    context: Context,
    private val onMirrorCloudBridgeRequested: (AndroidMiLinkMirrorCloudBridgeRequest) -> Unit = {},
    private val onMirrorCloudBridgeStopRequested: (String) -> Unit = {},
    private val peerMirrorTurnDataChannelSupported: () -> Boolean = { false }
) {
    private val appContext = context.applicationContext
    @Volatile
    private var activeMirrorMediaTransport: MirrorMediaTransport? = null

    // MirrorControl serializes its lifecycle internally; a second provider
    // call issued while a previous one is still inside the provider jams that
    // queue (one stuck startShare wedges every later call for ~15s each).
    // Exactly one provider call may be in flight at a time. A call whose
    // quick deadline expires is "still in flight", never "failed, retry now":
    // the semaphore stays held by a drainer until the provider answers (or a
    // hard cap), so later calls join it instead of racing it.
    private val mirrorProviderLifecycleSemaphore = Semaphore(1)
    private val mirrorProviderDrainScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile
    private var mirrorProviderInFlightMethod: String? = null
    @Volatile
    private var mirrorProviderLastCallStartedAtMs = 0L

    suspend fun handle(body: MiLinkCommandBody): MiLinkCommandResultBody =
        withContext(Dispatchers.IO) {
            val startedAt = System.currentTimeMillis()
            val result = runCatching {
                when (body.command) {
                    COMMAND_MISHARE_OPEN_SETTINGS -> openMiShareSettings()
                    COMMAND_MISHARE_DISCOVER -> discoverMiShareDevices(body)
                    COMMAND_MISHARE_NSD_DISCOVER -> discoverMiShareNsdDevices(body)
                    COMMAND_MI_CONNECT_NETWORKING_PROBE -> probeMiConnectNetworking(body, addServiceInfo = false)
                    COMMAND_MI_CONNECT_NETWORKING_REGISTER -> probeMiConnectNetworking(body, addServiceInfo = true)
                    COMMAND_MIRROR_QUERY_REMOTE_DEVICES -> queryMirrorRemoteDevices(body)
                    COMMAND_MIRROR_LOCK_STATE -> queryMirrorLockState()
                    COMMAND_MIRROR_START_MAIN_DISPLAY -> startMirrorMainDisplay(body)
                    COMMAND_MIRROR_GLOBAL -> sendMirrorGlobal(body)
                    COMMAND_MIRROR_OPEN_REMOTE_DEVICE -> callMirrorDeviceProvider(body, "openRemoteDeviceMirror")
                    COMMAND_SYNERGY_STATUS -> querySynergyStatus()
                    COMMAND_SYNERGY_SHOW_RELAY_DATA -> callSynergyRelay(body, transactionShowRelayData, "showRelayData")
                    COMMAND_SYNERGY_SYNC_RELAY_DATA -> callSynergyRelay(body, transactionSyncRelayData, "syncRelayData")
                    COMMAND_SYNERGY_CANCEL_RELAY_DATA -> callSynergyRelay(body, transactionCancelRelayData, "cancelRelayData")
                    COMMAND_DIST_AUDIO_BIND -> bindDistAudio()
                    else -> CommandResult(
                        success = false,
                        route = "edgelink.generic",
                        message = "unsupported command=${body.command}"
                    )
                }
            }.getOrElse { error ->
                CommandResult(
                    success = false,
                    route = "xiaomi.error",
                    message = "${error.javaClass.simpleName}:${error.message.orEmpty()}"
                )
            }

            val elapsedMs = System.currentTimeMillis() - startedAt
            val lockedWhileStarting = body.command == COMMAND_MIRROR_START_MAIN_DISPLAY &&
                appContext.getSystemService(KeyguardManager::class.java)?.isDeviceLocked == true
            if (lockedWhileStarting) {
                EdgeLinkLog.info("xiaomi.milink.command_locked_flag requestId=${body.requestId}")
            }
            val resultData = if (lockedWhileStarting) {
                result.data + ("locked" to "true")
            } else {
                result.data
            }
            EdgeLinkLog.info(
                "xiaomi.milink.command command=${body.command} requestId=${body.requestId} " +
                    "success=${result.success} route=${result.route} elapsedMs=$elapsedMs " +
                    "message=${result.message.forSingleLineLog()}"
            )
            MiLinkCommandResultBody(
                requestId = body.requestId,
                command = body.command,
                success = result.success,
                route = result.route,
                message = result.message,
                data = resultData,
                ts = System.currentTimeMillis() / 1_000L
            )
        }

    private suspend fun openMiShareSettings(): CommandResult {
        val intent = Intent(miShareSettingsAction)
            .setPackage(miSharePackage)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val direct = runCatching {
            appContext.startActivity(intent)
            CommandResult(
                success = true,
                route = "xiaomi.mishare",
                message = "MiShare settings opened directly"
            )
        }.getOrNull()
        if (direct != null) {
            return direct
        }

        val shizuku = runCatching {
            AndroidShizukuSupport.openMiShareSettings(appContext)
        }.getOrElse { error ->
            return CommandResult(
                success = false,
                route = "xiaomi.mishare",
                message = "MiShare direct start failed; Shizuku failed ${error.javaClass.simpleName}:${error.message.orEmpty()}"
            )
        }
        return CommandResult(
            success = shizuku.success,
            route = "xiaomi.mishare",
            message = shizuku.message
        )
    }

    private suspend fun discoverMiShareDevices(body: MiLinkCommandBody): CommandResult {
        val timeoutMs = body.args["timeoutMs"]
            ?.toLongOrNull()
            ?.coerceIn(1_000L, 12_000L)
            ?: 5_000L
        val result = AndroidMiShareServiceClient(appContext).discover(timeoutMs)
        val macLike = result.devices.filter { it.looksLikeMac() }
        val sample = result.devices.take(5).joinToString("|") { it.compactSummary() }
        val macSample = macLike.take(3).joinToString("|") { it.compactSummary() }
        val details = result.devices.take(3).joinToString("|") { it.diagnosticSummary() }
        return CommandResult(
            success = true,
            route = "xiaomi.mishare",
            message = "discover devices=${result.devices.size} macLike=${macLike.size} stateBefore=${result.stateBefore ?: -1}",
            data = mapOf(
                "devices" to result.devices.size.toString(),
                "macLike" to macLike.size.toString(),
                "stateBefore" to (result.stateBefore?.toString() ?: "unknown"),
                "lost" to result.lostDeviceIds.size.toString(),
                "sample" to sample,
                "macSample" to macSample,
                "details" to details
            )
        )
    }

    private suspend fun discoverMiShareNsdDevices(body: MiLinkCommandBody): CommandResult {
        val timeoutMs = body.args["timeoutMs"]
            ?.toLongOrNull()
            ?.coerceIn(1_000L, 12_000L)
            ?: 5_000L
        val result = AndroidLyraNsdDiscovery(appContext).discover(timeoutMs)
        val edgeLinkMatches = result.services.filter { it.serviceName.equals("721572C3", ignoreCase = true) }
        val sample = result.services.take(8).joinToString("|") { it.compactSummary() }
        return CommandResult(
            success = true,
            route = "android.nsd",
            message = "nsd services=${result.services.size} edgeLink=${edgeLinkMatches.size}",
            data = mapOf(
                "services" to result.services.size.toString(),
                "edgeLink" to edgeLinkMatches.size.toString(),
                "sample" to sample,
                "events" to result.events.takeLast(16).joinToString("|")
            )
        )
    }

    private suspend fun probeMiConnectNetworking(
        body: MiLinkCommandBody,
        addServiceInfo: Boolean
    ): CommandResult {
        val requestedDeviceIds = listOfNotNull(
            body.args["deviceId"],
            body.args["deviceIds"]
        )
            .flatMap { value -> value.split(',', '|', ';') }
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        val deviceIds = (requestedDeviceIds + listOf("1780C740", "721572C3"))
            .distinct()
            .take(8)
        val profile = AndroidMiConnectNetworkingDefaults.serviceProfile(body.args["profile"])
        val serviceData = AndroidMiConnectNetworkingDefaults.parseHex(body.args["serviceDataHex"])
            ?: profile?.serviceData
            ?: AndroidMiConnectNetworkingDefaults.defaultLyraShareServiceData()
        val serviceName = body.args["serviceName"]
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: profile?.serviceName
            ?: "miLyraShare"
        val servicePackageName = body.args["servicePackageName"]
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "com.edgelink.app"
        val request = MiConnectNetworkingProbeRequest(
            deviceIds = deviceIds,
            addServiceInfo = addServiceInfo || body.args["addServiceInfo"].toBooleanOrDefault(false),
            serviceName = serviceName,
            servicePackageName = servicePackageName,
            serviceData = serviceData
        )
        val result = AndroidMiConnectNetworkingClient(appContext).probe(request)
        val success = result.hasAnySuccessfulMetadataRead &&
            (!request.addServiceInfo || result.addServiceInfo?.ok == true)
        return CommandResult(
            success = success,
            route = if (result.hasPermissionError) {
                "xiaomi.mi_connect.permission"
            } else {
                "xiaomi.mi_connect.networking"
            },
            message = result.message(addRequested = request.addServiceInfo),
            data = result.toCommandData() + mapOf(
                "deviceIds" to deviceIds.joinToString(","),
                "serviceName" to serviceName,
                "servicePackageName" to servicePackageName,
                "profile" to body.args["profile"].orEmpty(),
                "addRequested" to request.addServiceInfo.toString()
            )
        )
    }

    private fun queryMirrorRemoteDevices(body: MiLinkCommandBody): CommandResult {
        val queryCall = callMirrorProviderSerialized(
            method = "queryRemoteDevices",
            deadlineMs = mirrorQueryProviderDeadlineMs
        ) {
            appContext.contentResolver.callMirrorProvider(
                "queryRemoteDevices",
                Bundle().apply {
                    body.args["manufacturer"]?.let { putString("remoteDeviceManufacturer", it) }
                    body.args["platform"]?.let { putString("device_platform", it) }
                }
            )
        }
        val result = when (queryCall) {
            is MirrorProviderCallResult.Completed -> queryCall.value
            is MirrorProviderCallResult.Pending -> return CommandResult(
                success = false,
                route = "xiaomi.mirror",
                message = "queryRemoteDevices pending>${queryCall.deadlineMs}ms provider_busy",
                data = mapOf(
                    "count" to "0",
                    "pending" to "true",
                    "pendingMethod" to "queryRemoteDevices",
                    "pendingDeadlineMs" to queryCall.deadlineMs.toString()
                )
            )
        } ?: return CommandResult(
            success = false,
            route = "xiaomi.mirror",
            message = "queryRemoteDevices returned null"
        )
        result.classLoader = RemoteDeviceInfo::class.java.classLoader
        @Suppress("DEPRECATION")
        val devices = result.getParcelableArrayList<RemoteDeviceInfo>("remoteDevices").orEmpty()
        return CommandResult(
            success = true,
            route = "xiaomi.mirror",
            message = "remoteDevices=${devices.size}",
            data = mapOf(
                "count" to devices.size.toString(),
                "sample" to devices.take(3).joinToString("|") { it.compactSummary() }
            )
        )
    }

    private fun queryMirrorLockState(): CommandResult {
        val keyguard = appContext.getSystemService(KeyguardManager::class.java)
        val locked = keyguard?.isDeviceLocked == true
        return CommandResult(
            success = true,
            route = "xiaomi.mirror.lockstate",
            message = "locked=$locked",
            data = mapOf("locked" to locked.toString())
        )
    }

    private suspend fun startMirrorMainDisplay(body: MiLinkCommandBody): CommandResult {
        val requestedDeviceId = body.args["remoteDeviceId"].orEmpty().trim()
        val requestedFakeRemote = MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(requestedDeviceId)
        val forceFakeRemote = body.args["forceFakeRemote"] == "true"
        val allowFakeRemote = body.args["allowFakeRemote"] == "true" || forceFakeRemote
        val selection = when {
            requestedDeviceId.isNotEmpty() && !requestedFakeRemote -> MirrorRemoteSelection(
                deviceId = requestedDeviceId,
                source = "request",
                count = 1,
                sample = "requested=$requestedDeviceId",
                btMac = null
            )
            !forceFakeRemote -> selectRealMirrorRemoteDevice(
                sourceSuffix = if (requestedFakeRemote) "realOverFakeRequest" else null
            )
            requestedFakeRemote -> MirrorRemoteSelection(
                deviceId = requestedDeviceId,
                source = "forceFakeRemote",
                count = 1,
                sample = "requested=$requestedDeviceId",
                btMac = null
            )
            else -> null
        }
        if (selection == null) {
            if (allowFakeRemote) {
                return startFakeMirrorMainDisplay(body)
            }
            return CommandResult(
                success = false,
                route = "xiaomi.mirror.unavailable",
                message = "no linked Xiaomi mirror remote device; Xiaomi screen route has no WebRTC fallback",
                data = mapOf(
                    "remoteDevices" to "0",
                    "requestedRemoteDeviceId" to requestedDeviceId,
                    "fallback" to "",
                    "fallbackSuppressed" to "true"
                )
            )
        }

        if (!MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(selection.deviceId) &&
            body.args["nativeShortcutFirst"] != "false"
        ) {
            return startRealMirrorNativeRoute(
                body = body,
                selection = selection,
                requestedDeviceId = requestedDeviceId
            )
        }

        if (MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(selection.deviceId)) {
            return startFakeMirrorMainDisplay(body)
        }

        val startCall = callMirrorDeviceProviderWithDeadline(
            body = body,
            method = "startRemoteMainMirrorDisplay",
            remoteDeviceId = selection.deviceId,
            deadlineMs = mirrorRealScreenProviderQuickDeadlineMs
        )
        if (startCall is MirrorProviderDeadlineResult.Pending) {
            return pendingRealMirrorFallbackResult(
                method = "startRemoteMainMirrorDisplay",
                selection = selection,
                requestedDeviceId = requestedDeviceId,
                deadlineMs = startCall.deadlineMs
            )
        }
        val startResult = (startCall as MirrorProviderDeadlineResult.Completed).result
        if (startResult.success) {
            return startResult.copy(
                message = "${startResult.message}; selected=${selection.source}; remoteDevices=${selection.count}",
                data = startResult.data + mapOf(
                    "selectedSource" to selection.source,
                    "selectedDeviceId" to selection.deviceId,
                    "requestedRemoteDeviceId" to requestedDeviceId,
                    "remoteDevices" to selection.count.toString(),
                    "sample" to selection.sample
                )
            )
        }

        val openCall = callMirrorDeviceProviderWithDeadline(
            body = body,
            method = "openRemoteDeviceMirror",
            remoteDeviceId = selection.deviceId,
            deadlineMs = mirrorRealScreenProviderQuickDeadlineMs
        )
        if (openCall is MirrorProviderDeadlineResult.Pending) {
            return pendingRealMirrorFallbackResult(
                method = "openRemoteDeviceMirror",
                selection = selection,
                requestedDeviceId = requestedDeviceId,
                deadlineMs = openCall.deadlineMs,
                startResult = startResult
            )
        }
        val openResult = (openCall as MirrorProviderDeadlineResult.Completed).result
        return CommandResult(
            success = openResult.success,
            route = if (openResult.success) "xiaomi.mirror" else "xiaomi.mirror.failed",
            message = "start=${startResult.message}; open=${openResult.message}; " +
                "selected=${selection.source}; remoteDevices=${selection.count}; noWebRTCFallback=true",
            data = startResult.data + mapOf(
                "startValue" to startResult.data["value"].orEmpty(),
                "openValue" to openResult.data["value"].orEmpty(),
                "selectedSource" to selection.source,
                "selectedDeviceId" to selection.deviceId,
                "requestedRemoteDeviceId" to requestedDeviceId,
                "remoteDevices" to selection.count.toString(),
                "sample" to selection.sample,
                "fallback" to "",
                "fallbackSuppressed" to (!openResult.success).toString()
            )
        )
    }

    private suspend fun startRealMirrorNativeRoute(
        body: MiLinkCommandBody,
        selection: MirrorRemoteSelection,
        requestedDeviceId: String
    ): CommandResult {
        val iconCall = runCatching {
            callMirrorDeviceIconClickWithDeadline(
                body = body,
                remoteDeviceId = selection.deviceId,
                deadlineMs = mirrorIconClickProviderDeadlineMs
            )
        }.getOrElse { error ->
            EdgeLinkLog.warn("xiaomi.mirror.icon_click_exception", error)
            null
        }

        scheduleMirrorBtMacFallback(
            body = body,
            selection = selection,
            requestedDeviceId = requestedDeviceId
        )

        if (iconCall is MirrorProviderDeadlineResult.Pending) {
            return pendingNativeMirrorResult(
                method = "performMirrorDeviceIconClick",
                selection = selection,
                requestedDeviceId = requestedDeviceId,
                deadlineMs = iconCall.deadlineMs,
                priorMessage = "btMac fallback scheduled"
            )
        }

        val iconResult = (iconCall as? MirrorProviderDeadlineResult.Completed)?.result
            ?: pendingNativeMirrorResult(
                method = "performMirrorDeviceIconClick",
                selection = selection,
                requestedDeviceId = requestedDeviceId,
                deadlineMs = mirrorIconClickProviderDeadlineMs,
                priorMessage = "performMirrorDeviceIconClick exception; btMac fallback scheduled"
            )

        return iconResult.copy(
            message = "${iconResult.message}; btMac fallback scheduled; " +
                "selected=${selection.source}; remoteDevices=${selection.count}",
            data = iconResult.data +
                nativeRouteSelectionData(selection, requestedDeviceId) +
                mapOf(
                    "nextMethod" to "openRemoteDeviceMirrorByBtMac",
                    "nextDelayMs" to mirrorBtMacFallbackDelayMs.toString()
                )
        )
    }

    private fun scheduleMirrorBtMacFallback(
        body: MiLinkCommandBody,
        selection: MirrorRemoteSelection,
        requestedDeviceId: String
    ) {
        if (body.args["btMacFallback"] == "false") {
            return
        }
        Thread({
            runCatching {
                Thread.sleep(mirrorBtMacFallbackDelayMs)
                if (isXiaomiMirrorDisplayActive()) {
                    EdgeLinkLog.info(
                        "xiaomi.mirror.bt_mac_fallback_skip reason=display_active " +
                            "deviceId=${selection.deviceId}"
                    )
                    return@runCatching
                }
                val btProbe = resolveMirrorBluetoothMacBlocking(body, selection)
                val btMac = btProbe?.btMac?.normalizeBluetoothMac()
                if (btMac == null) {
                    EdgeLinkLog.warn(
                        "xiaomi.mirror.bt_mac_fallback_skip reason=bt_mac_missing " +
                            "deviceId=${selection.deviceId} probe=${btProbe?.message.orEmpty().forSingleLineLog()}"
                    )
                    return@runCatching
                }
                val btCall = callMirrorBtMacProviderWithDeadline(
                    body = body,
                    btMac = btMac,
                    btMacSource = btProbe.source,
                    deadlineMs = mirrorNativeShortcutProviderDeadlineMs
                )
                when (btCall) {
                    is MirrorProviderDeadlineResult.Completed -> {
                        EdgeLinkLog.info(
                            "xiaomi.mirror.bt_mac_fallback_result requestId=${body.requestId} " +
                                "deviceId=${selection.deviceId} requested=$requestedDeviceId " +
                                "success=${btCall.result.success} route=${btCall.result.route} " +
                                "message=${btCall.result.message.forSingleLineLog()}"
                        )
                    }
                    is MirrorProviderDeadlineResult.Pending -> {
                        EdgeLinkLog.info(
                            "xiaomi.mirror.bt_mac_fallback_pending requestId=${body.requestId} " +
                                "deviceId=${selection.deviceId} deadlineMs=${btCall.deadlineMs}"
                        )
                    }
                }
            }.onFailure { error ->
                EdgeLinkLog.warn("xiaomi.mirror.bt_mac_fallback_exception", error)
            }
        }, "EdgeLinkMiMirror-btMacFallback").apply {
            isDaemon = true
            start()
        }
    }



    private fun sendMirrorGlobal(body: MiLinkCommandBody): CommandResult {
        val action = body.args["action"].orEmpty()
        val result = callMirrorProviderWithDeadline(
            method = "edgeLinkGlobal",
            deadlineMs = mirrorKeyboardProviderDeadlineMs
        ) {
            val providerResult = appContext.contentResolver.callMirrorProvider(
                "edgeLinkGlobal",
                Bundle().apply {
                    putString("action", action)
                    putString("requestId", body.requestId)
                    putString("deviceId", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
                    putString("remoteDeviceId", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
                    putInt("method_version", body.args["method_version"]?.toIntOrNull() ?: mirrorProviderMethodVersion)
                }
            )
            val accepted = providerResult?.getBoolean("edgelinkGlobalAccepted", false) == true
            CommandResult(
                success = accepted,
                route = "xiaomi.mirror.hid.global",
                message = "global accepted=$accepted keys=${providerResult?.keySummary().orEmpty()}",
                data = mapOf(
                    "accepted" to accepted.toString(),
                    "action" to action,
                    "providerValue" to (providerResult?.valueInt()?.toString() ?: ""),
                    "providerRoute" to providerResult?.getString("route").orEmpty(),
                    "providerMessage" to providerResult?.getString("message").orEmpty()
                )
            )
        }
        return when (result) {
            is MirrorProviderDeadlineResult.Completed -> result.result
            is MirrorProviderDeadlineResult.Pending -> CommandResult(
                success = false,
                route = "xiaomi.mirror.hid.global.pending",
                message = "global pending>${result.deadlineMs}ms",
                data = mapOf(
                    "pendingMethod" to "edgeLinkGlobal",
                    "pendingDeadlineMs" to result.deadlineMs.toString(),
                    "action" to action
                )
            )
        }
    }



    private fun resolveMirrorBluetoothMacBlocking(
        body: MiLinkCommandBody,
        selection: MirrorRemoteSelection
    ): MirrorBluetoothMacResult? {
        body.args["btMac"]?.normalizeBluetoothMac()?.let { btMac ->
            return MirrorBluetoothMacResult(btMac = btMac, source = "request", message = "bt mac from request")
        }
        selection.btMac?.normalizeBluetoothMac()?.let { btMac ->
            return MirrorBluetoothMacResult(btMac = btMac, source = "queryRemoteDevices", message = "bt mac from queryRemoteDevices")
        }
        if (body.args["probeBtMac"] == "false") {
            return null
        }
        return runCatching {
            runBlocking { AndroidShizukuSupport.recentMirrorBluetoothMac(appContext) }
        }.getOrElse { error ->
            EdgeLinkLog.warn("xiaomi.mirror.bt_mac_probe_exception", error)
            null
        }
    }

    private fun nativeRouteSelectionData(
        selection: MirrorRemoteSelection,
        requestedDeviceId: String
    ): Map<String, String> =
        mapOf(
            "selectedSource" to selection.source,
            "selectedDeviceId" to selection.deviceId,
            "requestedRemoteDeviceId" to requestedDeviceId,
            "remoteDevices" to selection.count.toString(),
            "sample" to selection.sample,
            "fallback" to ""
        )

    private fun pendingNativeMirrorResult(
        method: String,
        selection: MirrorRemoteSelection,
        requestedDeviceId: String,
        deadlineMs: Long,
        btMac: String? = null,
        btMacSource: String? = null,
        priorMessage: String? = null
    ): CommandResult =
        CommandResult(
            success = false,
            route = "xiaomi.mirror.pending",
            message = listOfNotNull(
                priorMessage,
                "$method pending>${deadlineMs}ms",
                "selected=${selection.source}",
                "remoteDevices=${selection.count}"
            ).joinToString("; "),
            data = mapOf(
                "remoteDeviceId" to selection.deviceId,
                "value" to "pending",
                "providerValue" to "pending",
                "pending" to "true",
                "state" to "pending",
                "pendingMethod" to method,
                "pendingDeadlineMs" to deadlineMs.toString(),
                "btMac" to (btMac?.maskBluetoothMac() ?: ""),
                "btMacSource" to (btMacSource ?: ""),
                "fallback" to ""
            ) + nativeRouteSelectionData(selection, requestedDeviceId)
        )

    private fun pendingRealMirrorFallbackResult(
        method: String,
        selection: MirrorRemoteSelection,
        requestedDeviceId: String,
        deadlineMs: Long,
        startResult: CommandResult? = null
    ): CommandResult {
        val prefix = listOfNotNull(
            "$method pending>${deadlineMs}ms",
            startResult?.let { "start=${it.message}" },
            "selected=${selection.source}",
            "remoteDevices=${selection.count}"
        ).joinToString("; ")
        return CommandResult(
            success = false,
            route = "xiaomi.mirror.pending",
            message = "$prefix; noWebRTCFallback=true",
            data = mapOf(
                "remoteDeviceId" to selection.deviceId,
                "selectedDeviceId" to selection.deviceId,
                "requestedRemoteDeviceId" to requestedDeviceId,
                "selectedSource" to selection.source,
                "remoteDevices" to selection.count.toString(),
                "sample" to selection.sample,
                "value" to "pending",
                "providerValue" to "pending",
                "pending" to "true",
                "state" to "pending",
                "pendingMethod" to method,
                "pendingDeadlineMs" to deadlineMs.toString(),
                "fallback" to "",
                "fallbackSuppressed" to "true"
            ) + (startResult?.data?.let { mapOf("startValue" to it["value"].orEmpty()) } ?: emptyMap())
        )
    }

    private suspend fun awaitMirrorCastChannelReady(
        sinceMs: Long,
        timeoutMs: Long = mirrorCastChannelReadyTimeoutMs
    ): String {
        // The Mac creates the cast channel before this command even arrives,
        // so a confirmation slightly *before* arm is valid — what matters is
        // that the mirror app holds a live channel now, not who came first.
        val freshAfterMs = minOf(sinceMs, System.currentTimeMillis() - mirrorCastChannelFreshMs)
        val deadlineMs = System.currentTimeMillis() + timeoutMs
        var confirmAtMs = 0L
        var device = ""
        while (System.currentTimeMillis() < deadlineMs) {
            val result = runCatching {
                appContext.contentResolver.callMirrorProvider(
                    "edgeLinkCastChannel",
                    Bundle().apply {
                        putString("deviceId", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
                        putString("remoteDeviceId", MiLinkPrivilegeHookPolicy.FAKE_MIRROR_REMOTE_ID)
                    }
                )
            }.getOrNull()
            confirmAtMs = result?.getLong("castChannelConfirmAtMs") ?: 0L
            device = result?.getString("castChannelDevice").orEmpty()
            if (confirmAtMs >= freshAfterMs) {
                return "ready device=$device confirmAt=$confirmAtMs waitedMs=${System.currentTimeMillis() - sinceMs}"
            }
            delay(mirrorCastChannelPollIntervalMs)
        }
        return "timeout device=$device confirmAt=$confirmAtMs since=$sinceMs"
    }

    private suspend fun startFakeMirrorMainDisplay(body: MiLinkCommandBody): CommandResult {
        // The fake pad remote is gone; what remains here is the live part of
        // the command: pick the media transport, wait for the cast channel
        // the Mac opened natively, and bring the cloud bridge up or down.
        val routeSelection = selectMirrorMediaRoute(body, reason = "start_main_display")
        val transport = routeSelection.transport
        val cloudMirrorSessionId = routeSelection.cloudSessionId
        activeMirrorMediaTransport = transport
        if (transport != MirrorMediaTransport.CLOUDFLARE && transport != MirrorMediaTransport.TURN) {
            onMirrorCloudBridgeStopRequested("transport_${transport.name.lowercase()}")
        }
        val startedAtMs = System.currentTimeMillis()
        val castChannelWait = awaitMirrorCastChannelReady(startedAtMs)
        EdgeLinkLog.info("xiaomi.mirror.android.cast_channel_wait $castChannelWait")
        val sourceListenHost = preferredLocalIPv4Address().orEmpty()
        val sourceListenPort = body.args["peerPort"]?.toIntOrNull()?.takeIf { it in 1..65_535 } ?: 7_102
        if (cloudMirrorSessionId != null) {
            onMirrorCloudBridgeRequested(
                AndroidMiLinkMirrorCloudBridgeRequest(
                    sessionId = cloudMirrorSessionId,
                    localRtspPorts = listOf(sourceListenPort, 7_102).distinct(),
                    reason = "startMainDisplay",
                    turnMode = transport == MirrorMediaTransport.TURN
                )
            )
        }
        val castChannelReady = castChannelWait.startsWith("ready")
        return CommandResult(
            success = castChannelReady || cloudMirrorSessionId != null,
            route = if (castChannelReady) "xiaomi.mirror" else "xiaomi.mirror.pending",
            message = "transport=${transport.name.lowercase()} castChannel=$castChannelWait",
            data = mapOf(
                "castChannel" to castChannelWait
            ) + mirrorMediaTransportData(
                transport = transport,
                cloudMirrorSessionId = cloudMirrorSessionId,
                sourceListenHost = sourceListenHost,
                sourceListenPort = sourceListenPort
            )
        )
    }


    private fun mirrorMediaTransportData(
        transport: MirrorMediaTransport,
        cloudMirrorSessionId: String?,
        sourceListenHost: String?,
        sourceListenPort: Int?
    ): Map<String, String> {
        if (transport == MirrorMediaTransport.TURN && !cloudMirrorSessionId.isNullOrBlank()) {
            return mapOf(
                "sourceRole" to "android_cloud_bridge",
                "cloudBridge" to "true",
                "mediaTransport" to "turn",
                "mirrorSessionId" to cloudMirrorSessionId,
                "sourceListenHost" to sourceListenHost.orEmpty(),
                "sourceListenPort" to (sourceListenPort?.toString() ?: "")
            )
        }
        if (transport == MirrorMediaTransport.CLOUDFLARE && !cloudMirrorSessionId.isNullOrBlank()) {
            return mapOf(
                "sourceRole" to "android_cloud_bridge",
                "cloudBridge" to "true",
                "mediaTransport" to "cloudflare",
                "mirrorSessionId" to cloudMirrorSessionId,
                "sourceListenHost" to sourceListenHost.orEmpty(),
                "sourceListenPort" to (sourceListenPort?.toString() ?: "")
            )
        }
        if (transport == MirrorMediaTransport.LAN_DIRECT) {
            // MirrorControl listens on the source device (like the official
            // WFD source), so the Mac must dial it as the RTSP client.
            return mapOf(
                "mediaTransport" to "lan_direct",
                "sourceRole" to "android_server",
                "sourceListenHost" to sourceListenHost.orEmpty(),
                "sourceListenPort" to (sourceListenPort?.toString() ?: "")
            )
        }
        if (!sourceListenHost.isNullOrBlank() && sourceListenPort != null) {
            return mapOf(
                "sourceRole" to "android_server",
                "sourceListenHost" to sourceListenHost,
                "sourceListenPort" to sourceListenPort.toString()
            )
        }
        return emptyMap()
    }

    private suspend fun selectMirrorMediaRoute(
        body: MiLinkCommandBody,
        reason: String
    ): MirrorMediaRouteSelection {
        val cloudSessionId = body.args["mirrorSessionId"]
            ?.trim()
            ?.takeIf { it.isNotEmpty() && body.args["mediaTransport"] == "cloudflare" }
        val peerHost = body.args["peerHost"]?.trim()?.takeIf { it.isNotEmpty() }
        val peerPort = body.args["peerPort"]?.toIntOrNull()?.takeIf { it in 1..65_535 }
        val probePort = body.args["lanProbePort"]?.toIntOrNull()?.takeIf { it in 1..65_535 }
        // LAN-first: the Mac announces its probe endpoint; when it answers, the
        // source can dial the Mac's own RTSP listener directly (the official
        // path) instead of bridging through the cloud. The Mac stands down its
        // cloud receiver when the result carries mediaTransport=lan_direct.
        if (cloudSessionId != null && peerHost != null && probePort != null &&
            LANTransport.isReachable(peerHost, probePort)
        ) {
            EdgeLinkLog.info(
                "xiaomi.mirror.android.media_route reason=$reason " +
                    "transport=lan_direct peer=$peerHost:$peerPort probePort=$probePort"
            )
            return MirrorMediaRouteSelection(MirrorMediaTransport.LAN_DIRECT, cloudSessionId = null)
        }
        val mirrorTurnRequested = body.args["mirrorTurn"] == "1"
        if (cloudSessionId != null && mirrorTurnRequested && peerMirrorTurnDataChannelSupported()) {
            EdgeLinkLog.info(
                "xiaomi.mirror.android.media_route reason=$reason " +
                    "transport=turn peer=${peerHost ?: "none"}:${peerPort ?: -1} probePort=${probePort ?: -1}"
            )
            return MirrorMediaRouteSelection(MirrorMediaTransport.TURN, cloudSessionId)
        }
        if (cloudSessionId != null) {
            EdgeLinkLog.info(
                "xiaomi.mirror.android.media_route reason=$reason " +
                    "transport=cloudflare peer=${peerHost ?: "none"}:${peerPort ?: -1} probePort=${probePort ?: -1}"
            )
            return MirrorMediaRouteSelection(MirrorMediaTransport.CLOUDFLARE, cloudSessionId)
        }
        EdgeLinkLog.info(
            "xiaomi.mirror.android.media_route reason=$reason " +
                "transport=direct peer=${peerHost ?: "none"}:${peerPort ?: -1} probePort=${probePort ?: -1}"
        )
        return MirrorMediaRouteSelection(MirrorMediaTransport.LEGACY_DIRECT, cloudSessionId = null)
    }

    private fun callMirrorDeviceProviderWithDeadline(
        body: MiLinkCommandBody,
        method: String,
        remoteDeviceId: String? = null,
        deadlineMs: Long
    ): MirrorProviderDeadlineResult =
        callMirrorProviderWithDeadline(method = method, deadlineMs = deadlineMs) {
            callMirrorDeviceProvider(body, method, remoteDeviceId)
        }

    private fun callMirrorBtMacProviderWithDeadline(
        body: MiLinkCommandBody,
        btMac: String,
        btMacSource: String,
        deadlineMs: Long
    ): MirrorProviderDeadlineResult =
        callMirrorProviderWithDeadline(method = "openRemoteDeviceMirrorByBtMac", deadlineMs = deadlineMs) {
            callMirrorBtMacProvider(body, btMac, btMacSource)
        }

    private fun callMirrorDeviceIconClickWithDeadline(
        body: MiLinkCommandBody,
        remoteDeviceId: String,
        deadlineMs: Long
    ): MirrorProviderDeadlineResult =
        callMirrorProviderWithDeadline(method = "performMirrorDeviceIconClick", deadlineMs = deadlineMs) {
            callMirrorDeviceIconClick(body, remoteDeviceId)
        }

    private fun callMirrorProviderWithDeadline(
        method: String,
        deadlineMs: Long,
        call: () -> CommandResult
    ): MirrorProviderDeadlineResult {
        val result = callMirrorProviderSerialized(
            method = method,
            deadlineMs = deadlineMs,
            onLateResult = { lateResult, elapsedMs ->
                EdgeLinkLog.info(
                    "xiaomi.milink.provider_late_result method=$method " +
                        "elapsedMs=$elapsedMs success=${lateResult.success} " +
                        "message=${lateResult.message.forSingleLineLog()}"
                )
            },
            call = call
        )
        return when (result) {
            is MirrorProviderCallResult.Completed ->
                MirrorProviderDeadlineResult.Completed(result.value)
            is MirrorProviderCallResult.Pending ->
                MirrorProviderDeadlineResult.Pending(result.deadlineMs)
        }
    }

    private fun <T> callMirrorProviderSerialized(
        method: String,
        deadlineMs: Long,
        onLateResult: ((T, Long) -> Unit)? = null,
        onTerminal: ((T?, Long) -> Unit)? = null,
        call: () -> T
    ): MirrorProviderCallResult<T> {
        val waitStartedAt = System.currentTimeMillis()
        if (!mirrorProviderLifecycleSemaphore.tryAcquire()) {
            val owner = mirrorProviderInFlightMethod
            EdgeLinkLog.info(
                "xiaomi.milink.provider_inflight_wait method=$method " +
                    "owner=${owner ?: "unknown"} deadlineMs=$deadlineMs"
            )
            val joinDeadlineAt = waitStartedAt + deadlineMs
            var acquired = false
            while (System.currentTimeMillis() < joinDeadlineAt) {
                Thread.sleep(providerInflightPollMs)
                if (mirrorProviderLifecycleSemaphore.tryAcquire()) {
                    acquired = true
                    break
                }
            }
            if (!acquired) {
                EdgeLinkLog.warn(
                    "xiaomi.milink.provider_inflight_timeout method=$method " +
                        "owner=${owner ?: "unknown"} " +
                        "waitedMs=${System.currentTimeMillis() - waitStartedAt} " +
                        "action=skip_provider_call"
                )
                return MirrorProviderCallResult.Pending(deadlineMs)
            }
            EdgeLinkLog.info(
                "xiaomi.milink.provider_inflight_joined method=$method " +
                    "owner=${owner ?: "unknown"} " +
                    "waitedMs=${System.currentTimeMillis() - waitStartedAt}"
            )
        }
        mirrorProviderInFlightMethod = method
        val gapMs = System.currentTimeMillis() - mirrorProviderLastCallStartedAtMs
        if (mirrorProviderLastCallStartedAtMs > 0L && gapMs in 0 until mirrorLifecycleMinGapMs) {
            Thread.sleep(mirrorLifecycleMinGapMs - gapMs)
            EdgeLinkLog.info(
                "xiaomi.milink.provider_rate_limited method=$method gapMs=$gapMs"
            )
        }
        mirrorProviderLastCallStartedAtMs = System.currentTimeMillis()
        val resultRef = AtomicReference<T?>()
        val errorRef = AtomicReference<Throwable?>()
        val doneRef = AtomicBoolean(false)
        val startedAt = System.currentTimeMillis()
        val thread = Thread({
            val result = runCatching {
                call()
            }.onFailure { error ->
                errorRef.set(error)
            }.getOrNull()
            doneRef.set(true)
            if (errorRef.get() == null) {
                resultRef.set(result)
                val elapsedMs = System.currentTimeMillis() - startedAt
                if (elapsedMs > deadlineMs && result != null) {
                    onLateResult?.invoke(result, elapsedMs)
                }
            }
        }, "EdgeLinkMiMirror-$method")
        thread.isDaemon = true
        thread.start()
        thread.join(deadlineMs)
        if (!doneRef.get()) {
            // The provider is still working on this call. Treat it as in
            // flight (not failed): a drainer keeps the lifecycle semaphore
            // until the terminal result so no later call can race inside
            // MirrorControl.
            mirrorProviderDrainScope.launch {
                thread.join(mirrorProviderTerminalCapMs)
                val elapsedMs = System.currentTimeMillis() - startedAt
                val terminal = resultRef.get()
                val terminalError = errorRef.get()
                EdgeLinkLog.info(
                    "xiaomi.milink.provider_inflight_terminal method=$method " +
                        "elapsedMs=$elapsedMs completed=${doneRef.get() && terminalError == null} " +
                        "abandoned=${!doneRef.get()} " +
                        "error=${terminalError?.javaClass?.simpleName ?: "none"}"
                )
                runCatching {
                    onTerminal?.invoke(terminal, elapsedMs)
                }.onFailure { error ->
                    EdgeLinkLog.warn("xiaomi.milink.provider_terminal_hook_failed method=$method", error)
                }
                mirrorProviderInFlightMethod = null
                mirrorProviderLifecycleSemaphore.release()
            }
            return MirrorProviderCallResult.Pending(deadlineMs)
        }
        mirrorProviderInFlightMethod = null
        mirrorProviderLifecycleSemaphore.release()
        errorRef.get()?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return MirrorProviderCallResult.Completed(resultRef.get() as T)
    }

    private fun callMirrorDeviceIconClick(
        body: MiLinkCommandBody,
        remoteDeviceId: String
    ): CommandResult {
        val extras = body.args.toBundle().apply {
            putString("extra", remoteDeviceId)
            putString("remoteDeviceId", remoteDeviceId)
        }
        val result = appContext.contentResolver.callMirrorProvider("performMirrorDeviceIconClick", extras)
        return CommandResult(
            success = false,
            route = "xiaomi.mirror.pending",
            message = "performMirrorDeviceIconClick accepted deviceId=$remoteDeviceId keys=${result?.keySummary().orEmpty()}",
            data = mapOf(
                "remoteDeviceId" to remoteDeviceId,
                "value" to "pending",
                "providerValue" to "pending",
                "pending" to "true",
                "state" to "pending",
                "pendingMethod" to "performMirrorDeviceIconClick",
                "nextMethod" to "openRemoteDeviceMirrorByBtMac",
                "nextDelayMs" to mirrorBtMacFallbackDelayMs.toString(),
                "fallback" to ""
            )
        )
    }

    private fun callMirrorBtMacProvider(
        body: MiLinkCommandBody,
        btMac: String,
        btMacSource: String
    ): CommandResult {
        val normalizedBtMac = btMac.normalizeBluetoothMac() ?: return CommandResult(
            success = false,
            route = "xiaomi.mirror",
            message = "openRemoteDeviceMirrorByBtMac invalid btMac",
            data = mapOf("value" to "invalid_bt_mac", "btMacSource" to btMacSource)
        )
        val deviceType = body.args["deviceType"]?.toIntOrNull() ?: mirrorBtMacDeviceTypeMac
        val remoteSupportLyra = body.args["remoteSupportLyra"].toBooleanOrDefault(true)
        val methodVersion = body.args["method_version"]?.toIntOrNull() ?: mirrorProviderMethodVersion
        val extras = body.args.toBundle().apply {
            putString("btMac", normalizedBtMac)
            putInt("deviceType", deviceType)
            putBoolean("remoteSupportLyra", remoteSupportLyra)
            putInt("method_version", methodVersion)
        }
        val result = appContext.contentResolver.callMirrorProvider("openRemoteDeviceMirrorByBtMac", extras)
        val value = result?.valueInt()
        val success = value == 0
        return CommandResult(
            success = success,
            route = "xiaomi.mirror",
            message = "openRemoteDeviceMirrorByBtMac bt=${normalizedBtMac.maskBluetoothMac()} " +
                "source=$btMacSource deviceType=$deviceType lyra=$remoteSupportLyra value=${value ?: "null"} " +
                "keys=${result?.keySummary().orEmpty()}",
            data = mapOf(
                "btMac" to normalizedBtMac.maskBluetoothMac(),
                "btMacSource" to btMacSource,
                "deviceType" to deviceType.toString(),
                "remoteSupportLyra" to remoteSupportLyra.toString(),
                "value" to (value?.toString() ?: "null")
            )
        )
    }

    private fun callMirrorDeviceProvider(
        body: MiLinkCommandBody,
        method: String,
        remoteDeviceId: String? = null
    ): CommandResult {
        val deviceId = remoteDeviceId ?: body.args["remoteDeviceId"].orEmpty().trim()
        if (deviceId.isBlank()) {
            return CommandResult(
                success = false,
                route = "xiaomi.mirror.unavailable",
                message = "$method remoteDeviceId missing; Xiaomi screen route has no WebRTC fallback",
                data = mapOf(
                    "fallback" to "",
                    "fallbackSuppressed" to "true"
                )
            )
        }
        val extras = body.args.toBundle().apply {
            putString("remoteDeviceId", deviceId)
            putInt("method_version", body.args["method_version"]?.toIntOrNull() ?: mirrorProviderMethodVersion)
        }
        val result = appContext.contentResolver.callMirrorProvider(method, extras)
        val value = result?.valueInt()
        val success = value == 0
        return CommandResult(
            success = success,
            route = "xiaomi.mirror",
            message = "$method deviceId=$deviceId value=${value ?: "null"} keys=${result?.keySummary().orEmpty()}",
            data = mapOf(
                "remoteDeviceId" to deviceId,
                "value" to (value?.toString() ?: "null")
            )
        )
    }

    private fun isXiaomiMirrorDisplayActive(): Boolean =
        runCatching {
            val displayManager = appContext.getSystemService(DisplayManager::class.java)
                ?: return@runCatching false
            displayManager.displays.any { display ->
                val name = display.name.orEmpty()
                name.contains("screen-mirror", ignoreCase = true) ||
                    name.contains("xiaomi", ignoreCase = true) && name.contains("mirror", ignoreCase = true)
            }
        }.getOrDefault(false)

    private fun selectRealMirrorRemoteDevice(sourceSuffix: String? = null): MirrorRemoteSelection? {
        val devicesById = linkedMapOf<String, RemoteDeviceInfo>()
        val samples = mutableListOf<String>()
        appContext.contentResolver.queryCurrentMirrorRemoteDevice()?.let { currentDevice ->
            val id = currentDevice.bestRemoteDeviceId()
            if (!id.isNullOrBlank() && !MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(id)) {
                devicesById[id] = currentDevice
                samples += "current:${currentDevice.compactSummary()}"
            }
        }
        for (query in mirrorRemoteDeviceQueries) {
            val devices = appContext.contentResolver.queryMirrorRemoteDeviceList(
                manufacturer = query.manufacturer,
                platform = query.platform
            )
            if (devices.isNotEmpty()) {
                samples += "${query.label}:${devices.take(2).joinToString("|") { it.compactSummary() }}"
            }
            for (device in devices) {
                val id = device.bestRemoteDeviceId()
                if (!id.isNullOrBlank() && !MiLinkPrivilegeHookPolicy.isFakeMirrorRemoteId(id)) {
                    devicesById[id] = device
                }
            }
        }
        val ranked = devicesById.entries
            .map { (id, device) -> id to device }
            .filter { (_, device) -> device.mirrorReceiverScore() > 0 }
            .maxByOrNull { (_, device) -> device.mirrorReceiverScore() }
            ?: return null
        return MirrorRemoteSelection(
            deviceId = ranked.first,
            source = listOfNotNull("queryRemoteDevices", sourceSuffix).joinToString(":"),
            count = devicesById.size,
            sample = (listOf("selected:${ranked.second.compactSummary()}") + samples)
                .joinToString(";")
                .forSingleLineLog(),
            btMac = ranked.second.mirrorBluetoothMac()
        )
    }

    private fun ContentResolver.queryMirrorRemoteDeviceList(
        manufacturer: String? = null,
        platform: String? = null
    ): List<RemoteDeviceInfo> {
        val queryCall = callMirrorProviderSerialized(
            method = "queryRemoteDevices",
            deadlineMs = mirrorQueryProviderDeadlineMs
        ) {
            callMirrorProvider(
                "queryRemoteDevices",
                Bundle().apply {
                    manufacturer?.let { putString("remoteDeviceManufacturer", it) }
                    platform?.let { putString("device_platform", it) }
                }
            )
        }
        val result = (queryCall as? MirrorProviderCallResult.Completed)?.value ?: return emptyList()
        result.classLoader = RemoteDeviceInfo::class.java.classLoader
        @Suppress("DEPRECATION")
        return result.getParcelableArrayList<RemoteDeviceInfo>("remoteDevices").orEmpty()
    }

    private fun ContentResolver.queryCurrentMirrorRemoteDevice(): RemoteDeviceInfo? {
        val queryCall = callMirrorProviderSerialized(
            method = "queryRemoteDevice",
            deadlineMs = mirrorQueryProviderDeadlineMs
        ) {
            callMirrorProvider("queryRemoteDevice", Bundle())
        }
        val result = (queryCall as? MirrorProviderCallResult.Completed)?.value ?: return null
        result.classLoader = RemoteDeviceInfo::class.java.classLoader
        @Suppress("DEPRECATION")
        return result.getParcelable("remoteDevice")
    }

    private suspend fun querySynergyStatus(): CommandResult {
        val bound = withTimeout(bindTimeoutMs) {
            bindService(
                Intent(mirrorSynergyAction)
                    .setPackage(mirrorPackage)
                    .addCategory(Intent.CATEGORY_DEFAULT)
            )
        }
        return try {
            val active = bound.binder.transactSynergyBoolean(transactionSynergyActive)
            CommandResult(
                success = true,
                route = "xiaomi.mirror.synergy",
                message = "SynergyService bound active=$active descriptor=${bound.binder.descriptorSummary()}",
                data = mapOf("active" to active.toString())
            )
        } finally {
            runCatching { appContext.unbindService(bound.connection) }
        }
    }

    private suspend fun callSynergyRelay(
        body: MiLinkCommandBody,
        transaction: Int,
        name: String
    ): CommandResult {
        val bound = withTimeout(bindTimeoutMs) {
            bindService(
                Intent(mirrorSynergyAction)
                    .setPackage(mirrorPackage)
                    .addCategory(Intent.CATEGORY_DEFAULT)
            )
        }
        return try {
            bound.binder.transactSynergyBundle(transaction, body.args.toBundle())
            CommandResult(
                success = true,
                route = "xiaomi.mirror.synergy",
                message = "$name accepted descriptor=${bound.binder.descriptorSummary()}",
                data = mapOf("transaction" to transaction.toString())
            )
        } finally {
            runCatching { appContext.unbindService(bound.connection) }
        }
    }

    private suspend fun bindDistAudio(): CommandResult {
        val bound = withTimeout(bindTimeoutMs) {
            bindService(Intent(distAudioAction).setPackage(audioMonitorPackage))
        }
        return try {
            CommandResult(
                success = true,
                route = "xiaomi.distAudio",
                message = "DistAudioService bound descriptor=${bound.binder.descriptorSummary()}",
                data = mapOf("descriptor" to bound.binder.descriptorSummary())
            )
        } finally {
            runCatching { appContext.unbindService(bound.connection) }
        }
    }

    private suspend fun bindService(intent: Intent): BoundService =
        suspendCancellableCoroutine { continuation ->
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, service: IBinder) {
                    if (continuation.isActive) {
                        continuation.resume(BoundService(service, this))
                    }
                }

                override fun onServiceDisconnected(name: ComponentName) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(
                            IllegalStateException("service disconnected ${name.flattenToShortString()}")
                        )
                    }
                }

                override fun onNullBinding(name: ComponentName) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(
                            IllegalStateException("service returned null ${name.flattenToShortString()}")
                        )
                    }
                }
            }

            val bound = runCatching {
                appContext.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            }.getOrElse { error ->
                continuation.resumeWithException(error)
                return@suspendCancellableCoroutine
            }
            if (!bound) {
                continuation.resumeWithException(IllegalStateException("bindService returned false"))
                return@suspendCancellableCoroutine
            }
            continuation.invokeOnCancellation {
                runCatching { appContext.unbindService(connection) }
            }
        }

    private fun ContentResolver.callMirrorProvider(method: String, extras: Bundle? = null): Bundle? =
        if (Build.VERSION.SDK_INT >= 29) {
            call(mirrorCallProviderAuthority, method, null, extras)
        } else {
            call(mirrorCallProviderUri, method, null, extras)
        }

    private fun Map<String, String>.toBundle(): Bundle =
        Bundle().also { bundle ->
            forEach { (key, value) -> bundle.putString(key, value) }
        }

    private fun IBinder.transactSynergyBoolean(code: Int): Boolean {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(synergyDescriptor)
            check(transact(code, data, reply, 0)) { "transact($code) returned false" }
            reply.readException()
            return reply.readInt() != 0
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    private fun IBinder.transactSynergyBundle(code: Int, bundle: Bundle) {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(synergyDescriptor)
            data.writeInt(1)
            bundle.writeToParcel(data, 0)
            check(transact(code, data, reply, 0)) { "transact($code) returned false" }
            reply.readException()
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    private fun IBinder.descriptorSummary(): String =
        runCatching { interfaceDescriptor.orEmpty() }
            .getOrElse { error -> "${error.javaClass.simpleName}:${error.message.orEmpty()}" }

    private fun Bundle.valueInt(): Int? =
        when {
            containsKey("value") -> getInt("value")
            containsKey("result") -> getInt("result")
            else -> null
        }

    private fun Bundle.keySummary(): String =
        keySet().sorted().joinToString("|") { key ->
            "$key=${valueSummary(get(key))}"
        }

    private fun valueSummary(value: Any?): String =
        when (value) {
            null -> "null"
            is IBinder -> "binder:${value.descriptorSummary()}"
            is ArrayList<*> -> "list:${value.size}"
            else -> value.toString()
        }

    private fun RemoteDeviceInfo.compactSummary(): String =
        "id=${id ?: "-"} platform=${platform ?: "-"} lyra=${flagText(KEY_IS_LYRA)} " +
            "sink=${flagText(KEY_IS_SINK)} mirror=${flagText(KEY_IS_MIRROR_ENABLED)} " +
            "showMirror=${flagText(KEY_IS_SHOW_MIRROR)} connect=$connectType relay=$isMediaRelay " +
            "address=${address ?: "-"} bt=${mirrorBluetoothMac()?.maskBluetoothMac() ?: "-"} name=${displayName ?: "-"}"

    private fun RemoteDeviceInfo.bestRemoteDeviceId(): String? =
        id?.takeIf { it.isNotBlank() } ?: deviceId?.takeIf { it.isNotBlank() }

    private fun RemoteDeviceInfo.mirrorBluetoothMac(): String? =
        getBundle().getString(KEY_BT_MAC)?.normalizeBluetoothMac()

    private fun RemoteDeviceInfo.mirrorReceiverScore(): Int {
        val platformText = platform.orEmpty().lowercase()
        val nameText = displayName.orEmpty().lowercase()
        var score = 0
        if (platformText.contains("androidphone")) {
            score -= 200
        }
        if (platformText.contains("mac") || platformText.contains("pc") || platformText.contains("windows")) {
            score += 100
        }
        if (platform == RemoteDeviceInfo.PLATFORM_WINDOWS || platform == "CommonPc" || platform == "Mac") {
            score += 80
        }
        if (flagEnabled(KEY_IS_LYRA)) {
            score += 80
        }
        if (flagEnabled(KEY_IS_SINK)) {
            score += 60
        }
        if (flagEnabled(KEY_IS_MIRROR_ENABLED)) {
            score += 50
        }
        if (flagEnabled(KEY_IS_SHOW_MIRROR)) {
            score += 40
        }
        if (connectType == RemoteDeviceInfo.CONNECT_TYPE_ADVANCED) {
            score += 20
        }
        if (isMediaRelay != RemoteDeviceInfo.MEDIA_RELAY_NOT_SUPPORT) {
            score += 20
        }
        if (flagEnabled(KEY_DESKTOP_SWITCH)) {
            score += 10
        }
        if (flagEnabled(KEY_HANDOFF_SWITCH)) {
            score += 10
        }
        if (nameText.contains("mac") || nameText.contains("pc") || nameText.contains("windows")) {
            score += 10
        }
        return score
    }

    private fun RemoteDeviceInfo.flagText(key: String): String =
        getBundle().rawFlagText(key)

    private fun RemoteDeviceInfo.flagEnabled(key: String): Boolean =
        getBundle().truthyFlag(key)

    private fun Bundle.rawFlagText(key: String): String =
        when (val value = get(key)) {
            null -> "-"
            else -> value.toString()
        }

    private fun Bundle.truthyFlag(key: String): Boolean =
        when (val value = get(key)) {
            is Boolean -> value
            is Int -> value > 0
            is Long -> value > 0L
            is String -> value.equals("true", ignoreCase = true) || value.toIntOrNull()?.let { it > 0 } == true
            else -> false
        }

    private data class BoundService(
        val binder: IBinder,
        val connection: ServiceConnection
    )

    private data class CommandResult(
        val success: Boolean,
        val route: String,
        val message: String,
        val data: Map<String, String> = emptyMap()
    )

    private data class MirrorRemoteSelection(
        val deviceId: String,
        val source: String,
        val count: Int,
        val sample: String,
        val btMac: String?
    )

    private data class MirrorRemoteDeviceQuery(
        val label: String,
        val manufacturer: String? = null,
        val platform: String? = null
    )

    private sealed class MirrorProviderDeadlineResult {
        data class Completed(val result: CommandResult) : MirrorProviderDeadlineResult()
        data class Pending(val deadlineMs: Long) : MirrorProviderDeadlineResult()
    }

    private sealed class MirrorProviderCallResult<out T> {
        data class Completed<T>(val value: T) : MirrorProviderCallResult<T>()
        data class Pending(val deadlineMs: Long) : MirrorProviderCallResult<Nothing>()
    }

    private fun String.forSingleLineLog(): String =
        replace('\n', ' ').replace('\r', ' ').take(240)

    private fun String?.toBooleanOrDefault(default: Boolean): Boolean =
        when (this?.lowercase()) {
            "true", "1", "yes", "y" -> true
            "false", "0", "no", "n" -> false
            else -> default
        }

    private fun String.normalizeBluetoothMac(): String? {
        val normalized = trim().uppercase()
        return normalized.takeIf { bluetoothMacRegex.matches(it) }
    }

    private fun String.maskBluetoothMac(): String =
        split(':').takeIf { it.size == 6 }?.let { "**:**:**:**:${it[4]}:${it[5]}" } ?: this

    private fun preferredLocalIPv4Address(): String? =
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

    private companion object {
        const val COMMAND_MISHARE_OPEN_SETTINGS = "xiaomi.mishare.openSettings"
        const val COMMAND_MISHARE_DISCOVER = "xiaomi.mishare.discover"
        const val COMMAND_MISHARE_NSD_DISCOVER = "xiaomi.mishare.nsdDiscover"
        const val COMMAND_MI_CONNECT_NETWORKING_PROBE = "xiaomi.mi_connect.networkingProbe"
        const val COMMAND_MI_CONNECT_NETWORKING_REGISTER = "xiaomi.mi_connect.registerLyraService"
        const val COMMAND_MIRROR_QUERY_REMOTE_DEVICES = "xiaomi.mirror.queryRemoteDevices"
        const val COMMAND_MIRROR_START_MAIN_DISPLAY = "xiaomi.mirror.startMainDisplay"
        const val COMMAND_MIRROR_LOCK_STATE = "xiaomi.mirror.lockState"
        const val COMMAND_MIRROR_GLOBAL = "xiaomi.mirror.global"
        const val COMMAND_MIRROR_OPEN_REMOTE_DEVICE = "xiaomi.mirror.openRemoteDeviceMirror"
        const val COMMAND_SYNERGY_STATUS = "xiaomi.synergy.status"
        const val COMMAND_SYNERGY_SHOW_RELAY_DATA = "xiaomi.synergy.showRelayData"
        const val COMMAND_SYNERGY_SYNC_RELAY_DATA = "xiaomi.synergy.syncRelayData"
        const val COMMAND_SYNERGY_CANCEL_RELAY_DATA = "xiaomi.synergy.cancelRelayData"
        const val COMMAND_DIST_AUDIO_BIND = "xiaomi.distaudio.bind"

        const val miSharePackage = "com.miui.mishare.connectivity"
        const val miShareSettingsAction = "com.miui.mishare.action.MiShareSettings"
        const val mirrorPackage = "com.xiaomi.mirror"
        const val mirrorSynergyAction = "com.xiaomi.mirror.ACTION_SYNERGY_SERVICE"
        const val audioMonitorPackage = "com.miui.audiomonitor"
        const val distAudioAction = "com.miui.audiomonitor.action.DistAudioService"
        const val mirrorCallProviderAuthority = "com.xiaomi.mirror.callprovider"
        const val synergyDescriptor = "com.xiaomi.mirror.ISynergyService"
        const val transactionSynergyActive = 1
        const val transactionShowRelayData = 3
        const val transactionSyncRelayData = 4
        const val transactionCancelRelayData = 5
        const val bindTimeoutMs = 3_000L
        const val mirrorProviderMethodVersion = 3
        const val mirrorBtMacDeviceTypeMac = 3
        const val mirrorRealScreenProviderQuickDeadlineMs = 8_000L
        const val mirrorIconClickProviderDeadlineMs = 2_000L
        const val mirrorBtMacFallbackDelayMs = 3_000L
        const val mirrorNativeShortcutProviderDeadlineMs = 8_000L
        const val mirrorCastChannelReadyTimeoutMs = 10_000L
        const val mirrorCastChannelPollIntervalMs = 250L
        const val mirrorCastChannelFreshMs = 30_000L
        const val mirrorKeyboardProviderDeadlineMs = 800L
        const val mirrorQueryProviderDeadlineMs = 3_000L
        const val mirrorProviderTerminalCapMs = 30_000L
        const val providerInflightPollMs = 25L
        const val mirrorLifecycleMinGapMs = 200L
        const val KEY_BT_MAC = "bt_mac"
        const val KEY_DESKTOP_SWITCH = "desktop_switch"
        const val KEY_HANDOFF_SWITCH = "handoff_switch"
        const val KEY_IS_LYRA = "is_lyra"
        const val KEY_IS_MIRROR_ENABLED = "is_mirror_enabled"
        const val KEY_IS_SHOW_MIRROR = "is_show_mirror"
        const val KEY_IS_SINK = "is_sink"
        val mirrorCallProviderUri: Uri = Uri.parse("content://$mirrorCallProviderAuthority")
        val bluetoothMacRegex = Regex("""[0-9A-F]{2}(:[0-9A-F]{2}){5}""")
        val mirrorRemoteDeviceQueries = listOf(
            MirrorRemoteDeviceQuery(label = "all"),
            MirrorRemoteDeviceQuery(label = "xiaomi", manufacturer = RemoteDeviceInfo.MANUFACTURER_XIAOMI),
            MirrorRemoteDeviceQuery(label = "other", manufacturer = RemoteDeviceInfo.MANUFACTURER_OTHER),
            MirrorRemoteDeviceQuery(label = "windows", platform = RemoteDeviceInfo.PLATFORM_WINDOWS),
            MirrorRemoteDeviceQuery(label = "mac", platform = "Mac"),
            MirrorRemoteDeviceQuery(label = "commonPc", platform = "CommonPc"),
            MirrorRemoteDeviceQuery(label = "androidPad", platform = RemoteDeviceInfo.PLATFORM_ANDROID_PAD),
            MirrorRemoteDeviceQuery(label = "androidPadCar", platform = RemoteDeviceInfo.PLATFORM_ANDROID_PAD_CAR)
        )
    }
}
