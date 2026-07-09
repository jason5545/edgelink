package com.edgelink.app

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.edgelink.core.NotificationPostBody
import com.edgelink.core.NotificationRemoveBody

class AndroidNotificationListenerService : NotificationListenerService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lastForwardedBodies = linkedMapOf<String, NotificationPostBody>()
    private var screenSharePolling = false
    private val screenSharePollRunnable = object : Runnable {
        override fun run() {
            syncActiveNotificationsInternal(
                reason = "screen_share_poll",
                force = false
            )
            if (screenSharePolling) {
                mainHandler.postDelayed(this, ACTIVE_NOTIFICATION_POLL_INTERVAL_MS)
            }
        }
    }

    override fun onListenerConnected() {
        EdgeLinkLog.configure(applicationContext)
        activeService = this
        EdgeLinkLog.info("notification.android.listener_connected")
        EdgeLinkRuntimeHolder.existing()?.refreshNotificationAccess()
        syncActiveNotificationsInternal(reason = "listener_connected", force = true)
        if (screenSharingActive) {
            startScreenSharePolling()
        }
    }

    override fun onListenerDisconnected() {
        EdgeLinkLog.info("notification.android.listener_disconnected")
        EdgeLinkRuntimeHolder.existing()?.refreshNotificationAccess()
        if (activeService === this) {
            activeService = null
        }
        stopScreenSharePolling()
    }

    override fun onDestroy() {
        if (activeService === this) {
            activeService = null
        }
        stopScreenSharePolling()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        forwardStatusBarNotification(sbn, reason = "posted", force = false)
        if (screenSharePolling) {
            scheduleActiveNotificationSync(
                reason = "posted_recheck_fast",
                delayMs = POSTED_NOTIFICATION_RECHECK_FAST_MS,
                force = false
            )
            scheduleActiveNotificationSync(
                reason = "posted_recheck_late",
                delayMs = POSTED_NOTIFICATION_RECHECK_LATE_MS,
                force = false
            )
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) {
            return
        }
        lastForwardedBodies.remove(sbn.stableNotificationId())
        EdgeLinkForegroundService.ensureStarted(applicationContext)
        EdgeLinkRuntimeHolder.getOrCreate(applicationContext).onLocalNotificationRemoved(
            NotificationRemoveBody(id = sbn.stableNotificationId())
        )
    }

    private fun startScreenSharePolling() {
        if (screenSharePolling) {
            return
        }
        screenSharePolling = true
        syncActiveNotificationsInternal(reason = "screen_share_started", force = true)
        mainHandler.removeCallbacks(screenSharePollRunnable)
        mainHandler.postDelayed(screenSharePollRunnable, ACTIVE_NOTIFICATION_POLL_INTERVAL_MS)
        EdgeLinkLog.info("notification.android.screen_share_resync_started")
    }

    private fun stopScreenSharePolling() {
        if (!screenSharePolling) {
            return
        }
        screenSharePolling = false
        mainHandler.removeCallbacks(screenSharePollRunnable)
        syncActiveNotificationsInternal(reason = "screen_share_stopped", force = true)
        EdgeLinkLog.info("notification.android.screen_share_resync_stopped")
    }

    private fun scheduleActiveNotificationSync(reason: String, delayMs: Long, force: Boolean) {
        mainHandler.postDelayed({
            syncActiveNotificationsInternal(reason = reason, force = force)
        }, delayMs)
    }

    private fun syncActiveNotificationsInternal(reason: String, force: Boolean) {
        val active = runCatching {
            activeNotifications.orEmpty().toList()
        }.getOrElse { error ->
            EdgeLinkLog.warn("notification.android.active_sync_failed reason=$reason", error)
            return
        }

        val activeIds = active.mapTo(mutableSetOf()) { it.stableNotificationId() }
        var forwarded = 0
        active.forEach { sbn ->
            if (forwardStatusBarNotification(sbn, reason = reason, force = force)) {
                forwarded += 1
            }
        }
        lastForwardedBodies.keys.removeAll { it !in activeIds }
        EdgeLinkLog.info(
            "notification.android.active_sync reason=$reason active=${active.size} forwarded=$forwarded force=$force"
        )
    }

    private fun forwardStatusBarNotification(
        sbn: StatusBarNotification,
        reason: String,
        force: Boolean
    ): Boolean {
        val body = sbn.toNotificationPostBody() ?: return false
        if (!force && lastForwardedBodies[body.id] == body) {
            return false
        }
        lastForwardedBodies[body.id] = body
        EdgeLinkForegroundService.ensureStarted(applicationContext)
        EdgeLinkRuntimeHolder.getOrCreate(applicationContext).onLocalNotificationPosted(body)
        EdgeLinkLog.info("notification.android.forwarded reason=$reason id=${body.id} app=${body.app}")
        return true
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
            .ifBlank { notification.extras.text(Notification.EXTRA_TITLE_BIG) }
            .ifBlank { notification.extras.text(Notification.EXTRA_CONVERSATION_TITLE) }
        val text = notification.extras.text(Notification.EXTRA_BIG_TEXT)
            .ifBlank { notification.extras.text(Notification.EXTRA_TEXT) }
            .ifBlank { notification.extras.messagingText() }
            .ifBlank { notification.extras.textLines() }
            .ifBlank { notification.tickerText?.toString()?.trim().orEmpty() }
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

    companion object {
        @Volatile
        private var activeService: AndroidNotificationListenerService? = null
        @Volatile
        private var screenSharingActive = false

        fun onScreenSharingStarted(context: Context) {
            screenSharingActive = true
            val service = activeService
            if (service == null) {
                EdgeLinkLog.warn("notification.android.screen_share_resync_unavailable no_listener")
                requestListenerRebind(context, reason = "screen_share_started")
                return
            }
            service.mainHandler.post { service.startScreenSharePolling() }
        }

        fun onScreenSharingStopped() {
            screenSharingActive = false
            activeService?.let { service ->
                service.mainHandler.post { service.stopScreenSharePolling() }
            }
        }

        fun requestActiveNotificationSync(context: Context, reason: String) {
            val service = activeService
            if (service == null) {
                EdgeLinkLog.warn("notification.android.active_sync_unavailable reason=$reason no_listener")
                requestListenerRebind(context, reason = reason)
                return
            }
            service.mainHandler.post {
                service.syncActiveNotificationsInternal(reason = reason, force = true)
            }
        }

        private fun requestListenerRebind(context: Context, reason: String) {
            val componentName = ComponentName(
                context.applicationContext,
                AndroidNotificationListenerService::class.java
            )
            runCatching {
                requestRebind(componentName)
            }.onSuccess {
                EdgeLinkLog.info("notification.android.rebind_requested reason=$reason")
            }.onFailure { error ->
                EdgeLinkLog.warn("notification.android.rebind_failed reason=$reason", error)
            }
        }

        private const val ACTIVE_NOTIFICATION_POLL_INTERVAL_MS = 1_000L
        private const val POSTED_NOTIFICATION_RECHECK_FAST_MS = 250L
        private const val POSTED_NOTIFICATION_RECHECK_LATE_MS = 1_500L
    }
}

private fun android.os.Bundle.text(key: String): String =
    getCharSequence(key)?.toString()?.trim().orEmpty()

private fun android.os.Bundle.textLines(): String =
    getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
        ?.mapNotNull { it?.toString()?.trim()?.takeIf(String::isNotBlank) }
        ?.joinToString("\n")
        .orEmpty()

@Suppress("DEPRECATION")
private fun android.os.Bundle.messagingText(): String =
    Notification.MessagingStyle.Message.getMessagesFromBundleArray(
        getParcelableArray(Notification.EXTRA_MESSAGES)
    )
        .mapNotNull { it.text?.toString()?.trim()?.takeIf(String::isNotBlank) }
        .joinToString("\n")
