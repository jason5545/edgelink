package com.edgelink.app

import android.app.Notification
import android.content.pm.PackageManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.edgelink.core.NotificationPostBody
import com.edgelink.core.NotificationRemoveBody

class AndroidNotificationListenerService : NotificationListenerService() {
    override fun onListenerConnected() {
        EdgeLinkLog.configure(applicationContext)
        EdgeLinkLog.info("notification.android.listener_connected")
        EdgeLinkRuntimeHolder.existing()?.refreshNotificationAccess()
    }

    override fun onListenerDisconnected() {
        EdgeLinkLog.info("notification.android.listener_disconnected")
        EdgeLinkRuntimeHolder.existing()?.refreshNotificationAccess()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val body = sbn.toNotificationPostBody() ?: return
        EdgeLinkForegroundService.ensureStarted(applicationContext)
        EdgeLinkRuntimeHolder.getOrCreate(applicationContext).onLocalNotificationPosted(body)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) {
            return
        }
        EdgeLinkForegroundService.ensureStarted(applicationContext)
        EdgeLinkRuntimeHolder.getOrCreate(applicationContext).onLocalNotificationRemoved(
            NotificationRemoveBody(id = sbn.stableNotificationId())
        )
    }

    private fun StatusBarNotification.toNotificationPostBody(): NotificationPostBody? {
        if (packageName == this@AndroidNotificationListenerService.packageName) {
            return null
        }
        val notification = notification
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) {
            return null
        }
        if (notification.flags and Notification.FLAG_ONGOING_EVENT != 0) {
            return null
        }
        if (notification.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) {
            return null
        }

        val title = notification.extras.text(Notification.EXTRA_TITLE)
        val text = notification.extras.text(Notification.EXTRA_BIG_TEXT)
            .ifBlank { notification.extras.text(Notification.EXTRA_TEXT) }
        val subtitle = notification.extras.text(Notification.EXTRA_SUB_TEXT).ifBlank { null }
        if (title.isBlank() && text.isBlank()) {
            return null
        }

        return NotificationPostBody(
            id = stableNotificationId(),
            sourcePlatform = "android",
            app = appLabel(packageName),
            bundle = packageName,
            title = title,
            text = text,
            subtitle = subtitle,
            ts = postTime / 1000
        )
    }

    private fun StatusBarNotification.stableNotificationId(): String =
        key ?: "${packageName}:${id}:${tag.orEmpty()}"

    private fun appLabel(packageName: String): String =
        runCatching {
            val applicationInfo = packageManager.getApplicationInfo(packageName, 0)
            packageManager.getApplicationLabel(applicationInfo).toString()
        }.recoverCatching {
            packageManager.getPackageInfo(packageName, PackageManager.GET_META_DATA).applicationInfo
                ?.let(packageManager::getApplicationLabel)
                ?.toString()
                ?: packageName
        }.getOrDefault(packageName)
}

private fun android.os.Bundle.text(key: String): String =
    getCharSequence(key)?.toString()?.trim().orEmpty()
