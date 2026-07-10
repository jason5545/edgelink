package com.edgelink.app

import org.junit.Assert.assertEquals
import org.junit.Test

class ScreenShareProtectionPolicyTest {
    @Test
    fun privacyEnabledUsesProtectedValues() {
        assertEquals(
            ScreenShareProtectionTarget(
                globalDisableProtections = 0,
                xiaomiPrivateProjection = 1
            ),
            screenShareProtectionTarget(privacyEnabled = true)
        )
    }

    @Test
    fun privacyDisabledUsesVisibleNotificationValues() {
        assertEquals(
            ScreenShareProtectionTarget(
                globalDisableProtections = 1,
                xiaomiPrivateProjection = 0
            ),
            screenShareProtectionTarget(privacyEnabled = false)
        )
    }
}
