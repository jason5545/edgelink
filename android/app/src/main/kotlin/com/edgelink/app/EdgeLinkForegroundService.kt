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
        startForeground(
            EDGE_LINK_SERVICE_NOTIFICATION_ID,
            AndroidNotificationPresenter.serviceNotification(applicationContext, "Starting")
        )

        controller = EdgeLinkRuntimeHolder.getOrCreate(applicationContext)
        notificationJob = scope.launch {
            controller.state.collectLatest { state ->
                val status = if (state.isConnected) "Connected to ${state.peerName}" else state.connectionStatus
                startForeground(
                    EDGE_LINK_SERVICE_NOTIFICATION_ID,
                    AndroidNotificationPresenter.serviceNotification(applicationContext, status)
                )
            }
        }
        EdgeLinkLog.info("service.android.foreground_started")
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
    }
}
