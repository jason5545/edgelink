package com.edgelink.app

import android.content.Context
import android.util.Log
import java.io.File
import java.security.MessageDigest
import java.time.Instant

object EdgeLinkLog {
    private const val TAG = "EdgeLink"
    @Volatile
    private var logFile: File? = null

    fun configure(context: Context) {
        logFile = File(context.filesDir, "diagnostics.log")
        info("diagnostics.android.configured path=${logFile?.absolutePath}")
    }

    fun info(message: String) {
        Log.i(TAG, message)
        write("INFO", message)
    }

    fun warn(message: String, throwable: Throwable? = null) {
        Log.w(TAG, message, throwable)
        write("WARN", messageWithThrowable(message, throwable))
    }

    fun error(message: String, throwable: Throwable? = null) {
        Log.e(TAG, message, throwable)
        write("ERROR", messageWithThrowable(message, throwable))
    }

    fun fingerprint(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.take(6).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    @Synchronized
    private fun write(level: String, message: String) {
        val target = logFile ?: return
        runCatching {
            target.parentFile?.mkdirs()
            target.appendText("${Instant.now()} $level $message\n")
        }
    }

    private fun messageWithThrowable(message: String, throwable: Throwable?): String =
        if (throwable == null) {
            message
        } else {
            "$message error=${throwable::class.java.name}: ${throwable.message}"
        }
}
