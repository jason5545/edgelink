package com.edgelink.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.util.Log
import com.edgelink.core.MiLinkCommandBody
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class DebugMiLinkProbeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_PROBE_MILINK) {
            return
        }

        val rawCommand = intent.getStringExtra(EXTRA_COMMAND)
            ?: intent.getStringExtra(EXTRA_COMMAND_ALT)
        Log.i(DEBUG_TAG, "received action=${intent.action} hasCommand=${!rawCommand.isNullOrBlank()}")

        val appContext = context.applicationContext
        EdgeLinkLog.configure(appContext)
        if (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            EdgeLinkLog.warn("xiaomi.milink.debug_probe_rejected_non_debug")
            return
        }

        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val command = rawCommand
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                if (command != null) {
                    runMiLinkCommand(appContext, intent, command)
                    return@launch
                }

                EdgeLinkLog.info("xiaomi.milink.debug_probe_requested")
                val result = AndroidMiLinkPhoneContinuityBridge.probe(appContext)
                EdgeLinkLog.info(
                    "xiaomi.milink.debug_probe_result " +
                        "success=${result.success} " +
                        "callRelay=${result.callRelayServiceOk} " +
                        "mediaRelayCallback=${result.mediaRelayCallbackOk} " +
                        "remoteDevices=${result.remoteDeviceCount} " +
                        "mediaRelayCandidates=${result.mediaRelayCandidateCount} " +
                        "message=${result.message}"
                )
            } catch (error: Throwable) {
                EdgeLinkLog.error("xiaomi.milink.debug_probe_failed", error)
            } finally {
                pendingResult.finish()
            }
        }
    }

    private suspend fun runMiLinkCommand(context: Context, intent: Intent, command: String) {
        val args = intent.extras
            ?.keySet()
            .orEmpty()
            .filter { it.startsWith(EXTRA_ARG_PREFIX) }
            .associate { key ->
                key.removePrefix(EXTRA_ARG_PREFIX) to intent.getStringExtra(key).orEmpty()
            }
        val requestId = "debug-${System.currentTimeMillis()}"
        EdgeLinkLog.info(
            "xiaomi.milink.debug_command_requested command=$command requestId=$requestId " +
                "args=${args.keys.sorted().joinToString(",")}"
        )
        val result = AndroidMiLinkCommandBridge(context).handle(
            MiLinkCommandBody(
                requestId = requestId,
                command = command,
                args = args,
                ts = System.currentTimeMillis() / 1_000L
            )
        )
        EdgeLinkLog.info(
            "xiaomi.milink.debug_command_result command=${result.command} " +
                "requestId=${result.requestId} success=${result.success} route=${result.route} " +
                "message=${result.message.forDebugMiLinkProbeLog()} " +
                "data=${result.data.forDebugMiLinkProbeLog()}"
        )
    }

    companion object {
        private const val DEBUG_TAG = "EdgeLinkDebugProbe"
        const val ACTION_PROBE_MILINK = "com.edgelink.app.DEBUG_PROBE_MILINK"
        const val EXTRA_COMMAND = "command"
        const val EXTRA_COMMAND_ALT = "edgelink.command"
        const val EXTRA_ARG_PREFIX = "arg."
    }
}

private fun String.forDebugMiLinkProbeLog(): String =
    replace('\n', ' ')
        .replace('\r', ' ')
        .take(1_500)

private fun Map<String, String>.forDebugMiLinkProbeLog(): String =
    entries
        .sortedBy { it.key }
        .joinToString(separator = ";") { (key, value) -> "$key=${value.forDebugMiLinkProbeLog()}" }
        .take(3_000)
