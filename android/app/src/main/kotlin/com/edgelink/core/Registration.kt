package com.edgelink.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.Base64

@Serializable
data class DeviceRegistrationRequest(
    val pubkey: String,
    val name: String,
    val platform: String
) {
    companion object {
        fun android(publicKey: ByteArray, name: String): DeviceRegistrationRequest =
            DeviceRegistrationRequest(
                pubkey = Base64.getEncoder().encodeToString(publicKey),
                name = name,
                platform = "android"
            )
    }
}

@Serializable
data class DeviceRegistrationResponse(
    val deviceId: String
)

class WorkerDeviceRegistrar(
    private val baseUrl: String,
    private val client: OkHttpClient = OkHttpClient(),
    private val json: Json = EnvelopeCodec.json
) {
    suspend fun register(publicKey: ByteArray, name: String, platform: String = "android"): String =
        withContext(Dispatchers.IO) {
            val body = json.encodeToString(
                DeviceRegistrationRequest.serializer(),
                DeviceRegistrationRequest(
                    pubkey = Base64.getEncoder().encodeToString(publicKey),
                    name = name,
                    platform = platform
                )
            )
            val request = Request.Builder()
                .url(baseUrl.trimEnd('/') + "/v1/device/register")
                .post(body.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    error("Device registration failed with HTTP ${response.code}.")
                }
                val responseBody = response.body?.string() ?: error("Empty registration response.")
                json.decodeFromString(DeviceRegistrationResponse.serializer(), responseBody).deviceId
            }
        }
}
