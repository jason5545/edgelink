package com.edgelink.core

import java.time.Instant

data class PinnedPeer(
    val deviceId: String,
    val name: String,
    val publicKey: ByteArray,
    val pairedAt: Instant
) {
    init {
        require(DeviceId.isValid(deviceId)) { "Device ID must be 9 digits without a leading zero." }
        require(publicKey.size == 32) { "Ed25519 public key must be 32 bytes." }
    }
}

interface PairingStore {
    fun loadPeer(deviceId: String): PinnedPeer?
    fun savePeer(peer: PinnedPeer)
}

class InMemoryPairingStore : PairingStore {
    private val peers = mutableMapOf<String, PinnedPeer>()

    override fun loadPeer(deviceId: String): PinnedPeer? = peers[deviceId]

    override fun savePeer(peer: PinnedPeer) {
        peers[peer.deviceId] = peer
    }
}
