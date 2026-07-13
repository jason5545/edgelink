package com.edgelink.app

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.math.min

private const val COMMAND_TIMEOUT_SECONDS = 10L
private const val COMMAND_OUTPUT_LIMIT = 16 * 1024
private const val EDGE_LINK_PACKAGE_NAME = "com.edgelink.app"

class EdgeLinkShizukuService : IEdgeLinkShizukuService.Stub() {
    override fun destroy() {
        System.exit(0)
    }

    override fun runCommand(command: Array<String>): String {
        if (!EdgeLinkShizukuCommandPolicy.isAllowed(command)) {
            return ShizukuCommandResult(
                exitCode = 126,
                stdout = "",
                stderr = "Command is not allowed: ${command.joinToString(" ")}"
            ).encode()
        }

        return runCatching {
            val process = ProcessBuilder(command.toList()).start()
            val stdout = AtomicReference("")
            val stderr = AtomicReference("")
            val stdoutThread = thread(name = "edgelink-shizuku-stdout") {
                stdout.set(readLimited(process.inputStream))
            }
            val stderrThread = thread(name = "edgelink-shizuku-stderr") {
                stderr.set(readLimited(process.errorStream))
            }
            val finished = process.waitFor(COMMAND_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            if (!finished) {
                process.destroyForcibly()
            }
            stdoutThread.join(1_000)
            stderrThread.join(1_000)
            ShizukuCommandResult(
                exitCode = if (finished) process.exitValue() else 124,
                stdout = stdout.get(),
                stderr = stderr.get()
            ).encode()
        }.getOrElse { error ->
            ShizukuCommandResult(
                exitCode = 1,
                stdout = "",
                stderr = error.message.orEmpty()
            ).encode()
        }
    }

    private fun readLimited(input: InputStream): String {
        input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            var total = 0
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) {
                    break
                }
                if (total < COMMAND_OUTPUT_LIMIT) {
                    val toWrite = min(read, COMMAND_OUTPUT_LIMIT - total)
                    output.write(buffer, 0, toWrite)
                    total += toWrite
                }
            }
            return output.toString(Charsets.UTF_8.name())
        }
    }
}

internal object EdgeLinkShizukuCommandPolicy {
    fun isAllowed(command: Array<String>): Boolean {
        if (command.isEmpty()) {
            return false
        }
        if (isAllowedSettingsCommand(command)) {
            return true
        }
        if (isAllowedAppOpsCommand(command)) {
            return true
        }
        if (isAllowedMiLinkProbeCommand(command)) {
            return true
        }
        return isAllowedPermissionGrantCommand(command)
    }

    private fun isAllowedSettingsCommand(command: Array<String>): Boolean {
        if (command.size !in 4..5) {
            return false
        }
        if (command[0] != "settings") {
            return false
        }
        val action = command[1]
        val namespace = command[2]
        val key = command[3]
        if (key !in allowedSettingsKeys[namespace].orEmpty()) {
            return false
        }
        return when (action) {
            "get" -> command.size == 4
            "delete" -> command.size == 4 && isScreenShareProtectionKey(namespace, key)
            "put" -> command.size == 5 &&
                (!isScreenShareProtectionKey(namespace, key) || command[4] == "0" || command[4] == "1")
            else -> false
        }
    }

    private fun isAllowedAppOpsCommand(command: Array<String>): Boolean {
        if (command.size != 6) {
            return false
        }
        return command[0] == "cmd" &&
            command[1] == "appops" &&
            command[2] == "set" &&
            command[3] == EDGE_LINK_PACKAGE_NAME &&
            command[4] in allowedAppOps &&
            command[5] == "allow"
    }

    private fun isAllowedPermissionGrantCommand(command: Array<String>): Boolean {
        if (command.size != 4) {
            return false
        }
        return command[0] == "pm" &&
            command[1] == "grant" &&
            command[2] == EDGE_LINK_PACKAGE_NAME &&
            command[3] in allowedRuntimePermissions
    }

    private fun isAllowedMiLinkProbeCommand(command: Array<String>): Boolean {
        if (command.size != 6 && command.size != 8) {
            return false
        }
        if (command[0] != "content" ||
            command[1] != "call" ||
            command[2] != "--uri" ||
            command[4] != "--method"
        ) {
            return false
        }
        if (command.size == 8 && command[6] != "--arg") {
            return false
        }

        val uri = command[3]
        val method = command[5]
        val arg = command.getOrNull(7)
        return arg in allowedMiLinkContentCalls[uri to method].orEmpty()
    }

    private fun isScreenShareProtectionKey(namespace: String, key: String): Boolean =
        namespace == "global" && key == GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS ||
            namespace == "secure" && key == XIAOMI_SCREEN_PROJECT_PRIVATE_ON

    private val allowedSettingsKeys = mapOf(
        "secure" to setOf(
            "accessibility_enabled",
            "enabled_accessibility_services",
            "enabled_notification_listeners",
            "screensaver_enabled",
            XIAOMI_SCREEN_PROJECT_PRIVATE_ON
        ),
        "global" to setOf(GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS)
    )
    private val allowedAppOps = setOf(
            "PROJECT_MEDIA",
            "SYSTEM_ALERT_WINDOW",
            "WRITE_SETTINGS"
    )
    private val allowedRuntimePermissions = setOf(
            "android.permission.POST_NOTIFICATIONS",
            "android.permission.RECORD_AUDIO",
            "android.permission.READ_SMS",
            "android.permission.RECEIVE_SMS",
            "android.permission.SEND_SMS"
    )
    private val allowedMiLinkContentCalls = mapOf(
        ("content://com.milink.service.circulate" to "check_permission") to setOf(
            "common",
            "miplay_url_circulate"
        ),
        (
            "content://provider.milink.mi.com/messenger" to
                "content://provider.milink.mi.com/messenger#ping"
        ) to setOf(null),
        ("content://com.milink.service.public" to "milink_casting") to setOf(null)
    )
}
