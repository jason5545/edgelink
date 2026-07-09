package com.edgelink.app

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import rikka.shizuku.Shizuku
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val SHIZUKU_REQUEST_CODE = 61_240
private const val SHIZUKU_USER_SERVICE_VERSION = 1

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
            val results = listOf(
                service.runCommandResult(arrayOf("cmd", "appops", "set", context.packageName, "PROJECT_MEDIA", "allow")),
                service.runCommandResult(arrayOf("cmd", "appops", "set", context.packageName, "WRITE_SETTINGS", "allow")),
                service.runCommandResult(arrayOf("cmd", "appops", "set", context.packageName, "SYSTEM_ALERT_WINDOW", "allow"))
            )
            results.toOperationResult("screen", allowPartial = true)
        }

    suspend fun putSecureInt(context: Context, key: String, value: Int): ShizukuOperationResult =
        withService(context) { service ->
            val result = service.runCommandResult(
                arrayOf("settings", "put", "secure", key, value.toString())
            )
            listOf(result).toOperationResult("secure_setting:$key")
        }

    private suspend fun <T> withService(
        context: Context,
        block: (IEdgeLinkShizukuService) -> T
    ): T = withContext(Dispatchers.IO) {
        ensureUsable()
        val boundService = bindService(context.applicationContext)
        try {
            block(boundService.service)
        } finally {
            boundService.close()
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
