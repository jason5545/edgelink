package com.edgelink.core

data class DeviceIdentity(
    val deviceId: String,
    val name: String,
    val publicKey: ByteArray
) {
    init {
        require(DeviceId.isValid(deviceId)) { "Device ID must be 9 digits without a leading zero." }
    }
}

data class LocalIdentity(
    val deviceId: String,
    val name: String,
    val publicKey: ByteArray,
    val privateKeySeed: ByteArray
) {
    init {
        require(DeviceId.isValid(deviceId)) { "Device ID must be 9 digits without a leading zero." }
        require(publicKey.size == 32) { "Ed25519 public key must be 32 bytes." }
        require(privateKeySeed.size == 32) { "Ed25519 private key seed must be 32 bytes." }
    }
}

interface IdentityStore {
    fun loadIdentity(): LocalIdentity?
    fun saveIdentity(identity: LocalIdentity)
}
