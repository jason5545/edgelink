package com.edgelink.app

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.security.MessageDigest
import java.time.Instant

object EdgeLinkLog {
    private const val TAG = "EdgeLink"
    private const val MAX_FILE_BYTES = 2L * 1024 * 1024
    private const val MAX_BACKUP_COUNT = 3
    private val writerThread = HandlerThread("EdgeLinkDiagnosticsLog").apply { start() }
    private val writerHandler = Handler(writerThread.looper)
    @Volatile
    private var logFile: File? = null
    private var writerFile: File? = null
    private var writer: BufferedWriter? = null

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

    private fun write(level: String, message: String) {
        val target = logFile ?: return
        val line = "${Instant.now()} $level $message\n"
        writerHandler.post {
            runCatching {
                rotateIfNeeded(target)
                val activeWriter = writerFor(target)
                activeWriter.write(line)
                activeWriter.flush()
            }
        }
    }

    private fun rotateIfNeeded(target: File) {
        if (!target.exists() || target.length() < MAX_FILE_BYTES) return
        writer?.close()
        writer = null
        writerFile = null
        val oldest = File(target.path + "." + MAX_BACKUP_COUNT)
        if (oldest.exists()) oldest.delete()
        for (index in MAX_BACKUP_COUNT - 1 downTo 1) {
            val source = File(target.path + "." + index)
            if (source.exists()) source.renameTo(File(target.path + "." + (index + 1)))
        }
        target.renameTo(File(target.path + ".1"))
    }

    private fun writerFor(target: File): BufferedWriter {
        if (writerFile != target || writer == null) {
            writer?.close()
            target.parentFile?.mkdirs()
            writer = BufferedWriter(FileWriter(target, true))
            writerFile = target
        }
        return checkNotNull(writer) { "Diagnostics writer was not initialized." }
    }

    private fun messageWithThrowable(message: String, throwable: Throwable?): String =
        if (throwable == null) {
            message
        } else {
            "$message error=${throwable::class.java.name}: ${throwable.message}"
        }
}
