package com.edgelink.core

import java.util.Base64

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

data class DeviceRegistrationResponse(
    val deviceId: String
)
