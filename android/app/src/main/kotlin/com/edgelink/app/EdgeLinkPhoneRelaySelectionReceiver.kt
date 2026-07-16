package com.edgelink.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class EdgeLinkPhoneRelaySelectionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != MiLinkPrivilegeHookPolicy.PHONE_RELAY_SELECTED_ACTION) {
            return
        }
        val appContext = context.applicationContext
        EdgeLinkLog.configure(appContext)
        runCatching {
            EdgeLinkForegroundService.ensureStarted(appContext)
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.relay_selection_service_start_failed", error)
        }
        val reason = intent
            .getStringExtra(MiLinkPrivilegeHookPolicy.PHONE_RELAY_SELECTED_REASON_EXTRA)
            ?.takeIf { it.isNotBlank() }
            ?: "incallui"
        EdgeLinkRuntimeHolder.getOrCreate(appContext).onPhoneRelaySelectedFromInCallUi(reason)
    }
}
