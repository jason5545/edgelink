package com.edgelink.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class EdgeLinkXiaomiMirrorCastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != MiLinkPrivilegeHookPolicy.XIAOMI_MIRROR_CAST_FRAME_ACTION) {
            return
        }
        val frame = intent.getByteArrayExtra(MiLinkPrivilegeHookPolicy.XIAOMI_MIRROR_CAST_FRAME_EXTRA)
            ?: return
        if (frame.size < 5 || frame[0].toInt() != 5) {
            EdgeLinkLog.warn("xiaomi.mirror.cast_frame_ignored bytes=${frame.size}")
            return
        }
        val appContext = context.applicationContext
        EdgeLinkLog.configure(appContext)
        runCatching {
            EdgeLinkForegroundService.ensureStarted(appContext)
        }.onFailure { error ->
            EdgeLinkLog.warn("xiaomi.mirror.cast_frame_service_start_failed", error)
        }
        EdgeLinkRuntimeHolder.getOrCreate(appContext).onXiaomiMirrorCastFrame(frame)
    }
}
