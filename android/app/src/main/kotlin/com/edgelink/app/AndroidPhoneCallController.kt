package com.edgelink.app

import android.content.Context
import com.edgelink.core.PhoneActionBody
import com.edgelink.core.PhoneActionResultBody
import java.time.Instant

private const val PHONE_ACTION_DIAL = "dial"
private const val PHONE_ACTION_ANSWER = "answer"
private const val PHONE_ACTION_HANGUP = "hangup"

class AndroidPhoneCallController(context: Context) {
    private val appContext = context.applicationContext

    suspend fun handle(body: PhoneActionBody): PhoneActionResultBody {
        val now = Instant.now().epochSecond
        return when (body.action) {
            PHONE_ACTION_DIAL -> dial(body, now)
            PHONE_ACTION_ANSWER -> pressKey(body, "KEYCODE_HEADSETHOOK", now)
            PHONE_ACTION_HANGUP -> pressKey(body, "KEYCODE_ENDCALL", now)
            else -> PhoneActionResultBody(
                requestId = body.requestId,
                action = body.action,
                success = false,
                error = "unsupported_action",
                ts = now
            )
        }
    }

    private suspend fun dial(body: PhoneActionBody, now: Long): PhoneActionResultBody {
        val number = sanitizePhoneNumber(body.number.orEmpty())
            ?: return PhoneActionResultBody(
                requestId = body.requestId,
                action = body.action,
                success = false,
                error = "invalid_number",
                ts = now
            )
        val telUri = "tel:$number"
        return runCatching {
            AndroidShizukuSupport.placePhoneCall(appContext, telUri)
        }.fold(
            onSuccess = { result ->
                EdgeLinkLog.info(
                    "phone.android.action_result action=dial success=${result.success} numberFp=${AndroidSmsSync.fingerprint(number)}"
                )
                PhoneActionResultBody(
                    requestId = body.requestId,
                    action = body.action,
                    success = result.success,
                    error = result.message.takeUnless { result.success },
                    ts = now
                )
            },
            onFailure = { error ->
                EdgeLinkLog.error(
                    "phone.android.action_failed action=dial numberFp=${AndroidSmsSync.fingerprint(number)}",
                    error
                )
                PhoneActionResultBody(
                    requestId = body.requestId,
                    action = body.action,
                    success = false,
                    error = error::class.java.simpleName,
                    ts = now
                )
            }
        )
    }

    private suspend fun pressKey(body: PhoneActionBody, keyCode: String, now: Long): PhoneActionResultBody {
        return runCatching {
            AndroidShizukuSupport.pressPhoneKey(appContext, keyCode)
        }.fold(
            onSuccess = { result ->
                EdgeLinkLog.info("phone.android.action_result action=${body.action} success=${result.success}")
                PhoneActionResultBody(
                    requestId = body.requestId,
                    action = body.action,
                    success = result.success,
                    error = result.message.takeUnless { result.success },
                    ts = now
                )
            },
            onFailure = { error ->
                EdgeLinkLog.error("phone.android.action_failed action=${body.action}", error)
                PhoneActionResultBody(
                    requestId = body.requestId,
                    action = body.action,
                    success = false,
                    error = error::class.java.simpleName,
                    ts = now
                )
            }
        )
    }

    private fun sanitizePhoneNumber(raw: String): String? {
        val normalized = raw
            .trim()
            .filterNot { it.isWhitespace() || it == '-' || it == '(' || it == ')' }
        if (normalized.isBlank() || normalized.length > 32) {
            return null
        }
        val plusCount = normalized.count { it == '+' }
        if (plusCount > 1 || plusCount == 1 && !normalized.startsWith("+")) {
            return null
        }
        return normalized.takeIf { value ->
            value.all { it.isDigit() || it == '+' } && value.any { it.isDigit() }
        }
    }
}
