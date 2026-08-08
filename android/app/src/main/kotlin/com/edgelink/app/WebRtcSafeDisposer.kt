package com.edgelink.app

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.webrtc.DataChannel
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory

// Deferred native disposal for WebRTC objects. Calling PeerConnection.dispose()
// synchronously right after close() races libwebrtc's own signaling/network
// threads: close() posts final state changes (ICE DISCONNECTED/CLOSED, data
// channel CLOSING) onto those threads, and disposing the native peer
// connection while they are still draining destroys the mutexes those tasks
// lock — observed live as SIGABRT "FORTIFY: pthread_mutex_lock called on a
// destroyed mutex" in libjingle's signaling thread during mirror TURN session
// churn (2026-08-08, twice). close() stays synchronous and graceful; only the
// native free is pushed out past the drain window on a dedicated daemon
// thread, one queue shared by every session so late disposals never interleave.
internal object WebRtcSafeDisposer {
    private const val DISPOSE_DELAY_MS = 300L

    private val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "EdgeLinkWebRtcDispose").apply { isDaemon = true }
    }

    fun disposeLater(channel: DataChannel?, peerConnection: PeerConnection?, factory: PeerConnectionFactory?) {
        if (channel == null && peerConnection == null && factory == null) {
            return
        }
        executor.schedule(
            {
                if (channel != null) {
                    runCatching { channel.dispose() }
                }
                if (peerConnection != null) {
                    runCatching { peerConnection.dispose() }
                }
                if (factory != null) {
                    runCatching { factory.dispose() }
                }
            },
            DISPOSE_DELAY_MS,
            TimeUnit.MILLISECONDS
        )
    }
}
