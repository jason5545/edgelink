package com.edgelink.app

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import com.edgelink.core.PhoneLockStateBody
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

internal class AndroidLockStateReporter(
    context: Context,
    private val onState: (PhoneLockStateBody) -> Unit
) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var started = false
    private var lastLocked: Boolean? = null
    private var settleJob: Job? = null
    private var heartbeatJob: Job? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // Keyguard state lags the broadcast slightly (especially
            // SCREEN_OFF -> lock), so sample after a short settle delay.
            settleJob?.cancel()
            settleJob = scope.launch {
                delay(SETTLE_MS)
                emitCurrent(reason = "broadcast:${intent.action}", force = false)
            }
        }
    }

    fun start() {
        if (started) {
            return
        }
        started = true
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_USER_PRESENT)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                appContext.registerReceiver(receiver, filter)
            }
        }.onFailure { error ->
            EdgeLinkLog.warn("lockstate.android.receiver_register_failed", error)
        }
        emitCurrent(reason = "start", force = true)
        // MIUI throttles background broadcasts (observed 2026-08-02:
        // USER_PRESENT/SCREEN_ON never arrived while the phone dozed), so
        // poll on a heartbeat as the reliable baseline. The heartbeat always
        // re-pushes (no dedupe): the Mac freshness-gates "unlocked" reports
        // (2026-08-04), and an unchanged-state heartbeat that never re-pushes
        // would let a steady unlocked report age past the gate.
        heartbeatJob = scope.launch {
            while (isActive) {
                delay(HEARTBEAT_MS)
                emitCurrent(reason = "heartbeat", force = true)
            }
        }
        EdgeLinkLog.info("lockstate.android.reporter_started")
    }

    fun stop() {
        if (!started) {
            return
        }
        started = false
        settleJob?.cancel()
        settleJob = null
        heartbeatJob?.cancel()
        heartbeatJob = null
        runCatching { appContext.unregisterReceiver(receiver) }
            .onFailure { error -> EdgeLinkLog.warn("lockstate.android.receiver_unregister_failed", error) }
        EdgeLinkLog.info("lockstate.android.reporter_stopped")
    }

    fun sendCurrent(reason: String) {
        emitCurrent(reason = reason, force = true)
    }

    private fun emitCurrent(reason: String, force: Boolean) {
        val locked = runCatching {
            appContext.getSystemService(KeyguardManager::class.java)?.isDeviceLocked
        }.getOrNull() ?: return
        if (!force && locked == lastLocked) {
            return
        }
        lastLocked = locked
        onState(PhoneLockStateBody(locked = locked, ts = Instant.now().epochSecond))
        EdgeLinkLog.info("lockstate.android.state locked=$locked reason=$reason")
    }

    private companion object {
        const val SETTLE_MS = 300L
        const val HEARTBEAT_MS = 15_000L
    }
}
