package com.edgelink.app

import android.app.Activity
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle

private const val SCREEN_CAPTURE_REQUEST_CODE = 4201
private const val RECORD_AUDIO_REQUEST_CODE = 4202

class ScreenCapturePermissionActivity : Activity() {
    private var launched = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) {
            launched = savedInstanceState.getBoolean(KEY_LAUNCHED, false)
        }
        if (!launched) {
            launched = true
            if (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), RECORD_AUDIO_REQUEST_CODE)
            } else {
                launchScreenCapturePermission()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RECORD_AUDIO_REQUEST_CODE) {
            if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
                EdgeLinkLog.warn("screen.android.audio_permission_denied video_only=true")
            }
            launchScreenCapturePermission()
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

    @Suppress("DEPRECATION")
    private fun launchScreenCapturePermission() {
        val manager = getSystemService(MediaProjectionManager::class.java)
        startActivityForResult(manager.createScreenCaptureIntent(), SCREEN_CAPTURE_REQUEST_CODE)
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
