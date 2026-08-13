package com.edgelink.app

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class LyraSeedServiceRequest(
    val action: String,
    val deviceId: String,
    val cred: String? = null,
    val ticket: String? = null
)

@Serializable
data class LyraSeedServiceResult(
    val ok: Boolean,
    val action: String,
    val deviceId: String,
    val hasCred: Boolean = false,
    val hasTicket: Boolean = false,
    val credNotAfter: Long? = null,
    val output: String = ""
)

object LyraSeedProtocol {
    const val ACTION_STATUS = "status"
    const val ACTION_SEED = "seed"
    const val DEX_ASSET_NAME = "lyra-seed.dex"

    private val deviceIdRegex = Regex("^[0-9A-Fa-f]{4,32}$")
    private val json = Json { ignoreUnknownKeys = true }

    fun validate(request: LyraSeedServiceRequest): String? {
        if (request.action != ACTION_STATUS && request.action != ACTION_SEED) {
            return "bad action: ${request.action}"
        }
        if (!deviceIdRegex.matches(request.deviceId)) {
            return "bad deviceId"
        }
        if (request.action == ACTION_SEED) {
            if (request.cred.isNullOrBlank() || request.ticket.isNullOrBlank()) {
                return "seed requires cred and ticket"
            }
            for ((name, value) in listOf("cred" to request.cred, "ticket" to request.ticket)) {
                val parsed = runCatching { Json.parseToJsonElement(value!!) }.getOrNull()
                    ?: return "$name is not valid JSON"
                if (parsed !is kotlinx.serialization.json.JsonObject) {
                    return "$name must be a JSON object"
                }
            }
        }
        return null
    }

    fun encodeRequest(request: LyraSeedServiceRequest): String = json.encodeToString(request)

    fun decodeRequest(raw: String): LyraSeedServiceRequest =
        json.decodeFromString<LyraSeedServiceRequest>(raw)

    fun encodeResult(result: LyraSeedServiceResult): String = json.encodeToString(result)

    fun decodeResult(raw: String): LyraSeedServiceResult =
        json.decodeFromString<LyraSeedServiceResult>(raw)
}
