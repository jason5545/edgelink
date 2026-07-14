package com.edgelink.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class DebugMiLinkProbeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_PROBE_MILINK) {
            return
        }

        val appContext = context.applicationContext
        EdgeLinkLog.configure(appContext)
        if (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            EdgeLinkLog.warn("xiaomi.milink.debug_probe_rejected_non_debug")
            return
        }

        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
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

    companion object {
        const val ACTION_PROBE_MILINK = "com.edgelink.app.DEBUG_PROBE_MILINK"
    }
}
