package com.edgelink.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import java.util.concurrent.Executors

class AndroidSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
            return
        }

        EdgeLinkLog.configure(context.applicationContext)
        SmsReceiverWorker.enqueue(context.applicationContext, Intent(intent))
    }
}

private object SmsReceiverWorker {
    private val executor = Executors.newSingleThreadExecutor()

    fun enqueue(context: Context, intent: Intent) {
        executor.execute {
            handle(context.applicationContext, intent)
        }
    }

    private fun handle(context: Context, intent: Intent) {
        EdgeLinkLog.configure(context.applicationContext)
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent).orEmpty()
        if (messages.isEmpty()) {
            EdgeLinkLog.warn("sms.android.receiver_empty")
            return
        }

        val address = messages.firstOrNull()?.originatingAddress.orEmpty()
        val timestampMs = messages.minOf { it.timestampMillis }
        val text = messages.joinToString(separator = "") { it.messageBody.orEmpty() }.trim()
        if (text.isBlank()) {
            EdgeLinkLog.warn("sms.android.receiver_blank addressFp=${AndroidSmsSync.fingerprint(address)}")
            return
        }

        AndroidSmsPendingStore.enqueue(
            context = context.applicationContext,
            address = address,
            text = text,
            timestampMs = timestampMs
        )
        EdgeLinkRuntimeHolder.existing()?.onSmsPendingAvailable(reason = "receiver")
    }
}
