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
    private const val REFRESH_FAILURE_RETRY_DELAY_MS = 5_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleMutex = Mutex()
    private var refreshJob: Job? = null

    @Volatile
    private var activeKey: String? = null

    fun isArmed(): Boolean = activeKey != null

    fun noteSessionArmed(context: Context, peerHost: String?, peerPort: Int?) {
        val appContext = context.applicationContext
        val key = "${peerHost.orEmpty()}:${peerPort?.toString().orEmpty()}"
        scope.launch {
            lifecycleMutex.withLock {
                if (refreshJob?.isActive == true && activeKey == key) {
                    return@withLock
                }
                refreshJob?.cancelAndJoin()
                activeKey = key
                EdgeLinkLog.info(
                    "xiaomi.mirror.android.screen_remote_keeper_start peer=$key"
                )
                refreshJob = launch {
                    var nextDelayMs = REFRESH_INTERVAL_MS
                    while (isActive) {
                        delay(nextDelayMs)
                        val result = runCatching {
                            AndroidShizukuSupport.armMirrorScreenRemote(
                                context = appContext,
                                peerHost = peerHost,
                                peerPort = peerPort
                            )
                        }
                        result.onSuccess { operationResult ->
                            EdgeLinkLog.info(
                                "xiaomi.mirror.android.screen_remote_keeper_refresh peer=$key " +
                                    "success=${operationResult.success}"
                            )
                            nextDelayMs = if (operationResult.success) {
                                REFRESH_INTERVAL_MS
                            } else {
                                REFRESH_FAILURE_RETRY_DELAY_MS
                            }
                        }.onFailure { error ->
                            EdgeLinkLog.warn(
                                "xiaomi.mirror.android.screen_remote_keeper_refresh_failed " +
                                    "peer=$key error=${error.javaClass.simpleName}:${error.message.orEmpty()} " +
                                    "retryDelayMs=$REFRESH_FAILURE_RETRY_DELAY_MS"
                            )
                            nextDelayMs = REFRESH_FAILURE_RETRY_DELAY_MS
                        }
                    }
                }
            }
        }
    }

    fun stop(reason: String) {
        scope.launch {
            lifecycleMutex.withLock {
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
}
