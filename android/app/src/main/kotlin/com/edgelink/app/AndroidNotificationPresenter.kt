package com.edgelink.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.edgelink.core.NotificationPostBody
import com.edgelink.core.NotificationRemoveBody
import java.nio.ByteBuffer
import java.security.MessageDigest

private const val REMOTE_NOTIFICATION_CHANNEL_ID = "edgelink_remote_notifications"
private const val SERVICE_NOTIFICATION_CHANNEL_ID = "edgelink_sync_service"

class AndroidNotificationPresenter(private val context: Context) {
    private val appContext = context.applicationContext
    private val notificationManager = appContext.getSystemService(NotificationManager::class.java)

    init {
        createChannels(appContext)
    }

    fun show(body: NotificationPostBody) {
        if (!canPostNotifications(appContext)) {
            EdgeLinkLog.warn("notification.android.post_blocked id=${body.id}")
            return
        }

        val title = body.title.ifBlank { body.app }
        val text = body.text
        val notification = Notification.Builder(appContext, REMOTE_NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(title)
            .setContentText(text)
            .setSubText(body.app)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(openAppIntent(appContext))
            .setAutoCancel(true)
            .setShowWhen(true)
            .setWhen(body.ts * 1000)
            .build()

        notificationManager.notify(notificationId(body.id, body.sourceDeviceId), notification)
        EdgeLinkLog.info("notification.android.remote_shown id=${body.id} app=${body.app}")
    }

    fun remove(body: NotificationRemoveBody) {
        notificationManager.cancel(notificationId(body.id, body.sourceDeviceId))
        EdgeLinkLog.info("notification.android.remote_removed id=${body.id}")
    }

    companion object {
        fun createChannels(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val remote = NotificationChannel(
                REMOTE_NOTIFICATION_CHANNEL_ID,
                "遠端通知",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            val service = NotificationChannel(
                SERVICE_NOTIFICATION_CHANNEL_ID,
                "EdgeLink 同步",
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(remote)
            manager.createNotificationChannel(service)
        }

        fun serviceNotification(context: Context, status: String): Notification {
            createChannels(context)
            return Notification.Builder(context, SERVICE_NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setContentTitle("EdgeLink")
                .setContentText(status)
                .setContentIntent(openAppIntent(context))
                .setOngoing(true)
                .setShowWhen(false)
                .build()
        }

        fun canPostNotifications(context: Context): Boolean =
            Build.VERSION.SDK_INT < 33 ||
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

        private fun openAppIntent(context: Context): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            return PendingIntent.getActivity(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        private fun notificationId(id: String, sourceDeviceId: String?): Int {
            val raw = "${sourceDeviceId ?: "remote"}:$id"
            val digest = MessageDigest.getInstance("SHA-256").digest(raw.encodeToByteArray())
            return ByteBuffer.wrap(digest).int and Int.MAX_VALUE
        }
    }
}
