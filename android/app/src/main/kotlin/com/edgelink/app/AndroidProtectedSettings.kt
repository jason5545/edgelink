package com.edgelink.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager

object AndroidProtectedSettings {
    fun canWriteSecureSettings(context: Context): Boolean =
        context.applicationContext.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED
}
