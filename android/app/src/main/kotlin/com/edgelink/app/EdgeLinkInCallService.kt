package com.edgelink.app

import android.telecom.Call
import android.telecom.InCallService
import java.util.IdentityHashMap

private const val PHONE_DTMF_TONE_DURATION_MS = 180L
private const val PHONE_DTMF_TONE_GAP_MS = 120L
private const val PHONE_DTMF_SEQUENCE_PAUSE_MS = 650L

class EdgeLinkInCallService : InCallService() {
    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        EdgeLinkInCallCallStore.add(call)
    }

    override fun onCallRemoved(call: Call) {
        EdgeLinkInCallCallStore.remove(call, "removed")
        super.onCallRemoved(call)
    }

    override fun onDestroy() {
        EdgeLinkInCallCallStore.clear()
        super.onDestroy()
    }

    companion object {
        @Volatile
        private var callsIdleListener: ((String) -> Unit)? = null

        fun setCallsIdleListener(listener: ((String) -> Unit)?) {
            callsIdleListener = listener
        }

        internal fun notifyCallsIdle(reason: String) {
            callsIdleListener?.invoke(reason)
        }

        fun sendDtmfSequence(sequence: String): ShizukuOperationResult =
            EdgeLinkInCallCallStore.sendDtmfSequence(sequence)

        fun diagnosticState(): String =
            EdgeLinkInCallCallStore.diagnosticState()

        fun hasOngoingCall(): Boolean =
            EdgeLinkInCallCallStore.hasOngoingCall()
    }
}

private object EdgeLinkInCallCallStore {
    private val lock = Any()
    private val calls = IdentityHashMap<Call, Call.Callback>()

    fun add(call: Call) {
        val callback = object : Call.Callback() {
            override fun onStateChanged(call: Call, state: Int) {
                EdgeLinkLog.info("phone.android.incall_service state=$state calls=${callStatesSummary()}")
                if (state == Call.STATE_DISCONNECTED) {
                    remove(call, "disconnected")
                }
            }

            override fun onDetailsChanged(call: Call, details: Call.Details) {
                EdgeLinkLog.info("phone.android.incall_service details state=${call.state} calls=${callStatesSummary()}")
            }
        }
        synchronized(lock) {
            calls[call] = callback
        }
        call.registerCallback(callback)
        EdgeLinkLog.info("phone.android.incall_service call_added state=${call.state} calls=${callStatesSummary()}")
    }

    fun remove(call: Call, reason: String) {
        val (callback, emptyAfterRemove) = synchronized(lock) {
            calls.remove(call) to calls.isEmpty()
        }
        callback?.let { runCatching { call.unregisterCallback(it) } }
        EdgeLinkLog.info("phone.android.incall_service call_removed reason=$reason calls=${callStatesSummary()}")
        if (callback != null && emptyAfterRemove) {
            EdgeLinkInCallService.notifyCallsIdle(reason)
        }
    }

    fun clear() {
        val snapshot = synchronized(lock) {
            val entries = calls.entries.map { it.key to it.value }
            calls.clear()
            entries
        }
        snapshot.forEach { (call, callback) ->
            runCatching { call.unregisterCallback(callback) }
        }
        EdgeLinkLog.info("phone.android.incall_service cleared")
    }

    fun sendDtmfSequence(sequence: String): ShizukuOperationResult {
        val call = activeCall()
            ?: return ShizukuOperationResult(
                success = false,
                message = "phone:dtmf no_active_call ${diagnosticState()}"
            )
        var sent = 0
        return runCatching {
            for ((index, tone) in sequence.withIndex()) {
                if (tone == ',') {
                    Thread.sleep(PHONE_DTMF_SEQUENCE_PAUSE_MS)
                    continue
                }
                if (!PhoneDtmfKeyMapper.isTone(tone)) {
                    return@runCatching ShizukuOperationResult(
                        success = false,
                        message = "phone:dtmf invalid_tone"
                    )
                }
                call.playDtmfTone(tone)
                Thread.sleep(PHONE_DTMF_TONE_DURATION_MS)
                call.stopDtmfTone()
                sent += 1
                if (index < sequence.lastIndex) {
                    Thread.sleep(PHONE_DTMF_TONE_GAP_MS)
                }
            }
            if (sent == 0) {
                ShizukuOperationResult(success = false, message = "phone:dtmf empty")
            } else {
                ShizukuOperationResult(success = true, message = "phone:dtmf incall_service count=$sent")
            }
        }.getOrElse { error ->
            runCatching { call.stopDtmfTone() }
            ShizukuOperationResult(
                success = false,
                message = "phone:dtmf incall_service_failed=${error.javaClass.simpleName}:${error.message.orEmpty()}"
            )
        }
    }

    fun diagnosticState(): String = "states=${callStatesSummary()}"

    fun hasOngoingCall(): Boolean {
        val snapshot = synchronized(lock) { calls.keys.toList() }
        return snapshot.any { call ->
            when (call.state) {
                Call.STATE_ACTIVE,
                Call.STATE_DIALING,
                Call.STATE_CONNECTING,
                Call.STATE_RINGING,
                Call.STATE_HOLDING -> true
                else -> false
            }
        }
    }

    private fun activeCall(): Call? {
        val snapshot = synchronized(lock) { calls.keys.toList() }
        return snapshot.firstOrNull { it.state == Call.STATE_ACTIVE }
            ?: snapshot.firstOrNull { it.state == Call.STATE_DIALING || it.state == Call.STATE_CONNECTING }
    }

    private fun callStatesSummary(): String {
        val states = synchronized(lock) { calls.keys.map { it.state } }
        return if (states.isEmpty()) {
            "none"
        } else {
            states.joinToString(",")
        }
    }
}
