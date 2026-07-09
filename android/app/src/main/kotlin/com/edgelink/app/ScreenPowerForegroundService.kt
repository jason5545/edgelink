package com.edgelink.app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

private const val SCREEN_POWER_NOTIFICATION_ID = 1003

class ScreenPowerForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        EdgeLinkLog.configure(applicationContext)
        AndroidNotificationPresenter.createChannels(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!startPowerForeground()) {
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        EdgeLinkLog.info("screen.android.power_foreground_stopped")
        super.onDestroy()
    }

    private fun startPowerForeground(): Boolean {
        val notification = AndroidNotificationPresenter.serviceNotification(
            applicationContext,
            "Keeping phone screen awake"
        )
        return runCatching {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    SCREEN_POWER_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(SCREEN_POWER_NOTIFICATION_ID, notification)
            }
        }.onSuccess {
            EdgeLinkLog.info("screen.android.power_foreground_started")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.power_foreground_start_failed", error)
        }.isSuccess
    }

    companion object {
        fun start(context: Context) {
            val appContext = context.applicationContext
            val intent = Intent(appContext, ScreenPowerForegroundService::class.java)
            runCatching {
                if (Build.VERSION.SDK_INT >= 26) {
                    appContext.startForegroundService(intent)
                } else {
                    appContext.startService(intent)
                }
            }.onSuccess {
                EdgeLinkLog.info("screen.android.power_foreground_start_requested")
            }.onFailure { error ->
                EdgeLinkLog.warn("screen.android.power_foreground_request_failed", error)
            }
        }

        fun stop(context: Context) {
            val appContext = context.applicationContext
            val intent = Intent(appContext, ScreenPowerForegroundService::class.java)
            appContext.stopService(intent)
        }
    }
}
