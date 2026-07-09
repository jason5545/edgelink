@file:Suppress("DEPRECATION")

package com.edgelink.app

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings

private const val SCREEN_DIM_DELAY_MS = 5_000L
private const val SCREEN_POWER_PREFS = "edgelink_screen_power"
private const val KEY_LEGACY_HAS_SNAPSHOT = "hasSnapshot"
private const val KEY_HAS_BRIGHTNESS_SNAPSHOT = "hasBrightnessSnapshot"
private const val KEY_BRIGHTNESS_MODE = "brightnessMode"
private const val KEY_BRIGHTNESS = "brightness"
private const val KEY_HAS_SCREENSAVER_SNAPSHOT = "hasScreensaverSnapshot"
private const val KEY_SCREENSAVER_ENABLED = "screensaverEnabled"
private const val SECURE_SCREENSAVER_ENABLED = "screensaver_enabled"

class AndroidScreenPowerGuard(context: Context) {
    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver
    private val prefs = appContext.getSharedPreferences(SCREEN_POWER_PREFS, Context.MODE_PRIVATE)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val powerManager = appContext.getSystemService(PowerManager::class.java)
    private var wakeLock: PowerManager.WakeLock? = null
    private var originalBrightnessSettings: BrightnessSnapshot? = null
    private var originalScreensaverSettings: ScreensaverSnapshot? = null
    private val keepScreenOnWindow = AndroidKeepScreenOnWindow(appContext)
    private var sharingActive = false
    private val dimRunnable = Runnable { dimIfSharingActive() }

    init {
        restoreBrightnessIfNeeded(reason = "startup")
        restoreScreensaverIfNeeded(reason = "startup")
    }

    fun onSharingStarted() {
        sharingActive = true
        acquireWakeLock()
        keepScreenOnWindow.show()
        ScreenPowerForegroundService.start(appContext)
        disableScreensaver()
        mainHandler.removeCallbacks(dimRunnable)
        mainHandler.postDelayed(dimRunnable, SCREEN_DIM_DELAY_MS)
        EdgeLinkLog.info("screen.android.power_guard_started canWrite=${canWriteSettings(appContext)}")
    }

    fun onSharingStopped() {
        sharingActive = false
        mainHandler.removeCallbacks(dimRunnable)
        restoreBrightnessIfNeeded(reason = "sharing_stopped")
        restoreScreensaverIfNeeded(reason = "sharing_stopped")
        keepScreenOnWindow.hide()
        releaseWakeLock()
        ScreenPowerForegroundService.stop(appContext)
    }

    private fun dimIfSharingActive() {
        if (!sharingActive) {
            return
        }
        if (!canWriteSettings(appContext)) {
            EdgeLinkLog.warn("screen.android.brightness_dim_skipped missing_write_settings")
            return
        }

        val snapshot = originalBrightnessSettings ?: loadBrightnessSnapshot() ?: readCurrentBrightnessSnapshot().also {
            saveBrightnessSnapshot(it)
        }
        originalBrightnessSettings = snapshot

        runCatching {
            Settings.System.putInt(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS_MODE,
                Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL
            )
            Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS, 0)
        }.onSuccess {
            EdgeLinkLog.info("screen.android.brightness_dimmed delayMs=$SCREEN_DIM_DELAY_MS")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.brightness_dim_failed", error)
        }
    }

    private fun restoreBrightnessIfNeeded(reason: String) {
        val snapshot = originalBrightnessSettings ?: loadBrightnessSnapshot() ?: return
        if (!canWriteSettings(appContext)) {
            EdgeLinkLog.warn("screen.android.brightness_restore_skipped reason=$reason missing_write_settings")
            return
        }

        runCatching {
            Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS, snapshot.brightness)
            Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS_MODE, snapshot.mode)
        }.onSuccess {
            originalBrightnessSettings = null
            clearBrightnessSnapshot()
            EdgeLinkLog.info("screen.android.brightness_restored reason=$reason")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.brightness_restore_failed reason=$reason", error)
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

        runCatching {
            Settings.Secure.putInt(resolver, SECURE_SCREENSAVER_ENABLED, snapshot.enabled)
        }.onSuccess {
            originalScreensaverSettings = null
            clearScreensaverSnapshot()
            EdgeLinkLog.info("screen.android.screensaver_restored reason=$reason enabled=${snapshot.enabled}")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.screensaver_restore_failed reason=$reason", error)
        }
    }

    private fun acquireWakeLock() {
        val existing = wakeLock
        if (existing?.isHeld == true) {
            return
        }
        wakeLock = powerManager.newWakeLock(
            PowerManager.SCREEN_DIM_WAKE_LOCK,
            "EdgeLink:ScreenShare"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
        EdgeLinkLog.info("screen.android.wake_lock_acquired")
    }

    private fun releaseWakeLock() {
        val lock = wakeLock
        wakeLock = null
        if (lock?.isHeld == true) {
            runCatching { lock.release() }
                .onFailure { error -> EdgeLinkLog.warn("screen.android.wake_lock_release_failed", error) }
            EdgeLinkLog.info("screen.android.wake_lock_released")
        }
    }

    private fun readCurrentBrightnessSnapshot(): BrightnessSnapshot =
        BrightnessSnapshot(
            mode = Settings.System.getInt(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS_MODE,
                Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL
            ),
            brightness = Settings.System.getInt(resolver, Settings.System.SCREEN_BRIGHTNESS, 125)
        )

    private fun saveBrightnessSnapshot(snapshot: BrightnessSnapshot) {
        prefs.edit()
            .putBoolean(KEY_HAS_BRIGHTNESS_SNAPSHOT, true)
            .putInt(KEY_BRIGHTNESS_MODE, snapshot.mode)
            .putInt(KEY_BRIGHTNESS, snapshot.brightness)
            .apply()
    }

    private fun loadBrightnessSnapshot(): BrightnessSnapshot? {
        if (
            !prefs.getBoolean(KEY_HAS_BRIGHTNESS_SNAPSHOT, false) &&
            !prefs.getBoolean(KEY_LEGACY_HAS_SNAPSHOT, false)
        ) {
            return null
        }
        return BrightnessSnapshot(
            mode = prefs.getInt(
                KEY_BRIGHTNESS_MODE,
                Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL
            ),
            brightness = prefs.getInt(KEY_BRIGHTNESS, 125)
        )
    }

    private fun clearBrightnessSnapshot() {
        prefs.edit()
            .remove(KEY_HAS_BRIGHTNESS_SNAPSHOT)
            .remove(KEY_LEGACY_HAS_SNAPSHOT)
            .remove(KEY_BRIGHTNESS_MODE)
            .remove(KEY_BRIGHTNESS)
            .apply()
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

    private data class BrightnessSnapshot(
        val mode: Int,
        val brightness: Int
    )

    private data class ScreensaverSnapshot(
        val enabled: Int
    )

    companion object {
        fun canWriteSettings(context: Context): Boolean =
            Build.VERSION.SDK_INT < 23 || Settings.System.canWrite(context.applicationContext)

        fun hasRequiredScreenPowerAccess(context: Context): Boolean =
            canWriteSettings(context) && AndroidKeepScreenOnWindow.canDrawOverlays(context)
    }
}
