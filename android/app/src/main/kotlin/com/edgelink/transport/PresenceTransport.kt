package com.edgelink.transport

import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.LocalIdentity
import com.edgelink.core.RelayAuth
import com.edgelink.core.SodiumHandshakeCrypto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.URLEncoder
import java.time.Instant
import java.util.Base64

class PresenceTransport(
    private val client: OkHttpClient = OkHttpClient(),
    private val crypto: SodiumHandshakeCrypto = SodiumHandshakeCrypto()
) {
    suspend fun fetch(workerBaseUrl: String, hostId: String, identity: LocalIdentity): MacPresenceResponse =
        withContext(Dispatchers.IO) {
            val timestamp = Instant.now().epochSecond
            val signature = crypto.signIdentity(RelayAuth.message(identity.deviceId, timestamp), identity)
            val sig = Base64.getEncoder().encodeToString(signature)
            val url = workerBaseUrl.trimEnd('/') + "/v1/presence" +
                "?hostId=" + urlEncode(hostId) +
                "&deviceId=" + urlEncode(identity.deviceId) +
                "&ts=" + timestamp +
                "&sig=" + urlEncode(sig)
            val request = Request.Builder().url(url).get().build()
            client.newCall(request).execute().use { response ->
                val responseBody = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    error("Presence request failed with HTTP ${response.code}: $responseBody")
                }
                EnvelopeCodec.json.decodeFromString(MacPresenceResponse.serializer(), responseBody)
            }
        }

    private fun urlEncode(value: String): String = URLEncoder.encode(value, Charsets.UTF_8)
}

@Serializable
data class MacPresenceResponse(
    val state: String,
    val updatedAt: Long = 0
)
