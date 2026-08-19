package com.edgelink.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EdgeLinkShizukuCommandPolicyTest {
    @Test
    fun allowsOnlyExactNotificationListenerApproval() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "cmd",
                    "notification",
                    "allow_listener",
                    "com.edgelink.app/com.edgelink.app.AndroidNotificationListenerService",
                    "0"
                )
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "cmd",
                    "notification",
                    "allow_listener",
                    "com.other.app/.NotificationListener",
                    "0"
                )
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "cmd",
                    "notification",
                    "disallow_listener",
                    "com.edgelink.app/com.edgelink.app.AndroidNotificationListenerService",
                    "0"
                )
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "cmd",
                    "notification",
                    "allow_listener",
                    "com.edgelink.app/com.edgelink.app.AndroidNotificationListenerService",
                    "-1"
                )
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "settings",
                    "put",
                    "secure",
                    "enabled_notification_listeners",
                    "com.edgelink.app/com.edgelink.app.AndroidNotificationListenerService"
                )
            )
        )
    }

    @Test
    fun allowsExactScreenShareProtectionCommands() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("settings", "put", "global", GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS, "1")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("settings", "put", "secure", XIAOMI_SCREEN_PROJECT_PRIVATE_ON, "0")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("settings", "get", "global", GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS)
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("settings", "delete", "secure", XIAOMI_SCREEN_PROJECT_PRIVATE_ON)
            )
        )
    }

    @Test
    fun rejectsWrongNamespaceKeyAndValues() {
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("settings", "put", "secure", GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS, "1")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("settings", "put", "global", "unrelated_key", "1")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("settings", "put", "secure", XIAOMI_SCREEN_PROJECT_PRIVATE_ON, "2")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("settings", "delete", "secure", "screensaver_enabled")
            )
        )
    }

    @Test
    fun allowsExactMiLinkProbeCommands() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "content",
                    "call",
                    "--uri",
                    "content://com.milink.service.circulate",
                    "--method",
                    "check_permission",
                    "--arg",
                    "common"
                )
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "content",
                    "call",
                    "--uri",
                    "content://provider.milink.mi.com/messenger",
                    "--method",
                    "content://provider.milink.mi.com/messenger#ping"
                )
            )
        )
    }

    @Test
    fun rejectsUnexpectedMiLinkProbeShape() {
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "content",
                    "call",
                    "--uri",
                    "content://com.milink.service.circulate",
                    "--method",
                    "check_permission",
                    "--arg",
                    "private_session"
                )
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "content",
                    "call",
                    "--uri",
                    "content://com.xiaomi.continuity.universal.clipboard",
                    "--method",
                    "query"
                )
            )
        )
    }

    @Test
    fun allowsOnlyExactMiShareSettingsStartCommand() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "am",
                    "start",
                    "-a",
                    "com.miui.mishare.action.MiShareSettings",
                    "-p",
                    "com.miui.mishare.connectivity"
                )
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "am",
                    "start",
                    "-a",
                    "android.intent.action.VIEW",
                    "-p",
                    "com.miui.mishare.connectivity"
                )
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "am",
                    "start",
                    "-a",
                    "com.miui.mishare.action.MiShareSettings",
                    "-p",
                    "com.android.settings"
                )
            )
        )
    }

    @Test
    fun allowsOnlyMirrorBluetoothLogcatProbe() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
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
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("logcat", "-d")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "logcat",
                    "-d",
                    "-t",
                    "5000",
                    "-v",
                    "time",
                    "BluetoothRemoteDevices:D",
                    "HyperRemoteDevicesAdapter:D",
                    "ScanController:V",
                    "*:S"
                )
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "logcat",
                    "-d",
                    "-t",
                    "3000",
                    "-v",
                    "time",
                    "AndroidRuntime:E",
                    "*:S"
                )
            )
        )
    }

    @Test
    fun allowsExactPhoneCommands() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("pm", "grant", "com.edgelink.app", "android.permission.CALL_PHONE")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "appops", "set", "com.edgelink.app", "MANAGE_ONGOING_CALLS", "allow")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("input", "keyevent", "KEYCODE_HEADSETHOOK")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("input", "keyevent", "KEYCODE_ENDCALL")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("input", "keyevent", "KEYCODE_1")
            )
        )
    }

    @Test
    fun allowsOnlyScopedTelecomCompanionCommands() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "telecom", "add-or-remove-call-companion-app", "com.edgelink.app", "1")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "telecom", "wait-on-handlers")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "telecom", "is-non-ui-in-call-service-bound", "com.edgelink.app")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "telecom", "add-or-remove-call-companion-app", "com.other.app", "1")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "telecom", "add-or-remove-call-companion-app", "com.edgelink.app", "0")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "telecom", "set-default-dialer", "com.edgelink.app")
            )
        )
    }

    @Test
    fun rejectsUnexpectedPhoneCommands() {
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("am", "start", "-a", "android.intent.action.CALL", "-d", "tel:+886912345678")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("am", "start", "-a", "android.intent.action.VIEW", "-d", "tel:+886912345678")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("pm", "grant", "com.edgelink.app", "android.permission.READ_CALL_LOG")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("input", "keyevent", "KEYCODE_POWER")
            )
        )
    }

    @Test
    fun allowsExactAppOpsCommands() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "appops", "set", "com.edgelink.app", "READ_CLIPBOARD", "allow")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "appops", "set", "--uid", "10295", "READ_CLIPBOARD", "allow")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "appops", "set", "com.edgelink.app", "READ_CLIPBOARD", "deny")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "appops", "set", "--uid", "10295", "READ_CLIPBOARD", "foreground")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "appops", "set", "--uid", "root", "READ_CLIPBOARD", "allow")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "appops", "set", "--uid", "10295", "RUN_ANY_IN_BACKGROUND", "allow")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("cmd", "appops", "set", "--uid", "10295", "--user", "0", "READ_CLIPBOARD", "allow")
            )
        )
    }

    @Test
    fun allowsExactDistAudioMaintenanceCommands() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                EdgeLinkShizukuCommands.RELAY_ROUTE_REGISTER_COMMAND
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("sh", "-c", "rm -rf /data/local/tmp")
            )
        )
        val tampered = EdgeLinkShizukuCommands.RELAY_ROUTE_REGISTER_COMMAND.copyOf()
        tampered[2] = tampered[2] + "; reboot"
        assertFalse(EdgeLinkShizukuCommandPolicy.isAllowed(tampered))
    }
}
