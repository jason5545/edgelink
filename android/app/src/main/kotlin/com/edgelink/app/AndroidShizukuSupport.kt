package com.edgelink.app

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.DeadObjectException
import android.os.IBinder
import android.os.Process
import android.os.RemoteException
import android.telecom.TelecomManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import rikka.shizuku.Shizuku
import java.net.Inet4Address
import java.net.NetworkInterface
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val SHIZUKU_REQUEST_CODE = 61_240
private const val SHIZUKU_USER_SERVICE_VERSION = 6
private const val SHIZUKU_USER_SERVICE_MAX_ATTEMPTS = 2
private const val SHIZUKU_USER_SERVICE_RETRY_DELAY_MS = 200L
private const val ANDROID_UIDS_PER_USER = 100_000
private const val PHONE_CALL_RELAY_LATCH_MAX_TTL_MS = 120_000L
private const val PHONE_RELAY_DEFAULT_PORT = 7_102
private const val PHONE_RELAY_SINK_RTSP_PORT = 15_550
private const val PHONE_DTMF_KEY_DELAY_MS = 120L
private const val MIRROR_SCREEN_REMOTE_TTL_MS = 180_000L
private val MIRROR_BT_LOGCAT_COMMAND = arrayOf(
    "logcat",
    "-d",
    "-t",
    "3000",
    "-v",
    "time",
    "BluetoothRemoteDevices:D",
    "HyperRemoteDevicesAdapter:D",
    "ScanController:V",
    "*:S"
)

data class AndroidShizukuState(
    val available: Boolean,
    val supported: Boolean,
    val permissionGranted: Boolean,
    val permissionRequestBlocked: Boolean,
    val uid: Int?
) {
    val canUse: Boolean
        get() = available && supported && permissionGranted

    val canRequestPermission: Boolean
        get() = available && supported && !permissionGranted && !permissionRequestBlocked
}

data class ShizukuOperationResult(
    val success: Boolean,
    val message: String
)

data class MirrorBluetoothMacResult(
    val btMac: String?,
    val source: String,
    val message: String
)

object AndroidShizukuSupport {
    val requestCode: Int = SHIZUKU_REQUEST_CODE
    private val serviceMutex = Mutex()

    fun currentState(): AndroidShizukuState {
        val available = runCatching { Shizuku.pingBinder() }.getOrDefault(false)
        if (!available) {
            return AndroidShizukuState(
                available = false,
                supported = false,
                permissionGranted = false,
                permissionRequestBlocked = false,
                uid = null
            )
        }

        val supported = runCatching { !Shizuku.isPreV11() && Shizuku.getVersion() >= 11 }
            .getOrDefault(false)
        val permissionGranted = supported &&
            runCatching { Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED }
                .getOrDefault(false)
        val permissionRequestBlocked = supported &&
            !permissionGranted &&
            runCatching { Shizuku.shouldShowRequestPermissionRationale() }
                .getOrDefault(false)
        val uid = if (permissionGranted) {
            runCatching { Shizuku.getUid() }.getOrNull()
        } else {
            null
        }

        return AndroidShizukuState(
            available = true,
            supported = supported,
            permissionGranted = permissionGranted,
            permissionRequestBlocked = permissionRequestBlocked,
            uid = uid
        )
    }

    fun hasPermission(): Boolean = currentState().canUse

    fun requestPermission(): Boolean {
        val state = currentState()
        if (state.permissionGranted) {
            return true
        }
        if (!state.canRequestPermission) {
            return false
        }
        return runCatching {
            Shizuku.requestPermission(SHIZUKU_REQUEST_CODE)
            true
        }.getOrElse { error ->
            EdgeLinkLog.warn("shizuku.android.permission_request_failed", error)
            false
        }
    }

    suspend fun enableRemoteInput(context: Context): ShizukuOperationResult =
        withService(context) { service ->
            val results = mutableListOf<ShizukuCommandResult>()
            val component = ComponentName(context, RemoteInputService::class.java).flattenToString()
            appendSecureComponent(
                service = service,
                key = "enabled_accessibility_services",
                component = component,
                results = results
            )
            results += service.runCommandResult(
                arrayOf("settings", "put", "secure", "accessibility_enabled", "1")
            )
            results.toOperationResult("remote_input")
        }

    suspend fun enableNotificationAccess(context: Context): ShizukuOperationResult =
        withService(context) { service ->
            val results = mutableListOf<ShizukuCommandResult>()
            if (Build.VERSION.SDK_INT >= 33) {
                results += service.runCommandResult(
                    arrayOf("pm", "grant", context.packageName, Manifest.permission.POST_NOTIFICATIONS)
                )
            }
            val component = ComponentName(context, AndroidNotificationListenerService::class.java).flattenToString()
            results += service.runCommandResult(
                arrayOf(
                    "cmd",
                    "notification",
                    "allow_listener",
                    component,
                    (Process.myUid() / ANDROID_UIDS_PER_USER).toString()
                )
            )
            results.toOperationResult("notification")
        }

    suspend fun grantSmsPermissions(context: Context): ShizukuOperationResult =
        withService(context) { service ->
            val results = AndroidSmsSync.requiredPermissions.map { permission ->
                service.runCommandResult(arrayOf("pm", "grant", context.packageName, permission))
            }
            results.toOperationResult("sms")
        }

    suspend fun prepareScreenAccess(context: Context): ShizukuOperationResult =
        withService(context) { service ->
            val results = mutableListOf(
                service.runCommandResult(arrayOf("cmd", "appops", "set", context.packageName, "PROJECT_MEDIA", "allow")),
                service.runCommandResult(arrayOf("cmd", "appops", "set", context.packageName, "WRITE_SETTINGS", "allow")),
                service.runCommandResult(arrayOf("cmd", "appops", "set", context.packageName, "SYSTEM_ALERT_WINDOW", "allow"))
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                results += service.runCommandResult(
                    arrayOf("pm", "grant", context.packageName, Manifest.permission.RECORD_AUDIO)
                )
            }
            results.toOperationResult("screen", allowPartial = true)
        }

    suspend fun putSecureInt(context: Context, key: String, value: Int): ShizukuOperationResult =
        withService(context) { service ->
            val result = service.runCommandResult(
                arrayOf("settings", "put", "secure", key, value.toString())
            )
            listOf(result).toOperationResult("secure_setting:$key")
        }

    suspend fun probeMiLinkRoot(context: Context): ShizukuOperationResult {
        val state = currentState()
        if (state.uid != 0) {
            return ShizukuOperationResult(
                success = false,
                message = "MiLink probe requires Shizuku root uid; current=${state.uid}"
            )
        }

        return withService(context) { service ->
            val results = miLinkProbeCommands.map { probe ->
                val result = service.runCommandResult(probe.command)
                EdgeLinkLog.info(
                    "xiaomi.milink.root_probe name=${probe.name} exit=${result.exitCode} " +
                        "stdout=${result.stdout.forSingleLineLog()} stderr=${result.stderr.forSingleLineLog()}"
                )
                probe to result
            }
            val successCount = results.count { (_, result) -> result.isProbeSuccess }
            val summary = results.joinToString { (probe, result) ->
                "${probe.name}=${if (result.isProbeSuccess) "ok" else "exit:${result.exitCode}"}"
            }
            ShizukuOperationResult(
                success = successCount > 0,
                message = "MiLink root probe $successCount/${results.size}: $summary"
            )
        }
    }

    suspend fun probeMiLinkAttributionSpoof(context: Context): ShizukuOperationResult =
        withContext(Dispatchers.IO) {
            val probes = listOf(
                "edgelink_direct" to context.applicationContext,
                "com.milink.service" to context.createPackageContext(
                    "com.milink.service",
                    Context.CONTEXT_IGNORE_SECURITY
                ),
                "com.xiaomi.mi_connect_service" to context.createPackageContext(
                    "com.xiaomi.mi_connect_service",
                    Context.CONTEXT_IGNORE_SECURITY
                ),
                "com.xiaomi.mirror" to context.createPackageContext(
                    "com.xiaomi.mirror",
                    Context.CONTEXT_IGNORE_SECURITY
                )
            )
            val results = probes.map { (name, probeContext) ->
                val result = runCatching {
                    val bundle = probeContext.contentResolver.call(
                        Uri.parse("content://provider.milink.mi.com/messenger"),
                        "content://provider.milink.mi.com/messenger#ping",
                        null,
                        null
                    )
                    "ok package=${probeContext.packageName} op=${probeContext.opPackageName} result=$bundle"
                }.getOrElse { error ->
                    "failed package=${probeContext.packageName} op=${probeContext.opPackageName} " +
                        "error=${error.javaClass.simpleName}:${error.message}"
                }
                EdgeLinkLog.info("xiaomi.milink.attribution_probe name=$name $result")
                name to result
            }
            val successCount = results.count { (_, result) -> result.startsWith("ok ") }
            ShizukuOperationResult(
                success = successCount > 0,
                message = "MiLink attribution probe $successCount/${results.size}"
            )
        }

    suspend fun openMiShareSettings(context: Context): ShizukuOperationResult =
        withService(context) { service ->
            val result = service.runCommandResult(
                arrayOf(
                    "am",
                    "start",
                    "-a",
                    "com.miui.mishare.action.MiShareSettings",
                    "-p",
                    "com.miui.mishare.connectivity"
                )
            )
            listOf(result).toOperationResult("mishare:settings")
        }

    suspend fun armMirrorScreenRemote(
        context: Context,
        peerHost: String? = null,
        peerPort: Int? = null
    ): ShizukuOperationResult =
        withService(context) { service ->
            val untilEpochMs = System.currentTimeMillis() + MIRROR_SCREEN_REMOTE_TTL_MS
            val sanitizedPeerHost = MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost(peerHost)
            val sanitizedPeerPort = peerPort?.takeIf { it in 1..65_535 }
            val commands = mutableListOf(
                arrayOf(
                    "setprop",
                    MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_SCREEN_PROPERTY,
                    "pad"
                ),
                arrayOf(
                    "setprop",
                    MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_SCREEN_UNTIL_PROPERTY,
                    untilEpochMs.toString()
                ),
                arrayOf(
                    "setprop",
                    MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_SCREEN_AUDIO_OWNER_PROPERTY,
                    "official"
                )
            )
            sanitizedPeerHost?.let {
                commands += arrayOf(
                    "setprop",
                    MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PEER_IP_PROPERTY,
                    it
                )
            }
            sanitizedPeerPort?.let {
                commands += arrayOf(
                    "setprop",
                    MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PEER_PORT_PROPERTY,
                    it.toString()
                )
            }
            val results = commands.map { command -> service.runCommandResult(command) }
            results.toOperationResult(
                "mirror:screen_remote peer=${sanitizedPeerHost ?: "default"}:${sanitizedPeerPort ?: "default"}"
            )
        }

    suspend fun recentMirrorBluetoothMac(context: Context): MirrorBluetoothMacResult =
        withService(context) { service ->
            val result = service.runCommandResult(
                MIRROR_BT_LOGCAT_COMMAND
            )
            if (!result.success) {
                EdgeLinkLog.warn(
                    "xiaomi.mirror.bt_mac_probe_failed exit=${result.exitCode} " +
                        "stderr=${result.stderr.forSingleLineLog()}"
                )
                return@withService MirrorBluetoothMacResult(
                    btMac = null,
                    source = "logcat",
                    message = "logcat exit=${result.exitCode}"
                )
            }

            val selected = mirrorBluetoothMacPatterns
                .flatMap { (source, pattern) ->
                    pattern.findAll(result.stdout).map { source to it.groupValues[1].uppercase() }
                }
                .lastOrNull()
            EdgeLinkLog.info(
                "xiaomi.mirror.bt_mac_probe found=${selected?.first ?: "none"} " +
                    "bt=${selected?.second?.maskBluetoothMac() ?: "none"}"
            )
            MirrorBluetoothMacResult(
                btMac = selected?.second,
                source = selected?.first ?: "logcat",
                message = if (selected == null) "bt mac not found" else "bt mac from ${selected.first}"
            )
        }

    suspend fun writeScreenShareSetting(
        context: Context,
        namespace: String,
        key: String,
        value: String?
    ): ShizukuOperationResult = withService(context) { service ->
        val writeCommand = if (value == null) {
            arrayOf("settings", "delete", namespace, key)
        } else {
            arrayOf("settings", "put", namespace, key, value)
        }
        val writeResult = service.runCommandResult(writeCommand)
        val readResult = service.runCommandResult(arrayOf("settings", "get", namespace, key))
        val observed = readResult.stdout.trim().takeUnless { it.isBlank() || it == "null" }
        val success = writeResult.success && readResult.success && observed == value
        ShizukuOperationResult(
            success = success,
            message = if (success) {
                "setting:$namespace:$key ok"
            } else {
                "setting:$namespace:$key write=${writeResult.exitCode} read=${readResult.exitCode} expected=$value observed=$observed"
            }
        )
    }

    suspend fun armPhoneCallRelay(context: Context, ttlMs: Long): ShizukuOperationResult {
        val boundedTtlMs = ttlMs.coerceIn(1_000L, PHONE_CALL_RELAY_LATCH_MAX_TTL_MS)
        val untilEpochMs = System.currentTimeMillis() + boundedTtlMs
        return writeDebugProperty(
            context = context,
            key = MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY,
            value = untilEpochMs.toString(),
            name = "phone:relay_latch"
        )
    }

    suspend fun clearPhoneCallRelay(context: Context): ShizukuOperationResult =
        withService(context) { service ->
            val results = listOf(
                service.runCommandResult(
                    arrayOf(
                        "setprop",
                        MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY,
                        "0"
                    )
                ),
                service.runCommandResult(
                    arrayOf(
                        "setprop",
                        MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_STATE_PROPERTY,
                        "idle"
                    )
                )
            )
            results.toOperationResult("phone:relay_latch_clear")
        }

    suspend fun configurePhoneCallRelayHooks(
        context: Context,
        relayHost: String?,
        relayPort: Int?
    ): ShizukuOperationResult = withService(context) { service ->
        val endpointPort = relayPort?.takeIf { it in 1..65_535 } ?: PHONE_RELAY_DEFAULT_PORT
        val localHost = preferredLocalIPv4Address()
        val peerHost = localHost ?: MiLinkPrivilegeHookPolicy.mirrorFakeRemoteEndpointHost(relayHost)
        val sinkPort = PHONE_RELAY_SINK_RTSP_PORT
        val commands = mutableListOf<Array<String>>()

        fun setProp(key: String, value: String) {
            commands += arrayOf("setprop", key, value)
        }

        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PROPERTY, "pad")
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_ATTACH_PROPERTY, "1")
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_KEY_PROPERTY, "1")
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_USING_PAD_PROPERTY, "1")
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_STATE_PROPERTY, "offhook")
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_PROPERTY, "1")
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_PARAMS_PROPERTY, "1")
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_START_PROPERTY, "both")
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_SINK_ARG_PROPERTY, sinkPort.toString())
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PLAIN_RTP_PROPERTY, "1")
        peerHost?.let { setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PEER_IP_PROPERTY, it) }
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PEER_PORT_PROPERTY, sinkPort.toString())
        localHost?.let { setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_LOCAL_IP_PROPERTY, it) }
        setProp(MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_LOCAL_PORT_PROPERTY, endpointPort.toString())

        val results = commands.map { command -> service.runCommandResult(command) }
        results.toOperationResult(
            "phone:relay_hooks peer=${peerHost ?: "default"}:$sinkPort " +
                "local=${localHost ?: "default"}:$endpointPort"
        )
    }

    suspend fun placePhoneCall(context: Context, telUri: String): ShizukuOperationResult =
        withContext(Dispatchers.IO) {
            val appContext = context.applicationContext
            val permissionResult = ensurePhoneCallPermission(appContext)
            if (!permissionResult.success) {
                return@withContext permissionResult
            }
            runCatching {
                ensurePhoneCallCompanionApp(appContext)
            }.onSuccess { result ->
                if (result.success) {
                    EdgeLinkLog.info("phone.android.companion_registered message=${result.message}")
                } else {
                    EdgeLinkLog.warn("phone.android.companion_register_failed message=${result.message}")
                }
            }.onFailure { error ->
                EdgeLinkLog.warn("phone.android.companion_register_failed", error)
            }
            val telecomManager = appContext.getSystemService(TelecomManager::class.java)
                ?: return@withContext ShizukuOperationResult(
                    success = false,
                    message = "phone:dial telecom_service_unavailable"
                )
            runCatching {
                telecomManager.placeCall(Uri.parse(telUri), Bundle())
            }.fold(
                onSuccess = {
                    ShizukuOperationResult(
                        success = true,
                        message = "phone:dial telecom_place_call"
                    )
                },
                onFailure = { error ->
                    ShizukuOperationResult(
                        success = false,
                        message = "phone:dial telecom_place_call_failed=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                    )
                }
            )
        }

    suspend fun pressPhoneKey(context: Context, keyCode: String): ShizukuOperationResult =
        withService(context) { service ->
            val result = service.runCommandResult(arrayOf("input", "keyevent", keyCode))
            listOf(result).toOperationResult("phone:keyevent:$keyCode")
        }

    suspend fun sendPhoneDtmfSequence(context: Context, sequence: String): ShizukuOperationResult =
        withContext(Dispatchers.IO) {
            val directResult = EdgeLinkInCallService.sendDtmfSequence(sequence)
            if (directResult.success) {
                return@withContext directResult
            }

            val companionResult = runCatching {
                ensurePhoneCallCompanionApp(context.applicationContext)
            }.getOrElse { error ->
                ShizukuOperationResult(
                    success = false,
                    message = "phone:companion exception=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                )
            }
            Thread.sleep(PHONE_DTMF_KEY_DELAY_MS)

            val retryResult = EdgeLinkInCallService.sendDtmfSequence(sequence)
            if (retryResult.success) {
                retryResult.copy(message = "${retryResult.message} after_companion")
            } else {
                ShizukuOperationResult(
                    success = false,
                    message = "${retryResult.message}; companion=${companionResult.message}"
                )
            }
        }

    private suspend fun ensurePhoneCallCompanionApp(context: Context): ShizukuOperationResult =
        withService(context) { service ->
            val appOpsResult = service.runCommandResult(
                arrayOf("cmd", "appops", "set", context.packageName, "MANAGE_ONGOING_CALLS", "allow")
            )
            val removeResult = service.runCommandResult(
                arrayOf("cmd", "telecom", "add-or-remove-call-companion-app", context.packageName, "0")
            )
            val addResult = service.runCommandResult(
                arrayOf("cmd", "telecom", "add-or-remove-call-companion-app", context.packageName, "1")
            )
            val waitResult = service.runCommandResult(arrayOf("cmd", "telecom", "wait-on-handlers"))
            val boundResult = service.runCommandResult(
                arrayOf("cmd", "telecom", "is-non-ui-in-call-service-bound", context.packageName)
            )
            val boundText = boundResult.stdout.trim().ifBlank { boundResult.stderr.trim() }
            val telecomManager = context.getSystemService(TelecomManager::class.java)
            val hasManageOngoingCalls = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                runCatching {
                    telecomManager?.hasManageOngoingCallsPermission() == true
                }.getOrDefault(false)
            ShizukuOperationResult(
                success = addResult.success && waitResult.success && hasManageOngoingCalls,
                message = "phone:companion appops=${appOpsResult.exitCode} " +
                    "remove=${removeResult.exitCode} add=${addResult.exitCode} wait=${waitResult.exitCode} " +
                    "manage=$hasManageOngoingCalls bound=${boundText.forSingleLineLog()}"
            )
        }

    private suspend fun ensurePhoneCallPermission(context: Context): ShizukuOperationResult {
        if (context.checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED) {
            return ShizukuOperationResult(
                success = true,
                message = "phone:dial_permission already_granted"
            )
        }
        return withService(context) { service ->
            val grantResult = service.runCommandResult(
                arrayOf("pm", "grant", context.packageName, Manifest.permission.CALL_PHONE)
            )
            val granted = context.checkSelfPermission(Manifest.permission.CALL_PHONE) ==
                PackageManager.PERMISSION_GRANTED
            ShizukuOperationResult(
                success = grantResult.success && granted,
                message = if (grantResult.success && granted) {
                    "phone:dial_permission granted"
                } else {
                    "phone:dial_permission grant=${grantResult.exitCode} granted=$granted " +
                        "stderr=${grantResult.stderr.forSingleLineLog()}"
                }
            )
        }
    }

    private suspend fun writeDebugProperty(
        context: Context,
        key: String,
        value: String,
        name: String
    ): ShizukuOperationResult = withService(context) { service ->
        val result = service.runCommandResult(arrayOf("setprop", key, value))
        listOf(result).toOperationResult(name)
    }

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

    private suspend fun <T> withService(
        context: Context,
        block: (IEdgeLinkShizukuService) -> T
    ): T {
        var lastError: Throwable? = null
        repeat(SHIZUKU_USER_SERVICE_MAX_ATTEMPTS) { index ->
            val attempt = index + 1
            try {
                return withServiceOnce(context, block)
            } catch (error: Throwable) {
                if (!error.isTransientShizukuServiceError() || attempt >= SHIZUKU_USER_SERVICE_MAX_ATTEMPTS) {
                    throw error
                }
                lastError = error
                EdgeLinkLog.warn(
                    "shizuku.android.user_service_retry attempt=$attempt/${SHIZUKU_USER_SERVICE_MAX_ATTEMPTS}",
                    error
                )
                delay(SHIZUKU_USER_SERVICE_RETRY_DELAY_MS)
            }
        }
        throw lastError ?: IllegalStateException("Shizuku UserService failed.")
    }

    private suspend fun <T> withServiceOnce(
        context: Context,
        block: (IEdgeLinkShizukuService) -> T
    ): T = withContext(Dispatchers.IO) {
        serviceMutex.withLock {
            ensureUsable()
            val boundService = bindService(context.applicationContext)
            try {
                block(boundService.service)
            } finally {
                boundService.close()
            }
        }
    }

    private fun ensureUsable() {
        val state = currentState()
        when {
            !state.available -> error("Shizuku binder is not available.")
            !state.supported -> error("Shizuku API version is not supported.")
            !state.permissionGranted -> error("Shizuku permission is not granted.")
        }
    }

    private suspend fun bindService(context: Context): BoundShizukuService =
        suspendCancellableCoroutine { continuation ->
            val args = userServiceArgs(context)
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                    if (!continuation.isActive) {
                        return
                    }
                    val service = IEdgeLinkShizukuService.Stub.asInterface(binder)
                    continuation.resume(BoundShizukuService(args, this, service))
                }

                override fun onServiceDisconnected(name: ComponentName) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(ShizukuUserServiceDisconnectedException())
                    }
                }
            }

            runCatching {
                Shizuku.bindUserService(args, connection)
            }.onFailure { error ->
                continuation.resumeWithException(error)
            }

            continuation.invokeOnCancellation {
                runCatching { Shizuku.unbindUserService(args, connection, true) }
            }
        }

    private fun userServiceArgs(context: Context): Shizuku.UserServiceArgs =
        Shizuku.UserServiceArgs(
            ComponentName(context.packageName, EdgeLinkShizukuService::class.java.name)
        )
            .daemon(false)
            .processNameSuffix("shizuku")
            .tag("edgelink-shizuku")
            .version(SHIZUKU_USER_SERVICE_VERSION)

    private fun appendSecureComponent(
        service: IEdgeLinkShizukuService,
        key: String,
        component: String,
        results: MutableList<ShizukuCommandResult>
    ) {
        val getResult = service.runCommandResult(arrayOf("settings", "get", "secure", key))
        results += getResult
        if (!getResult.success) {
            return
        }

        val current = getResult.stdout.trim().takeUnless { it.isBlank() || it == "null" }.orEmpty()
        val components = current.split(':')
            .filter { it.isNotBlank() }
            .toMutableList()
        if (component in components) {
            return
        }

        components += component
        results += service.runCommandResult(
            arrayOf("settings", "put", "secure", key, components.joinToString(":"))
        )
    }

    private fun IEdgeLinkShizukuService.runCommandResult(command: Array<String>): ShizukuCommandResult =
        ShizukuCommandResult.decode(runCommand(command))

    private fun List<ShizukuCommandResult>.toOperationResult(
        name: String,
        allowPartial: Boolean = false
    ): ShizukuOperationResult {
        val successCount = count { it.success }
        val failed = filterNot { it.success }
        val success = if (allowPartial) successCount > 0 else failed.isEmpty()
        val message = if (failed.isEmpty()) {
            "$name ok"
        } else {
            "$name partial=$successCount/${size} failed=${failed.joinToString { it.stderr.ifBlank { "exit=${it.exitCode}" } }}"
        }
        return ShizukuOperationResult(success = success, message = message)
    }

    private data class MiLinkProbeCommand(
        val name: String,
        val command: Array<String>
    )

    private val miLinkProbeCommands = listOf(
        MiLinkProbeCommand(
            name = "circulate_common",
            command = arrayOf(
                "content",
                "call",
                "--uri",
                "content://com.milink.service.circulate",
                "--method",
                "check_permission",
                "--arg",
                "common"
            )
        ),
        MiLinkProbeCommand(
            name = "circulate_miplay_url",
            command = arrayOf(
                "content",
                "call",
                "--uri",
                "content://com.milink.service.circulate",
                "--method",
                "check_permission",
                "--arg",
                "miplay_url_circulate"
            )
        ),
        MiLinkProbeCommand(
            name = "runtime_ping",
            command = arrayOf(
                "content",
                "call",
                "--uri",
                "content://provider.milink.mi.com/messenger",
                "--method",
                "content://provider.milink.mi.com/messenger#ping"
            )
        ),
        MiLinkProbeCommand(
            name = "public_casting",
            command = arrayOf(
                "content",
                "call",
                "--uri",
                "content://com.milink.service.public",
                "--method",
                "milink_casting"
            )
        )
    )

    private fun String.forSingleLineLog(): String =
        replace(Regex("\\s+"), " ")
            .trim()
            .take(512)

    private fun String.maskBluetoothMac(): String =
        split(':').takeIf { it.size == 6 }?.let { "**:**:**:**:${it[4]}:${it[5]}" } ?: this

    private val mirrorBluetoothMacPatterns = listOf(
        "bt_property" to Regex("""BT_PROPERTY_TYPE_OF_DEVICE addr:([0-9A-Fa-f:]{17}) deviceType:3"""),
        "hyper_remote" to Regex("""Remote device name is:.* type = 2 ([0-9A-Fa-f:]{17})""")
    )

    private val ShizukuCommandResult.isProbeSuccess: Boolean
        get() = success && stderr.isBlank()

    private class BoundShizukuService(
        private val args: Shizuku.UserServiceArgs,
        private val connection: ServiceConnection,
        val service: IEdgeLinkShizukuService
    ) {
        fun close() {
            runCatching { Shizuku.unbindUserService(args, connection, true) }
        }
    }

    private fun Throwable.isTransientShizukuServiceError(): Boolean =
        this is ShizukuUserServiceDisconnectedException ||
            this is DeadObjectException ||
            this is RemoteException && message.orEmpty().contains("disconnected", ignoreCase = true)

    private class ShizukuUserServiceDisconnectedException :
        IllegalStateException("Shizuku UserService disconnected.")
}
