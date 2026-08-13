package com.edgelink.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Recreates the LINE-call bug: LINE registers a self-managed ConnectionService,
 * so its VoIP calls reach EdgeLinkInCallService with accountPackage
 * "jp.naver.line.android" and no SIM subscription capability. These calls must
 * never be reported to the Mac (they previously popped the Mac incoming-call
 * UI). Real SIM calls must keep flowing.
 */
class PhoneCallReportPolicyTest {
    @Test
    fun suppressesLineVoipCall() {
        assertFalse(
            PhoneCallReportPolicy.shouldReport(
                accountPackage = "jp.naver.line.android",
                hasSimSubscription = false
            )
        )
    }

    @Test
    fun suppressesOtherThirdPartyVoipCalls() {
        for (pkg in listOf("com.whatsapp", "com.facebook.orca", "org.telegram.messenger")) {
            assertFalse(
                "expected $pkg to be suppressed",
                PhoneCallReportPolicy.shouldReport(accountPackage = pkg, hasSimSubscription = false)
            )
        }
    }

    @Test
    fun suppressesCallWithMissingAccount() {
        assertFalse(PhoneCallReportPolicy.shouldReport(accountPackage = null, hasSimSubscription = false))
    }

    @Test
    fun reportsSystemTelephonyCall() {
        assertTrue(
            PhoneCallReportPolicy.shouldReport(
                accountPackage = "com.android.phone",
                hasSimSubscription = true
            )
        )
    }

    @Test
    fun reportsTelephonyPackageEvenWithoutSimCapabilityFlag() {
        // OEM fallback: some builds fail to tag CAPABILITY_SIM_SUBSCRIPTION.
        assertTrue(
            PhoneCallReportPolicy.shouldReport(
                accountPackage = "com.android.phone",
                hasSimSubscription = false
            )
        )
        assertTrue(
            PhoneCallReportPolicy.shouldReport(
                accountPackage = "com.android.server.telecom",
                hasSimSubscription = false
            )
        )
    }

    @Test
    fun reportsSimBackedCallFromNonStandardPackage() {
        // SIM capability is authoritative even if the account package is an
        // unfamiliar OEM telephony stack.
        assertTrue(
            PhoneCallReportPolicy.shouldReport(
                accountPackage = "com.miui.voip",
                hasSimSubscription = true
            )
        )
    }
}
