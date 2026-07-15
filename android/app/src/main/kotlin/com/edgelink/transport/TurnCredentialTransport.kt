package com.edgelink.transport

import com.edgelink.app.EdgeLinkLog
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.LocalIdentity
import com.edgelink.core.RelayAuth
import com.edgelink.core.SodiumHandshakeCrypto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.time.Instant

class TurnCredentialTransport(
    private val client: OkHttpClient = OkHttpClient(),
    private val crypto: SodiumHandshakeCrypto = SodiumHandshakeCrypto()
) {
    suspend fun fetch(workerBaseUrl: String, hostId: String, identity: LocalIdentity): TurnCredentialsResponse {
        val timestamp = Instant.now().epochSecond
        val signature = crypto.signIdentity(RelayAuth.message(identity.deviceId, timestamp), identity)
        val body = EnvelopeCodec.json.encodeToString(
            TurnCredentialsRequest.serializer(),
            TurnCredentialsRequest(
                hostId = hostId,
                deviceId = identity.deviceId,
                ts = timestamp,
                sig = java.util.Base64.getEncoder().encodeToString(signature)
            )
        )
        return withContext(Dispatchers.IO) {
            val url = workerBaseUrl.trimEnd('/') + "/v1/turn/credentials"
            val request = Request.Builder()
                .url(url)
                .post(body.toRequestBody("application/json".toMediaType()))
                .build()
            EdgeLinkLog.info("turn.transport.android.fetch_start hostId=$hostId deviceId=${identity.deviceId}")
            client.newCall(request).execute().use { response ->
                val responseBody = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    error("TURN credential request failed with HTTP ${response.code}: $responseBody")
                }
                EnvelopeCodec.json.decodeFromString(TurnCredentialsResponse.serializer(), responseBody)
            }
        }
    }
}

@Serializable
private data class TurnCredentialsRequest(
    val hostId: String,
    val deviceId: String,
    val ts: Long,
    val sig: String
)

@Serializable
data class TurnCredentialsResponse(
    val urls: List<String>,
    val username: String,
    val credential: String,
    val ttlSeconds: Int,
    val issuedAt: Long,
    val expiresAt: Long,
    val realm: String,
    val iceServers: List<TurnIceServerResponse> = emptyList()
) {
    fun isFresh(nowSeconds: Long = Instant.now().epochSecond): Boolean =
        nowSeconds < expiresAt - 60

    fun diagnosticSummary(): String =
        "urls=${urls.joinToString(",")} ttl=$ttlSeconds expiresAt=$expiresAt realm=$realm"
}

@Serializable
data class TurnIceServerResponse(
    val urls: List<String>,
    val username: String? = null,
    val credential: String? = null
)
