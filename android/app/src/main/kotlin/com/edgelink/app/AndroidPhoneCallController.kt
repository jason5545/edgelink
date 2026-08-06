package com.edgelink.app

import android.content.Context
import com.edgelink.core.PhoneActionBody
import com.edgelink.core.PhoneActionResultBody
import java.time.Instant

private const val PHONE_ACTION_DIAL = "dial"
private const val PHONE_ACTION_ANSWER = "answer"
private const val PHONE_ACTION_HANGUP = "hangup"
private const val PHONE_ACTION_DTMF = "dtmf"

class AndroidPhoneCallController(context: Context) {
    private val appContext = context.applicationContext

    suspend fun handle(body: PhoneActionBody): PhoneActionResultBody {
        val now = Instant.now().epochSecond
        return when (body.action) {
            PHONE_ACTION_DIAL -> dial(body, now)
            PHONE_ACTION_ANSWER -> pressKey(body, "KEYCODE_HEADSETHOOK", now)
            PHONE_ACTION_HANGUP -> pressKey(body, "KEYCODE_ENDCALL", now)
            PHONE_ACTION_DTMF -> sendDtmf(body, now)
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
        if (body.skipDial == true) {
            // The native Xiaomi relay path already placed the call with
            // telecomm.EXTRA_CALL_RELAYED; we only attach the audio bridge.
            EdgeLinkLog.info(
                "phone.android.action_skip_dial numberFp=${AndroidSmsSync.fingerprint(number)}"
            )
            return PhoneActionResultBody(
                requestId = body.requestId,
                action = body.action,
                success = true,
                error = null,
                ts = now
            )
        }
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
                    error = error.phoneActionErrorMessage(),
                    ts = now
                )
            }
        )
    }

    private suspend fun sendDtmf(body: PhoneActionBody, now: Long): PhoneActionResultBody {
        val sequence = PhoneDtmfKeyMapper.sanitizeSequence(body.number.orEmpty())
            ?: return PhoneActionResultBody(
                requestId = body.requestId,
                action = body.action,
                success = false,
                error = "invalid_dtmf",
                ts = now
            )
        return runCatching {
            AndroidShizukuSupport.sendPhoneDtmfSequence(appContext, sequence)
        }.fold(
            onSuccess = { result ->
                EdgeLinkLog.info(
                    "phone.android.action_result action=dtmf success=${result.success} " +
                        "sequenceFp=${AndroidSmsSync.fingerprint(sequence)}"
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
                    "phone.android.action_failed action=dtmf sequenceFp=${AndroidSmsSync.fingerprint(sequence)}",
                    error
                )
                PhoneActionResultBody(
                    requestId = body.requestId,
                    action = body.action,
                    success = false,
                    error = error.phoneActionErrorMessage(),
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
                    error = error.phoneActionErrorMessage(),
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

    private fun Throwable.phoneActionErrorMessage(): String {
        val detail = message
            ?.replace(Regex("\\s+"), " ")
            ?.trim()
            ?.takeIf { it.isNotBlank() }
            ?.take(120)
        return listOfNotNull(this::class.java.simpleName, detail)
            .joinToString(":")
    }
}

internal object PhoneDtmfKeyMapper {
    fun sanitizeSequence(raw: String): String? {
        val builder = StringBuilder()
        for (char in raw.trim()) {
            if (char.isIgnoredSeparator()) {
                continue
            }
            builder.append(normalizeChar(char) ?: return null)
        }
        val normalized = builder.toString()
        if (normalized.isBlank() || normalized.length > 32) {
            return null
        }
        return normalized.takeIf { value ->
            value.any { it.isToneChar() } && value.all { it.isToneChar() || it == ',' }
        }
    }

    private fun normalizeChar(char: Char): Char? =
        when (char) {
            in '0'..'9', '*', '#', ',' -> char
            '＊' -> '*'
            '＃' -> '#'
            '，' -> ','
            'p', 'P' -> ','
            else -> null
        }

    private fun Char.isIgnoredSeparator(): Boolean = isWhitespace() || this == '-'

    fun isTone(char: Char): Boolean = char in '0'..'9' || char == '*' || char == '#'

    private fun Char.isToneChar(): Boolean = isTone(this)
}
