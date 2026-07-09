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

class AndroidKeepScreenOnWindow(context: Context) {
    private val appContext = context.applicationContext
    private val windowManager = appContext.getSystemService(WindowManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var requested = false
    private var attachedView: View? = null

    fun show() {
        requested = true
        mainHandler.post {
            if (!requested || attachedView != null) {
                return@post
            }
            if (!canDrawOverlays(appContext)) {
                EdgeLinkLog.warn("screen.android.keep_screen_window_skipped missing_overlay_permission")
                return@post
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
                EdgeLinkLog.info("screen.android.keep_screen_window_shown")
            }.onFailure { error ->
                EdgeLinkLog.warn("screen.android.keep_screen_window_show_failed", error)
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
        fun canDrawOverlays(context: Context): Boolean =
            Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(context.applicationContext)
    }
}
