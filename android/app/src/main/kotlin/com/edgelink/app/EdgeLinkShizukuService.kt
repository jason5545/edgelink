package com.edgelink.app

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.math.min

private const val COMMAND_TIMEOUT_SECONDS = 10L
private const val COMMAND_OUTPUT_LIMIT = 16 * 1024
private const val MI_CONNECT_PERMISSION_SWITCH_PROPERTY = "lyra.permission.switch"
private const val EDGE_LINK_PACKAGE_NAME = "com.edgelink.app"
private const val EDGE_LINK_NOTIFICATION_LISTENER_COMPONENT =
    "com.edgelink.app/com.edgelink.app.AndroidNotificationListenerService"
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

class EdgeLinkShizukuService : IEdgeLinkShizukuService.Stub() {
    override fun destroy() {
        System.exit(0)
    }

    // Permission gate for the mi_connect networking probe. mi_connect's
    // PermissionChecker refuses every binder caller except uid 1000, but it
    // consults a Xiaomi-shipped debug gate first: system property
    // lyra.permission.switch=1 makes checkPermissions return 0 for everyone
    // (PermissionSwitch.getPermissionAbility). The probe bind itself runs in
    // the app process (AMS rejects binds from this root process), so this
    // method only toggles the global property — on for the probe window,
    // restored to its previous value when the app turns it off. Root is
    // required because only root can write the property.
    private val miConnectSwitchBusy = AtomicBoolean(false)

    @Volatile
    private var miConnectSwitchPrevious = ""

    override fun setMiConnectPermissionSwitch(enabled: Boolean) {
        if (enabled) {
            if (!miConnectSwitchBusy.compareAndSet(false, true)) {
                android.util.Log.w(
                    "EdgeLinkShizuku",
                    "mi_connect permission switch already held, forcing re-arm"
                )
            }
            miConnectSwitchPrevious = readSystemProperty(MI_CONNECT_PERMISSION_SWITCH_PROPERTY)
            setSystemProperty(MI_CONNECT_PERMISSION_SWITCH_PROPERTY, "1")
        } else {
            setSystemProperty(MI_CONNECT_PERMISSION_SWITCH_PROPERTY, miConnectSwitchPrevious)
            miConnectSwitchBusy.set(false)
        }
    }

    private fun readSystemProperty(name: String): String = runCatching {
        Class.forName("android.os.SystemProperties")
            .getMethod("get", String::class.java)
            .invoke(null, name) as? String
    }.getOrNull().orEmpty()

    private fun setSystemProperty(name: String, value: String) {
        val ok = runCatching {
            Class.forName("android.os.SystemProperties")
                .getMethod("set", String::class.java, String::class.java)
                .invoke(null, name, value)
            true
        }.getOrElse { error ->
            android.util.Log.w(
                "EdgeLinkShizuku",
                "mi_connect probe setprop $name failed: ${error.javaClass.simpleName}: ${error.message}"
            )
            false
        }
        android.util.Log.i(
            "EdgeLinkShizuku",
            "mi_connect probe setprop $name=$value ok=$ok"
        )
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
        if (isAllowedNotificationCommand(command)) {
            return true
        }
        if (isAllowedMiLinkProbeCommand(command)) {
            return true
        }
        if (isAllowedMiShareStartCommand(command)) {
            return true
        }
        if (isAllowedMirrorBluetoothLogcatCommand(command)) {
            return true
        }
        if (isAllowedPhoneCommand(command)) {
            return true
        }
        if (isAllowedProcNetUdpReadCommand(command)) {
            return true
        }
        if (command.contentEquals(EdgeLinkShizukuCommands.RELAY_ROUTE_REGISTER_COMMAND)) {
            return true
        }
        return isAllowedPermissionGrantCommand(command)
    }

    private fun isAllowedProcNetUdpReadCommand(command: Array<String>): Boolean =
        command.size == 3 &&
            command[0] == "sh" &&
            command[1] == "-c" &&
            command[2] == "cat /proc/net/udp /proc/net/udp6"

    private fun isAllowedNotificationCommand(command: Array<String>): Boolean {
        if (command.size != 5) {
            return false
        }
        val userId = command[4].toIntOrNull() ?: return false
        return command[0] == "cmd" &&
            command[1] == "notification" &&
            command[2] == "allow_listener" &&
            command[3] == EDGE_LINK_NOTIFICATION_LISTENER_COMPONENT &&
            userId in 0..99_999
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

    private fun isAllowedMiShareStartCommand(command: Array<String>): Boolean =
        command.size == 6 &&
            command[0] == "am" &&
            command[1] == "start" &&
            command[2] == "-a" &&
            command[3] == "com.miui.mishare.action.MiShareSettings" &&
            command[4] == "-p" &&
            command[5] == "com.miui.mishare.connectivity"

    private fun isAllowedMirrorBluetoothLogcatCommand(command: Array<String>): Boolean =
        command.contentEquals(MIRROR_BT_LOGCAT_COMMAND)

    private fun isAllowedPhoneCommand(command: Array<String>): Boolean =
        isAllowedPhoneKeyCommand(command) || isAllowedPhoneTelecomCommand(command)

    private fun isAllowedPhoneKeyCommand(command: Array<String>): Boolean =
        command.size == 3 &&
            command[0] == "input" &&
            command[1] == "keyevent" &&
            command[2] in allowedPhoneKeyEvents

    private fun isAllowedPhoneTelecomCommand(command: Array<String>): Boolean {
        if (command.size < 3 || command[0] != "cmd" || command[1] != "telecom") {
            return false
        }
        return when (command[2]) {
            "add-or-remove-call-companion-app" ->
                command.size == 5 && command[3] == EDGE_LINK_PACKAGE_NAME && command[4] == "1"
            "wait-on-handlers" ->
                command.size == 3
            "is-non-ui-in-call-service-bound" ->
                command.size == 4 && command[3] == EDGE_LINK_PACKAGE_NAME
            else -> false
        }
    }

    private fun isScreenShareProtectionKey(namespace: String, key: String): Boolean =
        namespace == "global" && key == GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS ||
            namespace == "secure" && key == XIAOMI_SCREEN_PROJECT_PRIVATE_ON

    private val allowedSettingsKeys = mapOf(
        "secure" to setOf(
            "accessibility_enabled",
            "enabled_accessibility_services",
            "screensaver_enabled",
            XIAOMI_SCREEN_PROJECT_PRIVATE_ON
        ),
        "global" to setOf(GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS)
    )
    private val allowedAppOps = setOf(
            "PROJECT_MEDIA",
            "SYSTEM_ALERT_WINDOW",
            "WRITE_SETTINGS",
            "MANAGE_ONGOING_CALLS"
    )
    private val allowedRuntimePermissions = setOf(
            "android.permission.POST_NOTIFICATIONS",
            "android.permission.RECORD_AUDIO",
            "android.permission.CALL_PHONE",
            "android.permission.READ_SMS",
            "android.permission.RECEIVE_SMS",
            "android.permission.SEND_SMS"
    )
    private val allowedPhoneKeyEvents = setOf(
        "KEYCODE_HEADSETHOOK",
        "KEYCODE_ENDCALL"
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
