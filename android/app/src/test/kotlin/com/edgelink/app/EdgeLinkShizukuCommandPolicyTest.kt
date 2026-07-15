package com.edgelink.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EdgeLinkShizukuCommandPolicyTest {
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
    fun allowsExactPhoneCommands() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("pm", "grant", "com.edgelink.app", "android.permission.CALL_PHONE")
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
    }

    @Test
    fun allowsOnlyBoundedPhoneRelayPropertyWrites() {
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "setprop",
                    MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY,
                    "1790000000000"
                )
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "setprop",
                    MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY,
                    "0"
                )
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PROPERTY, "pad")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_ATTACH_PROPERTY, "1")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_KEY_PROPERTY, "1")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_USING_PAD_PROPERTY, "1")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_STATE_PROPERTY, "offhook")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_STATE_PROPERTY, "idle")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_PARAMS_PROPERTY, "1")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_START_PROPERTY, "both")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_SINK_ARG_PROPERTY, "7102")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PLAIN_RTP_PROPERTY, "1")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PEER_IP_PROPERTY, "10.0.0.42")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_LOCAL_IP_PROPERTY, "fd00::1234")
            )
        )
        assertTrue(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PEER_PORT_PROPERTY, "7102")
            )
        )

        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", "debug.edgelink.mirror_fake_remote_using_pad", "true")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PROPERTY, "car")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_PEER_IP_PROPERTY, "10.0.0.42;id")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("setprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_AUDIO_START_PROPERTY, "allow")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf(
                    "setprop",
                    MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY,
                    "1790000000000;id"
                )
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("getprop", MiLinkPrivilegeHookPolicy.MIRROR_FAKE_REMOTE_CALL_RELAY_UNTIL_PROPERTY)
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
}
