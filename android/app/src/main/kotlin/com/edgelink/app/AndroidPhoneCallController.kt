package com.edgelink.app

import android.content.Context
import com.edgelink.core.PhoneActionBody
import com.edgelink.core.PhoneActionResultBody
import java.time.Instant

private const val PHONE_ACTION_DIAL = "dial"
private const val PHONE_ACTION_ANSWER = "answer"
private const val PHONE_ACTION_HANGUP = "hangup"
private const val PHONE_CALL_RELAY_LATCH_TTL_MS = 30_000L

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
        armPhoneRelayLatch(PHONE_ACTION_DIAL, body)
        return runCatching {
            AndroidShizukuSupport.placePhoneCall(appContext, telUri)
        }.fold(
            onSuccess = { result ->
                if (!result.success) {
                    clearPhoneRelayLatch("dial_failed")
                }
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
                clearPhoneRelayLatch("dial_exception")
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

    private suspend fun pressKey(body: PhoneActionBody, keyCode: String, now: Long): PhoneActionResultBody {
        if (body.action == PHONE_ACTION_ANSWER) {
            armPhoneRelayLatch(PHONE_ACTION_ANSWER, body)
        }
        return runCatching {
            AndroidShizukuSupport.pressPhoneKey(appContext, keyCode)
        }.fold(
            onSuccess = { result ->
                if (body.action == PHONE_ACTION_ANSWER && !result.success) {
                    clearPhoneRelayLatch("answer_failed")
                }
                if (body.action == PHONE_ACTION_HANGUP) {
                    clearPhoneRelayLatch("hangup")
                }
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
                if (body.action == PHONE_ACTION_ANSWER) {
                    clearPhoneRelayLatch("answer_exception")
                }
                if (body.action == PHONE_ACTION_HANGUP) {
                    clearPhoneRelayLatch("hangup_exception")
                }
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

    private suspend fun armPhoneRelayLatch(action: String, body: PhoneActionBody) {
        runCatching {
            AndroidShizukuSupport.configurePhoneCallRelayHooks(
                appContext,
                relayHost = body.relayHost,
                relayPort = body.relayPort
            )
        }.onSuccess { result ->
            if (result.success) {
                EdgeLinkLog.info("phone.android.relay_hooks_configured action=$action message=${result.message}")
            } else {
                EdgeLinkLog.warn("phone.android.relay_hooks_configure_failed action=$action message=${result.message}")
            }
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.relay_hooks_configure_failed action=$action", error)
        }

        val latchResult = runCatching {
            AndroidShizukuSupport.armPhoneCallRelay(appContext, PHONE_CALL_RELAY_LATCH_TTL_MS)
        }
        latchResult.onSuccess { result ->
            if (result.success) {
                EdgeLinkLog.info("phone.android.relay_latch_armed action=$action ttlMs=$PHONE_CALL_RELAY_LATCH_TTL_MS")
            } else {
                EdgeLinkLog.warn("phone.android.relay_latch_arm_failed action=$action message=${result.message}")
            }
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.relay_latch_arm_failed action=$action", error)
        }
        if (latchResult.getOrNull()?.success == true) {
            pokePhoneContinuityRelay(action)
        }
    }

    private suspend fun pokePhoneContinuityRelay(action: String) {
        runCatching {
            AndroidMiLinkPhoneContinuityBridge.probe(appContext)
        }.onSuccess { result ->
            EdgeLinkLog.info(
                "phone.android.relay_continuity_poked action=$action " +
                    "success=${result.success} remoteDevices=${result.remoteDeviceCount} " +
                    "mediaRelayCandidates=${result.mediaRelayCandidateCount}"
            )
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.relay_continuity_poke_failed action=$action", error)
        }
    }

    private suspend fun clearPhoneRelayLatch(reason: String) {
        runCatching {
            AndroidShizukuSupport.clearPhoneCallRelay(appContext)
        }.onSuccess { result ->
            if (result.success) {
                EdgeLinkLog.info("phone.android.relay_latch_cleared reason=$reason")
            } else {
                EdgeLinkLog.warn("phone.android.relay_latch_clear_failed reason=$reason message=${result.message}")
            }
        }.onFailure { error ->
            EdgeLinkLog.warn("phone.android.relay_latch_clear_failed reason=$reason", error)
        }
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
