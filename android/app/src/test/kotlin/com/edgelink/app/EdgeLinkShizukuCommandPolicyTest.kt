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
}
