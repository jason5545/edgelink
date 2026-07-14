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
                arrayOf("am", "start", "-a", "android.intent.action.CALL", "-d", "tel:+886912345678")
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
    fun rejectsUnexpectedPhoneCommands() {
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("am", "start", "-a", "android.intent.action.VIEW", "-d", "tel:+886912345678")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("am", "start", "-a", "android.intent.action.CALL", "-d", "https://example.com")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("am", "start", "-a", "android.intent.action.CALL", "-d", "tel:*#06#")
            )
        )
        assertFalse(
            EdgeLinkShizukuCommandPolicy.isAllowed(
                arrayOf("input", "keyevent", "KEYCODE_POWER")
            )
        )
    }
}
