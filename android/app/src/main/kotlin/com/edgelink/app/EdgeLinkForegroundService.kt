package com.edgelink.app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

private const val EDGE_LINK_SERVICE_NOTIFICATION_ID = 1001

class EdgeLinkForegroundService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var controller: EdgeLinkController
    private var notificationJob: Job? = null

    override fun onCreate() {
        super.onCreate()
        EdgeLinkLog.configure(applicationContext)
        AndroidNotificationPresenter.createChannels(applicationContext)
        updateForegroundNotification("Starting")

        controller = EdgeLinkRuntimeHolder.getOrCreate(applicationContext)
        notificationJob = scope.launch {
            controller.state.collectLatest { state ->
                val status = if (state.isConnected) {
                    applicationContext.getString(R.string.service_connected_to, state.peerName)
                } else {
                    localizedStatus(applicationContext, state.connectionStatus)
                }
                updateForegroundNotification(status)
            }
        }
        EdgeLinkLog.info("service.android.foreground_started")
    }

    private fun updateForegroundNotification(status: String) {
        runCatching {
            startForeground(
                EDGE_LINK_SERVICE_NOTIFICATION_ID,
                AndroidNotificationPresenter.serviceNotification(applicationContext, status)
            )
        }.onFailure { error ->
            EdgeLinkLog.warn(
                "service.android.foreground_update_failed status=$status " +
                    "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        notificationJob?.cancel()
        scope.cancel()
        if (::controller.isInitialized) {
            EdgeLinkRuntimeHolder.close(controller)
        }
        EdgeLinkLog.info("service.android.foreground_stopped")
        super.onDestroy()
    }

    companion object {
        fun ensureStarted(context: Context) {
            val intent = Intent(context, EdgeLinkForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        private fun localizedStatus(context: Context, status: String): String =
            when (status) {
                "Starting" -> context.getString(R.string.status_starting)
                "Registering" -> context.getString(R.string.status_registering)
                "No paired Mac" -> context.getString(R.string.status_no_paired_mac)
                "Invalid Mac ID" -> context.getString(R.string.status_invalid_mac_id)
                "Opening pairing" -> context.getString(R.string.status_opening_pairing)
                "Pairing failed" -> context.getString(R.string.status_pairing_failed)
                "Waiting for Mac" -> context.getString(R.string.status_waiting_for_mac)
                "Compare code" -> context.getString(R.string.status_compare_code)
                "Paired" -> context.getString(R.string.status_paired)
                "Setup failed" -> context.getString(R.string.status_setup_failed)
                "Reconnecting" -> context.getString(R.string.status_reconnecting)
                "Connecting relay" -> context.getString(R.string.status_connecting_relay)
                "Handshaking" -> context.getString(R.string.status_handshaking)
                "Connected" -> context.getString(R.string.status_connected)
                "Disconnected" -> context.getString(R.string.status_disconnected)
                "Mac sleeping" -> context.getString(R.string.status_mac_sleeping)
                else -> status
            }
    }
}
