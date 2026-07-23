package com.edgelink.app

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

object AndroidMirrorScreenRemoteKeeper {
    private const val REFRESH_INTERVAL_MS = 60_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleMutex = Mutex()
    private var refreshJob: Job? = null
    private var activeKey: String? = null
    private var pendingStopJob: Job? = null

    fun noteSessionArmed(context: Context, peerHost: String?, peerPort: Int?) {
        val appContext = context.applicationContext
        val key = "${peerHost.orEmpty()}:${peerPort?.toString().orEmpty()}"
        scope.launch {
            lifecycleMutex.withLock {
                pendingStopJob?.cancel()
                pendingStopJob = null
                if (refreshJob?.isActive == true && activeKey == key) {
                    return@withLock
                }
                refreshJob?.cancelAndJoin()
                activeKey = key
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.screen_remote_keeper_start peer=$key"
                )
                refreshJob = launch {
                    while (isActive) {
                        delay(REFRESH_INTERVAL_MS)
                        val result = runCatching {
                            AndroidShizukuSupport.armMirrorScreenRemote(
                                context = appContext,
                                peerHost = peerHost,
                                peerPort = peerPort
                            )
                        }.getOrElse { error ->
                            EdgeLinkLog.warn(
                                "xiaomi.mirror.android.screen_remote_keeper_refresh_failed " +
                                    "peer=$key error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
                            )
                            continue
                        }
                        EdgeLinkLog.info(
                            "xiaomi.mirror.android.screen_remote_keeper_refresh peer=$key " +
                                "success=${result.success}"
                        )
                    }
                }
            }
        }
    }

    fun stop(reason: String) {
        scope.launch {
            lifecycleMutex.withLock {
                pendingStopJob?.cancel()
                pendingStopJob = null
                val key = activeKey
                activeKey = null
                refreshJob?.cancelAndJoin()
                refreshJob = null
                if (key != null) {
                    EdgeLinkLog.info(
                        "xiaomi.mirror.android.screen_remote_keeper_stop peer=$key reason=$reason"
                    )
                }
            }
        }
    }

    fun stopAfterGrace(reason: String, graceMs: Long) {
        scope.launch {
            lifecycleMutex.withLock {
                val key = activeKey ?: return@withLock
                pendingStopJob?.cancel()
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.screen_remote_keeper_stop_scheduled " +
                        "peer=$key reason=$reason graceMs=$graceMs"
                )
                pendingStopJob = scope.launch {
                    delay(graceMs)
                    stop("$reason:grace_expired")
                }
            }
        }
    }
}
