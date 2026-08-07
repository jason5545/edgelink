package com.edgelink.app

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.math.min

private const val COMMAND_TIMEOUT_SECONDS = 10L
private const val COMMAND_OUTPUT_LIMIT = 16 * 1024
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

    // In-service keepalive for com.miui.audiomonitor during distaudio calls.
    // The earlier sh -c poll hid its own failures (forced exit 0) and MIUI
    // may re-freeze between polls, so the loop now lives here in the root
    // service: direct file reads/writes with real state logging.
    private val keepalive = AudioMonitorKeepaliveLoop()

    // No-hook call-uplink inject: this root process owns the 19307 endpoint
    // and writes the Mac mic PCM into a telephony-routed AudioTrack directly,
    // bypassing the LSPosed feed inside audiomonitor. Falls back to the hook
    // (mode property + audiomonitor restart) if the route is refused.
    private val callUplinkInjector = CallUplinkInjector()

    override fun startAudioMonitorKeepalive() {
        keepalive.start()
    }

    override fun stopAudioMonitorKeepalive() {
        keepalive.stop()
    }

    override fun startCallUplinkInjector() {
        callUplinkInjector.start()
    }

    override fun stopCallUplinkInjector() {
        callUplinkInjector.stop()
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

// Runs inside the root Shizuku service process for the duration of a
// distaudio call: every 2s it checks com.miui.audiomonitor's cgroup state
// and clears the v2 freezer / lifts the process out of the background
// cpuset+cpuctl groups so the in-process call-inject thread keeps running.
// Every state change and a periodic heartbeat are logged — the previous
// sh -c variant forced exit 0 and masked whether anything actually happened.
internal class AudioMonitorKeepaliveLoop {
    private companion object {
        const val TAG = "EdgeLinkShizuku"
        const val TARGET_PACKAGE = "com.miui.audiomonitor"
        const val POLL_INTERVAL_MS = 2_000L
    }

    private val running = AtomicBoolean(false)

    @Volatile
    private var worker: Thread? = null

    fun start() {
        if (!running.compareAndSet(false, true)) {
            return
        }
        worker = thread(name = "edgelink-am-keepalive", isDaemon = true) { loop() }
    }

    fun stop() {
        running.set(false)
        worker?.interrupt()
        worker = null
    }

    private fun loop() {
        android.util.Log.i(TAG, "audiomonitor keepalive started")
        var iteration = 0
        while (running.get()) {
            iteration += 1
            runCatching { tick(iteration) }
                .onFailure { android.util.Log.w(TAG, "audiomonitor keepalive tick failed: ${it.message}") }
            try {
                Thread.sleep(POLL_INTERVAL_MS)
            } catch (_: InterruptedException) {
                break
            }
        }
        android.util.Log.i(TAG, "audiomonitor keepalive stopped")
    }

    private fun tick(iteration: Int) {
        val pid = findPid(TARGET_PACKAGE)
        if (pid == null) {
            if (iteration == 1 || iteration % 15 == 0) {
                android.util.Log.i(TAG, "audiomonitor keepalive iter=$iteration target not running")
            }
            return
        }
        val cgroupLines = runCatching { File("/proc/$pid/cgroup").readText() }.getOrDefault("")
            .lines()
        val v2Path = cgroupLines.firstOrNull { it.startsWith("0::") }?.removePrefix("0::")
        var unfrozen = false
        if (v2Path != null) {
            val freezeFile = File("/sys/fs/cgroup$v2Path/cgroup.freeze")
            if (freezeFile.exists() && freezeFile.readText().trim() == "1") {
                freezeFile.writeText("0")
                unfrozen = true
            }
        }
        val cpusetPath = cgroupLines
            .firstOrNull { it.split(':').getOrNull(1)?.contains("cpuset") == true }
            ?.split(':')?.getOrNull(2)
            .orEmpty()
        var lifted = false
        if (cpusetPath.startsWith("/background")) {
            lifted = listOf("/dev/cpuset/foreground/tasks", "/dev/cpuctl/foreground/tasks")
                .map { File(it) }
                .all { file -> runCatching { file.appendText("$pid\n") }.isSuccess }
        }
        if (unfrozen || lifted || iteration == 1 || iteration % 15 == 0) {
            android.util.Log.i(
                TAG,
                "audiomonitor keepalive iter=$iteration pid=$pid unfrozen=$unfrozen lifted=$lifted cpuset=$cpusetPath"
            )
        }
    }

    private fun findPid(packageName: String): Int? {
        val proc = File("/proc")
        for (entry in proc.listFiles().orEmpty()) {
            val pid = entry.name.toIntOrNull() ?: continue
            val cmdline = runCatching { File(entry, "cmdline").readText() }.getOrNull() ?: continue
            if (cmdline.trim('\u0000') == packageName) {
                return pid
            }
        }
        return null
    }
}
