package com.edgelink.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.setContent
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.edgelink.core.InputKeyBody
import com.edgelink.core.InputPointerBody
import com.edgelink.core.InputTextBody
import com.edgelink.ui.EdgeLinkActions
import com.edgelink.ui.EdgeLinkApp

class MainActivity : ComponentActivity() {
    private lateinit var controller: EdgeLinkController
    private lateinit var actions: EdgeLinkActivityActions
    private var openNotificationAccessAfterPermission = false

    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            controller.refreshNotificationAccess()
            if (openNotificationAccessAfterPermission) {
                openNotificationAccessAfterPermission = false
                openNotificationSettingsIfNeeded()
            }
        }

    private val smsPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            controller.refreshNotificationAccess()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        EdgeLinkForegroundService.ensureStarted(applicationContext)
        controller = EdgeLinkRuntimeHolder.getOrCreate(applicationContext)
        actions = EdgeLinkActivityActions(
            controller,
            ::handleNotificationSyncChange,
            ::handleOpenNotificationSettings,
            ::handleOpenRemoteInputSettings,
            ::handleOpenSmsSettings
        )
        setContent {
            val state by controller.state.collectAsState()
            EdgeLinkApp(state = state, actions = actions)
        }
    }

    override fun onResume() {
        super.onResume()
        controller.refreshNotificationAccess()
    }

    private fun handleNotificationSyncChange(enabled: Boolean) {
        controller.onNotificationSyncChange(enabled)
        if (enabled) {
            ensureNotificationPermissions()
        }
    }

    private fun handleOpenNotificationSettings() {
        if (!AndroidNotificationPresenter.canPostNotifications(this)) {
            requestPostNotificationsPermission(openAccessAfterPermission = false)
        } else {
            openNotificationSettingsIfNeeded(force = true)
        }
    }

    private fun handleOpenRemoteInputSettings() {
        controller.onOpenRemoteInputSettings()
    }

    private fun handleOpenSmsSettings() {
        controller.onOpenSmsSettings()
        smsPermissionLauncher.launch(AndroidSmsSync.requiredPermissions)
    }

    private fun ensureNotificationPermissions() {
        if (!AndroidNotificationPresenter.canPostNotifications(this)) {
            requestPostNotificationsPermission(openAccessAfterPermission = true)
            return
        }
        openNotificationSettingsIfNeeded()
    }

    private fun requestPostNotificationsPermission(openAccessAfterPermission: Boolean) {
        if (Build.VERSION.SDK_INT < 33) {
            openNotificationSettingsIfNeeded()
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            openNotificationSettingsIfNeeded()
            return
        }
        openNotificationAccessAfterPermission = openAccessAfterPermission
        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun openNotificationSettingsIfNeeded(force: Boolean = false) {
        controller.refreshNotificationAccess()
        if (force && !AndroidNotificationPresenter.canPostNotifications(this)) {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            startActivity(intent)
            return
        }
        if (force || !controller.isNotificationListenerEnabled()) {
            controller.onOpenNotificationSettings()
        }
    }
}

private class EdgeLinkActivityActions(
    private val delegate: EdgeLinkController,
    private val notificationSyncChangeHandler: (Boolean) -> Unit,
    private val openNotificationSettingsHandler: () -> Unit,
    private val openRemoteInputSettingsHandler: () -> Unit,
    private val openSmsSettingsHandler: () -> Unit
) : EdgeLinkActions {
    override fun onPointer(body: InputPointerBody) = delegate.onPointer(body)
    override fun onKey(body: InputKeyBody) = delegate.onKey(body)
    override fun onText(body: InputTextBody) = delegate.onText(body)
    override fun onPairDigit(digit: String) = delegate.onPairDigit(digit)
    override fun onPairBackspace() = delegate.onPairBackspace()
    override fun onStartPairing() = delegate.onStartPairing()
    override fun onConfirmPairing() = delegate.onConfirmPairing()
    override fun onReconnect() = delegate.onReconnect()
    override fun onAutoReconnectChange(enabled: Boolean) = delegate.onAutoReconnectChange(enabled)
    override fun onNotificationSyncChange(enabled: Boolean) = notificationSyncChangeHandler.invoke(enabled)
    override fun onOpenNotificationSettings() = openNotificationSettingsHandler.invoke()
    override fun onOpenRemoteInputSettings() = openRemoteInputSettingsHandler.invoke()
    override fun onOpenSmsSettings() = openSmsSettingsHandler.invoke()
}
