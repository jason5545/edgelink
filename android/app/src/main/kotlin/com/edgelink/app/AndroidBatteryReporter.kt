package com.edgelink.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import com.edgelink.core.BatteryStatusBody
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

internal class AndroidBatteryReporter(
    context: Context,
    private val onStatus: (BatteryStatusBody) -> Unit
) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var heartbeatJob: Job? = null
    private var started = false
    private var lastSignature: String? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            snapshot(intent)?.let { emit(it, reason = "broadcast", force = false) }
        }
    }

    fun start() {
        if (started) {
            return
        }
        started = true
        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val sticky = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                appContext.registerReceiver(receiver, filter)
            }
        }.onFailure { error ->
            EdgeLinkLog.warn("battery.android.receiver_register_failed", error)
        }.getOrNull()
        sticky?.let { intent -> snapshot(intent)?.let { emit(it, reason = "start", force = false) } }
        heartbeatJob = scope.launch {
            while (isActive) {
                delay(HEARTBEAT_MS)
                currentSnapshot()?.let { emit(it, reason = "heartbeat", force = true) }
            }
        }
        EdgeLinkLog.info("battery.android.reporter_started")
    }

    fun stop() {
        if (!started) {
            return
        }
        started = false
        heartbeatJob?.cancel()
        heartbeatJob = null
        runCatching { appContext.unregisterReceiver(receiver) }
            .onFailure { error -> EdgeLinkLog.warn("battery.android.receiver_unregister_failed", error) }
        EdgeLinkLog.info("battery.android.reporter_stopped")
    }

    fun sendCurrent(reason: String) {
        currentSnapshot()?.let { emit(it, reason = reason, force = true) }
    }

    private fun currentSnapshot(): BatteryStatusBody? {
        val intent = runCatching {
            appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        }.getOrNull() ?: return null
        return snapshot(intent)
    }

    private fun snapshot(intent: Intent): BatteryStatusBody? {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) {
            return null
        }
        val percent = (level * 100) / scale
        if (percent !in 0..100) {
            return null
        }
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val plugged = when (intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)) {
            BatteryManager.BATTERY_PLUGGED_USB -> "usb"
            BatteryManager.BATTERY_PLUGGED_AC -> "ac"
            BatteryManager.BATTERY_PLUGGED_WIRELESS -> "wireless"
            else -> null
        }
        val rawTemperature = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        val temperature = if (rawTemperature == Int.MIN_VALUE) null else rawTemperature / 10.0
        return BatteryStatusBody(
            level = percent,
            charging = charging,
            plugged = plugged,
            temperature = temperature,
            ts = Instant.now().epochSecond
        )
    }

    private fun emit(status: BatteryStatusBody, reason: String, force: Boolean) {
        val signature = listOf(
            status.level.toString(),
            status.charging.toString(),
            status.plugged ?: "none"
        ).joinToString(":")
        if (!force && signature == lastSignature) {
            return
        }
        lastSignature = signature
        onStatus(status)
        EdgeLinkLog.info(
            "battery.android.status level=${status.level} charging=${status.charging} " +
                "plugged=${status.plugged ?: "none"} reason=$reason"
        )
    }

    private companion object {
        const val HEARTBEAT_MS = 60_000L
    }
}
