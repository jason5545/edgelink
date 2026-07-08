package com.edgelink.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo

class DebugSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_INJECT_SMS) {
            return
        }

        val appContext = context.applicationContext
        EdgeLinkLog.configure(appContext)
        if (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            EdgeLinkLog.warn("sms.android.debug_rejected_non_debug")
            return
        }

        val address = intent.getStringExtra(EXTRA_ADDRESS)?.trim().orEmpty().ifBlank { DEFAULT_ADDRESS }
        val text = intent.getStringExtra(EXTRA_TEXT)?.trim().orEmpty()
        if (text.isBlank()) {
            EdgeLinkLog.warn("sms.android.debug_blank addressFp=${AndroidSmsSync.fingerprint(address)}")
            return
        }
        val timestampMs = intent.getLongExtra(EXTRA_TIMESTAMP_MS, System.currentTimeMillis())
            .takeIf { it > 0L }
            ?: System.currentTimeMillis()

        EdgeLinkLog.info(
            "sms.android.debug_inject_requested addressFp=${AndroidSmsSync.fingerprint(address)} " +
                "textFp=${AndroidSmsSync.fingerprint(text)}"
        )
        AndroidSmsPendingStore.enqueue(
            context = appContext,
            address = address,
            text = text,
            timestampMs = timestampMs
        )
        EdgeLinkRuntimeHolder.existing()?.onSmsPendingAvailable(reason = "debug")
    }

    companion object {
        const val ACTION_INJECT_SMS = "com.edgelink.app.DEBUG_INJECT_SMS"
        const val EXTRA_ADDRESS = "address"
        const val EXTRA_TEXT = "text"
        const val EXTRA_TIMESTAMP_MS = "timestampMs"
        private const val DEFAULT_ADDRESS = "123720"
    }
}
