package com.edgelink.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import com.edgelink.core.CtrlGlobalBody
import com.edgelink.core.CtrlKeyBody
import com.edgelink.core.CtrlPointerBody
import com.edgelink.core.CtrlTextBody
import java.util.ArrayDeque
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

private const val TOUCH_SEGMENT_MS = 24L
private const val TAP_SEGMENT_MS = 40L
private const val LONG_PRESS_MS = 620L
private const val WHEEL_GESTURE_MS = 140L

class RemoteInputService : AccessibilityService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingStrokes = ArrayDeque<GestureDescription.StrokeDescription>()
    private var gestureInFlight = false
    private var activeStroke: GestureDescription.StrokeDescription? = null
    private var lastX = 0f
    private var lastY = 0f

    override fun onServiceConnected() {
        super.onServiceConnected()
        activeService = this
        serviceInfo = serviceInfo.apply {
            if (Build.VERSION.SDK_INT >= 33) {
                flags = flags or AccessibilityServiceInfo.FLAG_INPUT_METHOD_EDITOR
            }
        }
        EdgeLinkLog.configure(applicationContext)
        EdgeLinkLog.info("remote_input.android.connected")
    }

    override fun onDestroy() {
        if (activeService === this) {
            activeService = null
        }
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() {
        EdgeLinkLog.info("remote_input.android.interrupt")
    }

    private fun handlePointer(body: CtrlPointerBody) {
        when (body.action) {
            "down" -> beginStroke(body.x.toFloat(), body.y.toFloat())
            "move" -> continueStroke(body.x.toFloat(), body.y.toFloat(), willContinue = true)
            "up" -> continueStroke(body.x.toFloat(), body.y.toFloat(), willContinue = false)
            "rightUp" -> longPress(body.x.toFloat(), body.y.toFloat())
            "wheel" -> wheel(body.x.toFloat(), body.y.toFloat(), body.wheelDy ?: 0)
            else -> EdgeLinkLog.warn("remote_input.android.pointer_ignored action=${body.action}")
        }
    }

    private fun handleGlobal(body: CtrlGlobalBody) {
        val action = when (body.action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "power" -> GLOBAL_ACTION_POWER_DIALOG
            else -> null
        }
        if (action == null) {
            EdgeLinkLog.warn("remote_input.android.global_ignored action=${body.action}")
            return
        }
        performGlobalAction(action)
    }

    private fun handleText(body: CtrlTextBody) {
        if (body.text.isEmpty()) {
            return
        }
        if (Build.VERSION.SDK_INT >= 33) {
            val connection = inputMethod?.currentInputConnection
            if (connection != null) {
                connection.commitText(body.text, 1, null)
                return
            }
        }
        EdgeLinkLog.warn("remote_input.android.text_ignored no_input_connection")
    }

    private fun handleKey(body: CtrlKeyBody) {
        if (body.key.equals("escape", ignoreCase = true)) {
            if (body.down) {
                performGlobalAction(GLOBAL_ACTION_BACK)
            }
            return
        }
        if (Build.VERSION.SDK_INT < 33) {
            EdgeLinkLog.warn("remote_input.android.key_ignored api=${Build.VERSION.SDK_INT}")
            return
        }
        val keyCode = androidKeyCode(body.key) ?: run {
            EdgeLinkLog.warn("remote_input.android.key_ignored key=${body.key}")
            return
        }
        val connection = inputMethod?.currentInputConnection
        if (connection == null) {
            EdgeLinkLog.warn("remote_input.android.key_ignored no_input_connection key=${body.key}")
            return
        }
        val now = SystemClock.uptimeMillis()
        val action = if (body.down) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP
        connection.sendKeyEvent(KeyEvent(now, now, action, keyCode, 0, metaState(body.mods)))
    }

    private fun beginStroke(x: Float, y: Float) {
        activeStroke = null
        pendingStrokes.clear()
        lastX = cleanCoordinate(x)
        lastY = cleanCoordinate(y)
        val path = Path().apply { moveTo(lastX, lastY) }
        val stroke = GestureDescription.StrokeDescription(path, 0, TAP_SEGMENT_MS, true)
        activeStroke = stroke
        enqueueStroke(stroke)
    }

    private fun continueStroke(x: Float, y: Float, willContinue: Boolean) {
        val cleanX = cleanCoordinate(x)
        val cleanY = cleanCoordinate(y)
        val current = activeStroke ?: run {
            beginStroke(cleanX, cleanY)
            activeStroke ?: return
        }
        val path = Path().apply {
            moveTo(lastX, lastY)
            lineTo(cleanX, cleanY)
        }
        val stroke = current.continueStroke(path, 0, TOUCH_SEGMENT_MS, willContinue)
        activeStroke = if (willContinue) stroke else null
        lastX = cleanX
        lastY = cleanY
        enqueueStroke(stroke)
    }

    private fun longPress(x: Float, y: Float) {
        finishActiveStroke(cleanCoordinate(x), cleanCoordinate(y))
        val path = Path().apply { moveTo(cleanCoordinate(x), cleanCoordinate(y)) }
        enqueueStroke(GestureDescription.StrokeDescription(path, 0, LONG_PRESS_MS, false))
    }

    private fun wheel(x: Float, y: Float, wheelDy: Int) {
        if (wheelDy == 0) {
            return
        }
        finishActiveStroke(cleanCoordinate(x), cleanCoordinate(y))
        val distance = min(720f, max(96f, abs(wheelDy).toFloat() * 2.6f))
        val direction = if (wheelDy > 0) 1f else -1f
        val startX = cleanCoordinate(x)
        val startY = cleanCoordinate(y)
        val endY = cleanCoordinate(startY + distance * direction)
        val path = Path().apply {
            moveTo(startX, startY)
            lineTo(startX, endY)
        }
        enqueueStroke(GestureDescription.StrokeDescription(path, 0, WHEEL_GESTURE_MS, false))
    }

    private fun finishActiveStroke(x: Float, y: Float) {
        if (activeStroke != null) {
            continueStroke(x, y, willContinue = false)
        }
    }

    private fun enqueueStroke(stroke: GestureDescription.StrokeDescription) {
        pendingStrokes.add(stroke)
        dispatchNextStroke()
    }

    private fun dispatchNextStroke() {
        if (gestureInFlight) {
            return
        }
        val stroke = pendingStrokes.poll() ?: return
        gestureInFlight = true
        val dispatched = dispatchGesture(
            GestureDescription.Builder().addStroke(stroke).build(),
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    gestureInFlight = false
                    dispatchNextStroke()
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    gestureInFlight = false
                    EdgeLinkLog.warn("remote_input.android.gesture_cancelled")
                    dispatchNextStroke()
                }
            },
            mainHandler
        )
        if (!dispatched) {
            gestureInFlight = false
            EdgeLinkLog.warn("remote_input.android.gesture_dispatch_failed")
            dispatchNextStroke()
        }
    }

    private fun cleanCoordinate(value: Float): Float = max(0f, value)

    companion object {
        @Volatile
        private var activeService: RemoteInputService? = null

        fun isEnabled(context: Context): Boolean {
            val componentName = ComponentName(context, RemoteInputService::class.java)
            val enabledServices = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ).orEmpty()
            return enabledServices.split(':').any { it.equals(componentName.flattenToString(), ignoreCase = true) }
        }

        fun openSettings(context: Context) {
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }

        fun dispatchPointer(body: CtrlPointerBody) = postToActive("pointer") { handlePointer(body) }
        fun dispatchGlobal(body: CtrlGlobalBody) = postToActive("global") { handleGlobal(body) }
        fun dispatchText(body: CtrlTextBody) = postToActive("text") { handleText(body) }
        fun dispatchKey(body: CtrlKeyBody) = postToActive("key") { handleKey(body) }

        private fun postToActive(name: String, block: RemoteInputService.() -> Unit) {
            val service = activeService
            if (service == null) {
                EdgeLinkLog.warn("remote_input.android.${name}_ignored service_inactive")
                return
            }
            service.mainHandler.post { service.block() }
        }
    }
}

private fun androidKeyCode(key: String): Int? =
    when (key.lowercase()) {
        "backspace", "delete" -> KeyEvent.KEYCODE_DEL
        "forwarddelete" -> KeyEvent.KEYCODE_FORWARD_DEL
        "tab" -> KeyEvent.KEYCODE_TAB
        "return", "enter" -> KeyEvent.KEYCODE_ENTER
        "space" -> KeyEvent.KEYCODE_SPACE
        "left" -> KeyEvent.KEYCODE_DPAD_LEFT
        "right" -> KeyEvent.KEYCODE_DPAD_RIGHT
        "up" -> KeyEvent.KEYCODE_DPAD_UP
        "down" -> KeyEvent.KEYCODE_DPAD_DOWN
        else -> key.singleOrNull()?.let { char ->
            when (char.lowercaseChar()) {
                in 'a'..'z' -> KeyEvent.KEYCODE_A + (char.lowercaseChar() - 'a')
                in '0'..'9' -> KeyEvent.KEYCODE_0 + (char - '0')
                else -> null
            }
        }
    }

private fun metaState(mods: List<String>): Int =
    mods.fold(0) { partial, mod ->
        partial or when (mod.lowercase()) {
            "shift" -> KeyEvent.META_SHIFT_ON
            "ctrl" -> KeyEvent.META_CTRL_ON
            "alt", "option" -> KeyEvent.META_ALT_ON
            "cmd", "meta" -> KeyEvent.META_META_ON
            else -> 0
        }
    }
