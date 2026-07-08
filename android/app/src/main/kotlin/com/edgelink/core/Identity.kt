package com.edgelink.core

data class DeviceIdentity(
    val deviceId: String,
    val name: String,
    val publicKey: ByteArray
) {
    init {
        require(deviceId.matches(Regex("[1-9][0-9]{8}"))) { "Device ID must be 9 digits without a leading zero." }
    }
}
