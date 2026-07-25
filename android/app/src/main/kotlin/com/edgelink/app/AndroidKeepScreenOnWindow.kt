package com.edgelink.app

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class AndroidKeepScreenOnWindow(context: Context) {
    private val appContext = context.applicationContext
    private val windowManager = appContext.getSystemService(WindowManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val repairScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile
    private var requested = false
    private var attachedView: View? = null
    private var showAttempts = 0

    fun show() {
        requested = true
        showAttempts = 0
        mainHandler.post { tryShow() }
    }

    private fun tryShow() {
        if (!requested || attachedView != null) {
            return
        }
        if (!canDrawOverlays(appContext)) {
            showAttempts += 1
            if (showAttempts == 1) {
                EdgeLinkLog.warn("screen.android.keep_screen_window_skipped missing_overlay_permission")
                ensureOverlayPermissionAsync()
            }
            if (showAttempts > MAX_SHOW_ATTEMPTS) {
                EdgeLinkLog.warn("screen.android.keep_screen_window_gave_up attempts=$showAttempts")
                return
            }
            val delayMs = RETRY_DELAYS_MS.getOrElse(showAttempts - 1) { RETRY_DELAYS_MS.last() }
            EdgeLinkLog.info(
                "screen.android.keep_screen_window_retry attempt=$showAttempts delayMs=$delayMs"
            )
            mainHandler.postDelayed({ tryShow() }, delayMs)
            return
        }

        val view = View(appContext)
        val params = WindowManager.LayoutParams(
            1,
            1,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = 0
            alpha = 0.01f
            title = "EdgeLinkKeepScreenOn"
        }

        runCatching {
            windowManager.addView(view, params)
            attachedView = view
        }.onSuccess {
            EdgeLinkLog.info("screen.android.keep_screen_window_shown attempts=$showAttempts")
        }.onFailure { error ->
            EdgeLinkLog.warn("screen.android.keep_screen_window_show_failed", error)
        }
    }

    private fun ensureOverlayPermissionAsync() {
        if (!AndroidShizukuSupport.hasPermission()) {
            EdgeLinkLog.warn("screen.android.overlay_repair_skipped no_shizuku_permission")
            return
        }
        repairScope.launch {
            val result = runCatching {
                AndroidShizukuSupport.grantOverlayPermission(appContext)
            }.getOrElse { error ->
                ShizukuOperationResult(success = false, message = error.message.orEmpty())
            }
            if (result.success) {
                EdgeLinkLog.info("screen.android.overlay_repair_ok message=${result.message}")
            } else {
                EdgeLinkLog.warn("screen.android.overlay_repair_failed message=${result.message}")
            }
        }
    }

    fun hide() {
        requested = false
        mainHandler.post {
            val view = attachedView ?: return@post
            attachedView = null
            runCatching {
                windowManager.removeViewImmediate(view)
            }.onSuccess {
                EdgeLinkLog.info("screen.android.keep_screen_window_hidden")
            }.onFailure { error ->
                EdgeLinkLog.warn("screen.android.keep_screen_window_hide_failed", error)
            }
        }
    }

    companion object {
        private const val MAX_SHOW_ATTEMPTS = 12
        private val RETRY_DELAYS_MS = longArrayOf(2_000L, 5_000L, 10_000L, 20_000L, 30_000L, 60_000L, 120_000L)

        fun canDrawOverlays(context: Context): Boolean =
            Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(context.applicationContext)
    }
}
