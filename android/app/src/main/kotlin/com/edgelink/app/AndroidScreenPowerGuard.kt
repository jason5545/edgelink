package com.edgelink.app

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

// The guard only disables the screensaver while the WebRTC screen share is
// active. Brightness dimming and the Xiaomi mirror keep-awake provider were
// removed: the mirror runs the official Hangup virtual-display path where the
// physical screen state does not affect the encoder, so fighting brightness
// and wake locks is no longer needed.
private const val SCREEN_POWER_PREFS = "edgelink_screen_power"
private const val KEY_HAS_SCREENSAVER_SNAPSHOT = "hasScreensaverSnapshot"
private const val KEY_SCREENSAVER_ENABLED = "screensaverEnabled"
private const val SECURE_SCREENSAVER_ENABLED = "screensaver_enabled"

// Legacy keys written by the retired brightness-dim logic; restored once on
// stop so user settings survive the upgrade, then cleared.
private const val KEY_LEGACY_HAS_SNAPSHOT = "hasSnapshot"
private const val KEY_HAS_BRIGHTNESS_SNAPSHOT = "hasBrightnessSnapshot"
private const val KEY_BRIGHTNESS_MODE = "brightnessMode"
private const val KEY_BRIGHTNESS = "brightness"

class AndroidScreenPowerGuard(context: Context) {
    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver
    private val prefs = appContext.getSharedPreferences(SCREEN_POWER_PREFS, Context.MODE_PRIVATE)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val secureSettingsScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var originalScreensaverSettings: ScreensaverSnapshot? = null

    init {
        restoreScreensaverIfNeeded(reason = "startup")
    }

    fun onSharingStarted() {
        ScreenPowerForegroundService.start(appContext)
        disableScreensaver()
        EdgeLinkLog.info("screen.android.power_guard_started")
    }

    fun onSharingStopped() {
        mainHandler.removeCallbacksAndMessages(null)
        restoreLegacyBrightnessIfNeeded(reason = "sharing_stopped")
        restoreScreensaverIfNeeded(reason = "sharing_stopped")
        ScreenPowerForegroundService.stop(appContext)
    }

    private fun restoreLegacyBrightnessIfNeeded(reason: String) {
        val hasSnapshot = prefs.getBoolean(KEY_HAS_BRIGHTNESS_SNAPSHOT, false) ||
            prefs.getBoolean(KEY_LEGACY_HAS_SNAPSHOT, false)
        if (!hasSnapshot) {
            return
        }
        if (!canWriteSettings(appContext)) {
            EdgeLinkLog.warn("screen.android.brightness_restore_skipped reason=$reason missing_write_settings")
            return
        }
        val mode = prefs.getInt(KEY_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
        val brightness = prefs.getInt(KEY_BRIGHTNESS, 125)
        runCatching {
            Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS, brightness)
            Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS_MODE, mode)
        }.onSuccess {
            prefs.edit()
                .remove(KEY_HAS_BRIGHTNESS_SNAPSHOT)
                .remove(KEY_LEGACY_HAS_SNAPSHOT)
                .remove(KEY_BRIGHTNESS_MODE)
                .remove(KEY_BRIGHTNESS)
                .apply()
            EdgeLinkLog.info("screen.android.brightness_restored reason=$reason")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.brightness_restore_failed", error)
        }
    }

    private fun disableScreensaver() {
        if (!AndroidProtectedSettings.canWriteSecureSettings(appContext)) {
            EdgeLinkLog.warn("screen.android.screensaver_disable_skipped missing_write_secure_settings")
            return
        }
        val snapshot = originalScreensaverSettings
            ?: loadScreensaverSnapshot()
            ?: readCurrentScreensaverSnapshot().also(::saveScreensaverSnapshot)
        originalScreensaverSettings = snapshot

        if (!AndroidProtectedSettings.canWriteSecureSettingsDirectly(appContext)) {
            putScreensaverWithShizuku(value = 0, reason = "disable")
            return
        }

        runCatching {
            Settings.Secure.putInt(resolver, SECURE_SCREENSAVER_ENABLED, 0)
        }.onSuccess {
            EdgeLinkLog.info("screen.android.screensaver_disabled")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.screensaver_disable_failed", error)
        }
    }

    private fun restoreScreensaverIfNeeded(reason: String) {
        val snapshot = originalScreensaverSettings ?: loadScreensaverSnapshot() ?: return
        if (!AndroidProtectedSettings.canWriteSecureSettings(appContext)) {
            EdgeLinkLog.warn("screen.android.screensaver_restore_skipped reason=$reason missing_write_secure_settings")
            return
        }

        if (!AndroidProtectedSettings.canWriteSecureSettingsDirectly(appContext)) {
            putScreensaverWithShizuku(value = snapshot.enabled, reason = "restore:$reason") {
                originalScreensaverSettings = null
                clearScreensaverSnapshot()
            }
            return
        }

        runCatching {
            Settings.Secure.putInt(resolver, SECURE_SCREENSAVER_ENABLED, snapshot.enabled)
        }.onSuccess {
            originalScreensaverSettings = null
            clearScreensaverSnapshot()
            EdgeLinkLog.info("screen.android.screensaver_restored reason=$reason enabled=${snapshot.enabled}")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.screensaver_restore_failed", error)
        }
    }

    private fun putScreensaverWithShizuku(
        value: Int,
        reason: String,
        onSuccess: () -> Unit = {}
    ) {
        secureSettingsScope.launch {
            val result = runCatching {
                AndroidShizukuSupport.putSecureInt(appContext, SECURE_SCREENSAVER_ENABLED, value)
            }.getOrElse { error ->
                ShizukuOperationResult(success = false, message = error.message.orEmpty())
            }
            if (result.success) {
                EdgeLinkLog.info("screen.android.screensaver_shizuku_written reason=$reason value=$value")
                onSuccess()
            } else {
                EdgeLinkLog.warn("screen.android.screensaver_shizuku_failed reason=$reason message=${result.message}")
            }
        }
    }

    private fun readCurrentScreensaverSnapshot(): ScreensaverSnapshot =
        ScreensaverSnapshot(
            enabled = Settings.Secure.getInt(resolver, SECURE_SCREENSAVER_ENABLED, 0)
        )

    private fun saveScreensaverSnapshot(snapshot: ScreensaverSnapshot) {
        prefs.edit()
            .putBoolean(KEY_HAS_SCREENSAVER_SNAPSHOT, true)
            .putInt(KEY_SCREENSAVER_ENABLED, snapshot.enabled)
            .apply()
    }

    private fun loadScreensaverSnapshot(): ScreensaverSnapshot? {
        if (!prefs.getBoolean(KEY_HAS_SCREENSAVER_SNAPSHOT, false)) {
            return null
        }
        return ScreensaverSnapshot(
            enabled = prefs.getInt(KEY_SCREENSAVER_ENABLED, 0)
        )
    }

    private fun clearScreensaverSnapshot() {
        prefs.edit()
            .remove(KEY_HAS_SCREENSAVER_SNAPSHOT)
            .remove(KEY_SCREENSAVER_ENABLED)
            .apply()
    }

    private data class ScreensaverSnapshot(
        val enabled: Int
    )

    companion object {
        fun canWriteSettings(context: Context): Boolean =
            Build.VERSION.SDK_INT < 23 || Settings.System.canWrite(context.applicationContext)
    }
}
