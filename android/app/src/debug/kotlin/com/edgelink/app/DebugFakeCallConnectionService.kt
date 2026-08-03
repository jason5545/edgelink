package com.edgelink.app

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

class DebugFakeCallConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val connection = object : Connection() {
            override fun onAnswer() {
                setActive()
            }

            override fun onReject() {
                setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
                destroy()
            }

            override fun onDisconnect() {
                setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
                destroy()
            }
        }
        connection.setAddress(request.address, TelecomManager.PRESENTATION_ALLOWED)
        connection.setCallerDisplayName("Debug Fake Call", TelecomManager.PRESENTATION_ALLOWED)
        connection.setRinging()
        return connection
    }

    companion object {
        private const val PHONE_ACCOUNT_ID = "edgelink_debug_fake_call"

        fun phoneAccountHandle(context: Context): PhoneAccountHandle =
            PhoneAccountHandle(
                ComponentName(context, DebugFakeCallConnectionService::class.java),
                PHONE_ACCOUNT_ID
            )

        fun ensurePhoneAccount(context: Context) {
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val handle = phoneAccountHandle(context)
            val existing = runCatching { telecom.getPhoneAccount(handle) }.getOrNull()
            if (existing?.isEnabled == true) {
                return
            }
            val account = PhoneAccount.builder(handle, "EdgeLink Debug Calls")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .build()
            telecom.registerPhoneAccount(account)
        }

        fun injectIncomingCall(context: Context, number: String) {
            ensurePhoneAccount(context)
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.parse("tel:$number"))
            }
            telecom.addNewIncomingCall(phoneAccountHandle(context), extras)
        }
    }
}
