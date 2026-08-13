package com.edgelink.app

import android.telecom.Call
import android.telecom.PhoneAccount
import android.telecom.TelecomManager

/**
 * Decides whether a Telecom [Call] is a real SIM telephony call that should be
 * reported to the Mac (and relayed), or a third-party VoIP call that must be
 * ignored entirely.
 *
 * Android Telecom unifies calls the way CallKit does on iOS: any app that
 * registers a self-managed ConnectionService (LINE, WhatsApp, Messenger, ...)
 * surfaces its calls to every bound InCallService, including ours. Without a
 * filter, an incoming LINE call reaches [EdgeLinkInCallService] as a RINGING
 * call and pops the Mac incoming-call UI with answer/decline buttons that
 * cannot control the LINE call's audio.
 *
 * Classification is exact, not heuristic:
 * - SIM telephony calls carry CAPABILITY_SIM_SUBSCRIPTION, or
 * - their PhoneAccount belongs to the system telephony stack
 *   (com.android.phone / com.android.server.telecom), which covers OEM builds
 *   that fail to tag the capability.
 * Everything else (VoIP apps use their own package) is suppressed.
 */
object PhoneCallReportPolicy {
    private val telephonyPackages = setOf(
        "com.android.phone",
        "com.android.server.telecom"
    )

    fun shouldReport(accountPackage: String?, hasSimSubscription: Boolean): Boolean =
        hasSimSubscription || telephonyPackages.contains(accountPackage)

    fun shouldReport(details: Call.Details?, telecomManager: TelecomManager?): Boolean {
        val handle = details?.accountHandle ?: return false
        val accountPackage = handle.componentName?.packageName
        val hasSimSubscription = telecomManager
            ?.getPhoneAccount(handle)
            ?.hasCapabilities(PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION) == true
        return shouldReport(accountPackage, hasSimSubscription)
    }
}
