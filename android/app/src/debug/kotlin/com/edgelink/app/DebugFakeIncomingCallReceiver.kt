package com.edgelink.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class DebugFakeIncomingCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_FAKE_INCOMING_CALL) {
            return
        }
        val number = intent.getStringExtra(EXTRA_NUMBER) ?: "+886900000000"
        runCatching {
            DebugFakeCallConnectionService.injectIncomingCall(context.applicationContext, number)
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.debug_fake_incoming_failed", error)
        }
    }

    companion object {
        const val ACTION_FAKE_INCOMING_CALL = "com.edgelink.app.DEBUG_FAKE_INCOMING_CALL"
        const val EXTRA_NUMBER = "number"
    }
}
