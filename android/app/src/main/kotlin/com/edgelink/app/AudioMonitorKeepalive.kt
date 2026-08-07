package com.edgelink.app

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

// Keeps com.miui.audiomonitor schedulable during a distaudio call. MIUI parks
// the background process in the background cpuset/cpu cgroup (and sometimes
// the cgroup v2 freezer), which stalls the LSPosed call-inject server thread
// for the whole call — observed live: zero process logs for ~50s and the
// entire mic PCM backlog drained in one burst only at hangup.
//
// The actual 2s poll loop lives inside the root Shizuku service process
// (AudioMonitorKeepaliveLoop): earlier client-side sh -c polling hid its own
// failures behind a forced exit 0 and each command had to pass the shell
// command policy. This client object only starts/stops that service-side
// loop through the sanctioned Shizuku channel.
object AudioMonitorKeepalive {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val active = AtomicBoolean(false)

    fun start(context: Context) {
        if (!active.compareAndSet(false, true)) {
            return
        }
        val appContext = context.applicationContext
        scope.launch {
            EdgeLinkLog.info("phone.android.audiomonitor_keepalive_start")
            val ok = AndroidShizukuSupport.startAudioMonitorKeepalive(appContext)
            if (!ok) {
                active.set(false)
                EdgeLinkLog.warn("phone.android.audiomonitor_keepalive_start_failed")
            }
        }
    }

    fun stop() {
        if (!active.compareAndSet(true, false)) {
            return
        }
        EdgeLinkLog.info("phone.android.audiomonitor_keepalive_stop")
        scope.launch {
            AndroidShizukuSupport.stopAudioMonitorKeepalive(
                DistAudioConnector.appContext ?: return@launch
            )
        }
    }
}
