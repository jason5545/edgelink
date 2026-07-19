package com.edgelink.app

import android.content.Context
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Surface
import java.io.ByteArrayOutputStream

class EdgeLinkXiaomiMirrorScreenConfigReporter(
    context: Context,
    private val onFrame: (ByteArray) -> Unit
) {
    private val appContext = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val displayManager = appContext.getSystemService(DisplayManager::class.java)
    @Volatile
    private var started = false
    @Volatile
    private var lastReportedKey = ""

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == Display.DEFAULT_DISPLAY) {
                reportCurrent("display_changed")
            }
        }
    }

    fun start() {
        if (started) {
            return
        }
        started = true
        runCatching {
            displayManager?.registerDisplayListener(displayListener, handler)
        }.onFailure { error ->
            EdgeLinkLog.warn("xiaomi.mirror.screen_config_listener_failed", error)
        }
        reportCurrent("start")
    }

    fun stop() {
        if (!started) {
            return
        }
        started = false
        runCatching {
            displayManager?.unregisterDisplayListener(displayListener)
        }
        lastReportedKey = ""
    }

    private fun reportCurrent(reason: String) {
        val display = displayManager?.getDisplay(Display.DEFAULT_DISPLAY) ?: return
        val size = Point()
        runCatching { display.getRealSize(size) }
        if (size.x <= 0 || size.y <= 0) {
            return
        }
        var width = size.x
        var height = size.y
        when (display.rotation) {
            Surface.ROTATION_90, Surface.ROTATION_270 -> {
                if (width < height) {
                    val tmp = width
                    width = height
                    height = tmp
                }
            }
            else -> {
                if (width > height) {
                    val tmp = width
                    width = height
                    height = tmp
                }
            }
        }
        val key = "$width x $height"
        if (key == lastReportedKey) {
            return
        }
        lastReportedKey = key
        val frame = buildOfficialScreenConfigurationFrame(width = width, height = height)
        EdgeLinkLog.info(
            "xiaomi.mirror.screen_config_reported reason=$reason size=${width}x$height rotation=${display.rotation}"
        )
        onFrame(frame)
    }

    companion object {
        private const val OFFICIAL_FRAME_TYPE: Byte = 5
        private const val CONFIGURATION_SIZE_CHANGED = 1

        fun buildOfficialScreenConfigurationFrame(width: Int, height: Int): ByteArray {
            val payload = ByteArrayOutputStream()
            writeVarintField(payload, fieldNumber = 2, value = 0)
            writeVarintField(payload, fieldNumber = 3, value = CONFIGURATION_SIZE_CHANGED)
            writeVarintField(payload, fieldNumber = 6, value = width)
            writeVarintField(payload, fieldNumber = 7, value = height)
            writeVarintField(payload, fieldNumber = 14, value = if (width > height) 1 else 0)
            writeVarintField(payload, fieldNumber = 23, value = width)
            writeVarintField(payload, fieldNumber = 24, value = height)
            val payloadBytes = payload.toByteArray()
            val frame = ByteArray(5 + payloadBytes.size)
            frame[0] = OFFICIAL_FRAME_TYPE
            val length = payloadBytes.size
            frame[1] = (length and 0xff).toByte()
            frame[2] = ((length shr 8) and 0xff).toByte()
            frame[3] = ((length shr 16) and 0xff).toByte()
            frame[4] = ((length shr 24) and 0xff).toByte()
            System.arraycopy(payloadBytes, 0, frame, 5, payloadBytes.size)
            return frame
        }

        private fun writeVarintField(out: ByteArrayOutputStream, fieldNumber: Int, value: Int) {
            writeVarint(out, (fieldNumber shl 3).toLong())
            writeVarint(out, value.toLong() and 0xffffffffL)
        }

        private fun writeVarint(out: ByteArrayOutputStream, input: Long) {
            var value = input
            while (true) {
                if (value and 0x7fL.inv() == 0L) {
                    out.write(value.toInt())
                    return
                }
                out.write(((value and 0x7f) or 0x80).toInt())
                value = value ushr 7
            }
        }
    }
}
