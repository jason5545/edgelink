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
                    "已連線到 ${state.peerName}"
                } else {
                    localizedStatus(state.connectionStatus)
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

        private fun localizedStatus(status: String): String =
            when (status) {
                "Starting" -> "啟動中"
                "Registering" -> "註冊裝置中"
                "No paired Mac" -> "尚未配對 Mac"
                "Invalid Mac ID" -> "Mac ID 不正確"
                "Opening pairing" -> "正在開啟配對"
                "Pairing failed" -> "配對失敗"
                "Waiting for Mac" -> "等待 Mac 確認"
                "Compare code" -> "比對確認碼"
                "Paired" -> "已配對"
                "Setup failed" -> "初始化失敗"
                "Reconnecting" -> "重新連線中"
                "Connecting relay" -> "連線到 relay"
                "Handshaking" -> "握手中"
                "Connected" -> "已連線"
                "Disconnected" -> "已中斷"
                else -> status
            }
    }
}
