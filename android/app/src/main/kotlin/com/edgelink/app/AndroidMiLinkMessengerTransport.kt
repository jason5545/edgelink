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
            var registeredUri: Uri? = null
            var success = false

            try {
                val ping = resolver.call(providerUri, pingMethod, null, null)
                val pingCode = ping.codeOrNull()
                steps += "ping=${pingCode.asStep()}"

                registeredUri = resolver.insert(registerUri, ContentValues())
                val registerCode = registeredUri?.getQueryParameter("code")?.toIntOrNull()
                val clientNo = registeredUri?.lastPathSegment
                val registered = registerCode == 0 && !clientNo.isNullOrBlank()
                steps += if (registered) {
                    "register=ok:$clientNo"
                } else {
                    "register=${registerCode.asStep()}"
                }

                if (registered) {
                    val poll = resolver.call(providerUri, pollMethod, clientNo, null)
                    val pollCode = poll.codeOrNull()
                    val data = poll?.getByteArray("dat")
                    val hasNext = poll?.getBoolean("has_next", false) == true
                    steps += "poll=${pollCode.asStep()}:bytes=${data?.size ?: 0}:hasNext=$hasNext"
                    success = pingCode == 0 && pollCode == 0
                }
            } catch (error: Throwable) {
                steps += "error=${error.javaClass.simpleName}:${error.message}"
            } finally {
                val unregisterResult = unregister(resolver, registeredUri)
                if (unregisterResult != null) {
                    steps += "unregister=$unregisterResult"
                }
            }

            val message = "MiLink messenger transport ${if (success) "ok" else "failed"}: " +
                steps.joinToString()
            EdgeLinkLog.info("xiaomi.milink.messenger_transport_probe $message")
            ShizukuOperationResult(success = success, message = message)
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

    private fun unregister(resolver: ContentResolver, registeredUri: Uri?): String? =
        registeredUri
            ?.buildUpon()
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
}
