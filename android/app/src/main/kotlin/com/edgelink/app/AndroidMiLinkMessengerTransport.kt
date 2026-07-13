package com.edgelink.app

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Bundle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object AndroidMiLinkMessengerTransport {
    private val providerUri: Uri = Uri.parse("content://provider.milink.mi.com")
    private val registerUri: Uri = Uri.parse("content://provider.milink.mi.com/messenger/register")
    private const val pingMethod = "content://provider.milink.mi.com/messenger#ping"
    private const val pollMethod = "content://provider.milink.mi.com/messenger#poll"
    private const val sendMethod = "content://provider.milink.mi.com/messenger#send"

    suspend fun probe(context: Context): ShizukuOperationResult =
        withContext(Dispatchers.IO) {
            val resolver = context.applicationContext.contentResolver
            val steps = mutableListOf<String>()
            var registeredClient: RegisteredClient? = null
            var success = false

            try {
                val ping = resolver.call(providerUri, pingMethod, null, null)
                val pingCode = ping.codeOrNull()
                steps += "ping=${pingCode.asStep()}"

                val registerResult = register(context)
                registeredClient = registerResult.client
                steps += if (registerResult.client != null) {
                    "register=ok:${registerResult.client.clientNo}"
                } else {
                    "register=${registerResult.code.asStep()}"
                }

                if (registeredClient != null) {
                    val poll = poll(context, registeredClient.clientNo)
                    steps += "poll=${poll.code.asStep()}:bytes=${poll.data?.size ?: 0}:hasNext=${poll.hasNext}"
                    success = pingCode == 0 && poll.code == 0
                }
            } catch (error: Throwable) {
                steps += "error=${error.javaClass.simpleName}:${error.message}"
            } finally {
                val unregisterResult = registeredClient?.let { unregister(context, it) }
                if (unregisterResult != null) {
                    steps += "unregister=$unregisterResult"
                }
            }

            val message = "MiLink messenger transport ${if (success) "ok" else "failed"}: " +
                steps.joinToString()
            EdgeLinkLog.info("xiaomi.milink.messenger_transport_probe $message")
            ShizukuOperationResult(success = success, message = message)
        }

    suspend fun register(context: Context): RegisterResult =
        withContext(Dispatchers.IO) {
            val registeredUri = context.applicationContext.contentResolver.insert(registerUri, ContentValues())
            val code = registeredUri?.getQueryParameter("code")?.toIntOrNull()
            val clientNo = registeredUri?.lastPathSegment
            val client = if (code == 0 && !clientNo.isNullOrBlank()) {
                RegisteredClient(clientNo = clientNo, registeredUri = registeredUri)
            } else {
                null
            }
            RegisterResult(code = code, client = client)
        }

    suspend fun poll(context: Context, clientNo: String): PollResult =
        withContext(Dispatchers.IO) {
            val poll = context.applicationContext.contentResolver.call(providerUri, pollMethod, clientNo, null)
            PollResult(
                code = poll.codeOrNull(),
                data = poll?.getByteArray("dat"),
                hasNext = poll?.getBoolean("has_next", false) == true,
                start = poll?.getLong("start", -1L)?.takeIf { it >= 0L }
            )
        }

    suspend fun send(context: Context, clientNo: String, data: ByteArray): Int =
        withContext(Dispatchers.IO) {
            val extras = Bundle().apply {
                putByteArray("dat", data)
            }
            context.applicationContext.contentResolver
                .call(providerUri, sendMethod, clientNo, extras)
                ?.getInt("code", -1001)
                ?: -1001
        }

    suspend fun unregister(context: Context, client: RegisteredClient): String? =
        withContext(Dispatchers.IO) {
            unregister(context.applicationContext.contentResolver, client.registeredUri)
        }

    private fun unregister(resolver: ContentResolver, registeredUri: Uri): String? =
        registeredUri
            .buildUpon()
            ?.clearQuery()
            ?.build()
            ?.let { uri ->
                runCatching { resolver.delete(uri, null, null).toString() }
                    .getOrElse { error -> "${error.javaClass.simpleName}:${error.message}" }
            }

    private fun Bundle?.codeOrNull(): Int? =
        this?.takeIf { containsKey("code") }?.getInt("code")

    private fun Int?.asStep(): String =
        when (this) {
            0 -> "ok"
            null -> "null"
            else -> "code:$this"
        }

    data class RegisteredClient(
        val clientNo: String,
        val registeredUri: Uri
    )

    data class RegisterResult(
        val code: Int?,
        val client: RegisteredClient?
    )

    data class PollResult(
        val code: Int?,
        val data: ByteArray?,
        val hasNext: Boolean,
        val start: Long?
    )
}
