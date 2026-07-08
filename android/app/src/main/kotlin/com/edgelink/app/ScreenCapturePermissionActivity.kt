package com.edgelink.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle

private const val SCREEN_CAPTURE_REQUEST_CODE = 4201

class ScreenCapturePermissionActivity : Activity() {
    private var launched = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) {
            launched = savedInstanceState.getBoolean(KEY_LAUNCHED, false)
        }
        if (!launched) {
            launched = true
            val manager = getSystemService(MediaProjectionManager::class.java)
            startActivityForResult(manager.createScreenCaptureIntent(), SCREEN_CAPTURE_REQUEST_CODE)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(KEY_LAUNCHED, launched)
        super.onSaveInstanceState(outState)
    }

    @Deprecated("Deprecated by Android framework; Activity Result API adds no value for this transparent bridge.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SCREEN_CAPTURE_REQUEST_CODE && resultCode == RESULT_OK && data != null) {
            ScreenProjectionForegroundService.startProjection(applicationContext, resultCode, data)
        } else {
            EdgeLinkRuntimeHolder.existing()?.onScreenCapturePermissionDenied()
        }
        finish()
        overridePendingTransition(0, 0)
    }

    companion object {
        private const val KEY_LAUNCHED = "launched"

        fun start(context: Context) {
            val intent = Intent(context, ScreenCapturePermissionActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
            context.startActivity(intent)
        }
    }
}
