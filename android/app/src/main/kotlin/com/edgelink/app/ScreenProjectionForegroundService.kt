package com.edgelink.app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

private const val SCREEN_PROJECTION_NOTIFICATION_ID = 1002

class ScreenProjectionForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        EdgeLinkLog.configure(applicationContext)
        AndroidNotificationPresenter.createChannels(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startProjectionForeground()
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                val data = intent.projectionDataExtra()
                if (resultCode != 0 && data != null) {
                    EdgeLinkRuntimeHolder.getOrCreate(applicationContext)
                        .onScreenCapturePermissionGranted(resultCode, data)
                } else {
                    EdgeLinkRuntimeHolder.existing()?.onScreenCapturePermissionDenied()
                    stopSelf(startId)
                }
            }
            else -> startProjectionForeground()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startProjectionForeground() {
        val notification = AndroidNotificationPresenter.serviceNotification(
            applicationContext,
            "Sharing phone screen"
        )
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                SCREEN_PROJECTION_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(SCREEN_PROJECTION_NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val ACTION_START = "com.edgelink.app.SCREEN_PROJECTION_START"
        private const val EXTRA_RESULT_CODE = "resultCode"
        private const val EXTRA_DATA = "data"

        fun startProjection(context: Context, resultCode: Int, data: Intent) {
            val intent = Intent(context, ScreenProjectionForegroundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_DATA, data)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, ScreenProjectionForegroundService::class.java)
            context.stopService(intent)
        }
    }
}

private fun Intent.projectionDataExtra(): Intent? =
    if (Build.VERSION.SDK_INT >= 33) {
        getParcelableExtra("data", Intent::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra("data")
    }
