package com.edgelink.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings

private const val SCREEN_SHARE_PROTECTION_PREFS = "edgelink_screen_share_protection"
private const val KEY_HAS_SNAPSHOT = "hasSnapshot"
private const val KEY_GLOBAL_DISABLE_PROTECTIONS = "globalDisableProtections"
private const val KEY_XIAOMI_PRIVATE_MODE = "xiaomiPrivateMode"

class AndroidScreenShareProtectionGuard(context: Context) {
    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver
    private val prefs = appContext.getSharedPreferences(SCREEN_SHARE_PROTECTION_PREFS, Context.MODE_PRIVATE)
    private var originalSettings: ProtectionSnapshot? = null

    init {
        restoreIfNeeded(reason = "startup")
    }

    fun onSharingStarted() {
        if (!canWriteProtectedSettings(appContext)) {
            EdgeLinkLog.warn("screen.android.protection_override_skipped missing_write_secure_settings")
            return
        }
        val snapshot = originalSettings ?: loadSnapshot() ?: readSnapshot().also(::saveSnapshot)
        originalSettings = snapshot

        runCatching {
            Settings.Global.putInt(
                resolver,
                GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS,
                1
            )
            Settings.Secure.putInt(
                resolver,
                XIAOMI_SCREEN_PROJECT_PRIVATE_ON,
                0
            )
        }.onSuccess {
            EdgeLinkLog.info("screen.android.protection_override_enabled")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.protection_override_failed", error)
        }
    }

    fun onSharingStopped() {
        restoreIfNeeded(reason = "sharing_stopped")
    }

    private fun restoreIfNeeded(reason: String) {
        val snapshot = originalSettings ?: loadSnapshot() ?: return
        if (!canWriteProtectedSettings(appContext)) {
            EdgeLinkLog.warn("screen.android.protection_restore_skipped reason=$reason missing_write_secure_settings")
            return
        }

        runCatching {
            Settings.Global.putInt(
                resolver,
                GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS,
                snapshot.globalDisableProtections
            )
            Settings.Secure.putInt(
                resolver,
                XIAOMI_SCREEN_PROJECT_PRIVATE_ON,
                snapshot.xiaomiPrivateMode
            )
        }.onSuccess {
            originalSettings = null
            clearSnapshot()
            EdgeLinkLog.info("screen.android.protection_restored reason=$reason")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.protection_restore_failed reason=$reason", error)
        }
    }

    private fun readSnapshot(): ProtectionSnapshot =
        ProtectionSnapshot(
            globalDisableProtections = Settings.Global.getInt(
                resolver,
                GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS,
                0
            ),
            xiaomiPrivateMode = Settings.Secure.getInt(
                resolver,
                XIAOMI_SCREEN_PROJECT_PRIVATE_ON,
                1
            )
        )

    private fun saveSnapshot(snapshot: ProtectionSnapshot) {
        prefs.edit()
            .putBoolean(KEY_HAS_SNAPSHOT, true)
            .putInt(KEY_GLOBAL_DISABLE_PROTECTIONS, snapshot.globalDisableProtections)
            .putInt(KEY_XIAOMI_PRIVATE_MODE, snapshot.xiaomiPrivateMode)
            .apply()
    }

    private fun loadSnapshot(): ProtectionSnapshot? {
        if (!prefs.getBoolean(KEY_HAS_SNAPSHOT, false)) {
            return null
        }
        return ProtectionSnapshot(
            globalDisableProtections = prefs.getInt(KEY_GLOBAL_DISABLE_PROTECTIONS, 0),
            xiaomiPrivateMode = prefs.getInt(KEY_XIAOMI_PRIVATE_MODE, 1)
        )
    }

    private fun clearSnapshot() {
        prefs.edit().clear().apply()
    }

    private data class ProtectionSnapshot(
        val globalDisableProtections: Int,
        val xiaomiPrivateMode: Int
    )

    companion object {
        private const val GLOBAL_DISABLE_SCREEN_SHARE_PROTECTIONS =
            "disable_screen_share_protections_for_apps_and_notifications"
        private const val XIAOMI_SCREEN_PROJECT_PRIVATE_ON = "screen_project_private_on"

        fun canWriteProtectedSettings(context: Context): Boolean =
            context.applicationContext.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
                PackageManager.PERMISSION_GRANTED
    }
}
