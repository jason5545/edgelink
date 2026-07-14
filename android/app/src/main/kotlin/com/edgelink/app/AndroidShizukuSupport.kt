package com.edgelink.app

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.telecom.TelecomManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import rikka.shizuku.Shizuku
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val SHIZUKU_REQUEST_CODE = 61_240
private const val SHIZUKU_USER_SERVICE_VERSION = 4

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
            appendSecureComponent(
                service = service,
                key = "enabled_notification_listeners",
                component = component,
                results = results
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

    suspend fun placePhoneCall(context: Context, telUri: String): ShizukuOperationResult =
        withContext(Dispatchers.IO) {
            val appContext = context.applicationContext
            val permissionResult = ensurePhoneCallPermission(appContext)
            if (!permissionResult.success) {
                return@withContext permissionResult
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

    private suspend fun <T> withService(
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
                        continuation.resumeWithException(IllegalStateException("Shizuku UserService disconnected."))
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
}
