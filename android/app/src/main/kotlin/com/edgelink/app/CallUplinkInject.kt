package com.edgelink.app

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

// Lifecycle driver for the no-hook call-uplink inject. During a relayed call
// the root Shizuku service owns the 19307 endpoint and writes the Mac mic
// PCM into a telephony-routed AudioTrack; the LSPosed feed inside
// audiomonitor stays dormant (debug.edgelink.call_inject_mode=shizuku). If
// the root route is refused the injector restores mode=hook and restarts
// audiomonitor, so the hook path resumes without any extra wiring here.
object CallUplinkInject {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val active = AtomicBoolean(false)

    fun start(context: Context) {
        if (!active.compareAndSet(false, true)) {
            return
        }
        val appContext = context.applicationContext
        scope.launch {
            EdgeLinkLog.info("phone.android.call_uplink_injector_start")
            val ok = AndroidShizukuSupport.startCallUplinkInjector(appContext)
            if (!ok) {
                active.set(false)
                EdgeLinkLog.warn("phone.android.call_uplink_injector_start_failed")
            }
        }
    }

    fun stop() {
        if (!active.compareAndSet(true, false)) {
            return
        }
        EdgeLinkLog.info("phone.android.call_uplink_injector_stop")
        scope.launch {
            AndroidShizukuSupport.stopCallUplinkInjector(
                DistAudioConnector.appContext ?: return@launch
            )
        }
    }
}
