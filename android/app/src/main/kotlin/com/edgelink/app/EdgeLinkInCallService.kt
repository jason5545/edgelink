package com.edgelink.app

import android.os.Build
import android.telecom.Call
import android.telecom.InCallService
import com.edgelink.core.PhoneCallStatusBody
import java.time.Instant
import java.util.IdentityHashMap

private const val PHONE_DTMF_TONE_DURATION_MS = 180L
private const val PHONE_DTMF_TONE_GAP_MS = 120L
private const val PHONE_DTMF_SEQUENCE_PAUSE_MS = 650L

class EdgeLinkInCallService : InCallService() {
    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        EdgeLinkLog.configure(applicationContext)
        runCatching {
            EdgeLinkForegroundService.ensureStarted(applicationContext)
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.incall_service_start_foreground_failed", error)
        }
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
        @Volatile
        private var callStatusListener: ((PhoneCallStatusBody) -> Unit)? = null

        fun setCallsIdleListener(listener: ((String) -> Unit)?) {
            callsIdleListener = listener
        }

        fun setCallStatusListener(listener: ((PhoneCallStatusBody) -> Unit)?) {
            callStatusListener = listener
        }

        internal fun notifyCallsIdle(reason: String) {
            callsIdleListener?.invoke(reason)
        }

        internal fun notifyCallStatus(status: PhoneCallStatusBody) {
            callStatusListener?.invoke(status)
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
                EdgeLinkInCallService.notifyCallStatus(callStatusBody(call, "state_changed"))
                if (state == Call.STATE_DISCONNECTED) {
                    remove(call, "disconnected")
                }
            }

            override fun onDetailsChanged(call: Call, details: Call.Details) {
                EdgeLinkLog.info("phone.android.incall_service details state=${call.state} calls=${callStatesSummary()}")
                EdgeLinkInCallService.notifyCallStatus(callStatusBody(call, "details_changed"))
            }
        }
        synchronized(lock) {
            calls[call] = callback
        }
        call.registerCallback(callback)
        EdgeLinkLog.info("phone.android.incall_service call_added state=${call.state} calls=${callStatesSummary()}")
        EdgeLinkInCallService.notifyCallStatus(callStatusBody(call, "added"))
    }

    fun remove(call: Call, reason: String) {
        val (callback, emptyAfterRemove) = synchronized(lock) {
            calls.remove(call) to calls.isEmpty()
        }
        callback?.let { runCatching { call.unregisterCallback(it) } }
        EdgeLinkLog.info("phone.android.incall_service call_removed reason=$reason calls=${callStatesSummary()}")
        EdgeLinkInCallService.notifyCallStatus(callStatusBody(call, reason, removed = true))
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
        EdgeLinkInCallService.notifyCallStatus(
            PhoneCallStatusBody(
                callId = "all",
                state = "ended",
                reason = "cleared",
                ts = Instant.now().epochSecond
            )
        )
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

    private fun callStatusBody(call: Call, reason: String, removed: Boolean = false): PhoneCallStatusBody {
        val state = if (removed) "ended" else call.state.callStateName()
        val details = call.details
        val handle = details?.handle?.schemeSpecificPart
            ?: details?.handle?.toString()?.takeIf { it.isNotBlank() }
        val displayName = details?.callerDisplayName?.takeIf { it.isNotBlank() }
        return PhoneCallStatusBody(
            callId = "call-${System.identityHashCode(call).toString(16)}",
            state = state,
            handle = handle?.takeIf { it.length <= MAX_CALL_HANDLE_CHARS },
            displayName = displayName?.takeIf { it.length <= MAX_CALL_DISPLAY_NAME_CHARS },
            direction = details.callDirectionName(),
            canAnswer = call.state == Call.STATE_RINGING,
            canHangUp = !removed && call.state != Call.STATE_DISCONNECTED,
            isActive = call.state == Call.STATE_ACTIVE,
            reason = reason,
            ts = Instant.now().epochSecond
        )
    }

    private fun Int.callStateName(): String =
        when (this) {
            Call.STATE_NEW -> "new"
            Call.STATE_RINGING -> "ringing"
            Call.STATE_DIALING -> "dialing"
            Call.STATE_CONNECTING -> "connecting"
            Call.STATE_ACTIVE -> "active"
            Call.STATE_HOLDING -> "held"
            Call.STATE_DISCONNECTED -> "disconnected"
            Call.STATE_DISCONNECTING -> "disconnecting"
            Call.STATE_SELECT_PHONE_ACCOUNT -> "select_phone_account"
            else -> "unknown_$this"
        }

    private fun Call.Details?.callDirectionName(): String? {
        if (this == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return null
        }
        return when (callDirection) {
            Call.Details.DIRECTION_INCOMING -> "incoming"
            Call.Details.DIRECTION_OUTGOING -> "outgoing"
            Call.Details.DIRECTION_UNKNOWN -> "unknown"
            else -> "unknown_$callDirection"
        }
    }

    private fun callStatesSummary(): String {
        val states = synchronized(lock) { calls.keys.map { it.state } }
        return if (states.isEmpty()) {
            "none"
        } else {
            states.joinToString(",")
        }
    }

    private const val MAX_CALL_HANDLE_CHARS = 80
    private const val MAX_CALL_DISPLAY_NAME_CHARS = 120
}
