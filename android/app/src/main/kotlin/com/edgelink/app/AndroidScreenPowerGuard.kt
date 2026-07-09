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
private const val KEY_HAS_SNAPSHOT = "hasSnapshot"
private const val KEY_BRIGHTNESS_MODE = "brightnessMode"
private const val KEY_BRIGHTNESS = "brightness"

class AndroidScreenPowerGuard(context: Context) {
    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver
    private val prefs = appContext.getSharedPreferences(SCREEN_POWER_PREFS, Context.MODE_PRIVATE)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val powerManager = appContext.getSystemService(PowerManager::class.java)
    private var wakeLock: PowerManager.WakeLock? = null
    private var originalSettings: BrightnessSnapshot? = null
    private var sharingActive = false
    private val dimRunnable = Runnable { dimIfSharingActive() }

    init {
        restoreIfNeeded(reason = "startup")
    }

    fun onSharingStarted() {
        sharingActive = true
        acquireWakeLock()
        mainHandler.removeCallbacks(dimRunnable)
        mainHandler.postDelayed(dimRunnable, SCREEN_DIM_DELAY_MS)
        EdgeLinkLog.info("screen.android.power_guard_started canWrite=${canWriteSettings(appContext)}")
    }

    fun onSharingStopped() {
        sharingActive = false
        mainHandler.removeCallbacks(dimRunnable)
        restoreIfNeeded(reason = "sharing_stopped")
        releaseWakeLock()
    }

    private fun dimIfSharingActive() {
        if (!sharingActive) {
            return
        }
        if (!canWriteSettings(appContext)) {
            EdgeLinkLog.warn("screen.android.brightness_dim_skipped missing_write_settings")
            return
        }

        val snapshot = originalSettings ?: loadSnapshot() ?: readCurrentBrightnessSnapshot().also {
            saveSnapshot(it)
        }
        originalSettings = snapshot

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

    private fun restoreIfNeeded(reason: String) {
        val snapshot = originalSettings ?: loadSnapshot() ?: return
        if (!canWriteSettings(appContext)) {
            EdgeLinkLog.warn("screen.android.brightness_restore_skipped reason=$reason missing_write_settings")
            return
        }

        runCatching {
            Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS, snapshot.brightness)
            Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS_MODE, snapshot.mode)
        }.onSuccess {
            originalSettings = null
            clearSnapshot()
            EdgeLinkLog.info("screen.android.brightness_restored reason=$reason")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.brightness_restore_failed reason=$reason", error)
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

    private fun saveSnapshot(snapshot: BrightnessSnapshot) {
        prefs.edit()
            .putBoolean(KEY_HAS_SNAPSHOT, true)
            .putInt(KEY_BRIGHTNESS_MODE, snapshot.mode)
            .putInt(KEY_BRIGHTNESS, snapshot.brightness)
            .apply()
    }

    private fun loadSnapshot(): BrightnessSnapshot? {
        if (!prefs.getBoolean(KEY_HAS_SNAPSHOT, false)) {
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

    private fun clearSnapshot() {
        prefs.edit().clear().apply()
    }

    private data class BrightnessSnapshot(
        val mode: Int,
        val brightness: Int
    )

    companion object {
        fun canWriteSettings(context: Context): Boolean =
            Build.VERSION.SDK_INT < 23 || Settings.System.canWrite(context.applicationContext)
    }
}
