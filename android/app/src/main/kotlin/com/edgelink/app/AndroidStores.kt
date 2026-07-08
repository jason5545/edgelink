@file:Suppress("DEPRECATION")

package com.edgelink.app

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.edgelink.core.IdentityStore
import com.edgelink.core.LocalIdentity
import com.edgelink.core.PairingStore
import com.edgelink.core.PinnedPeer
import java.time.Instant
import java.util.Base64

class SharedPreferencesIdentityStore(context: Context) : IdentityStore {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "edgelink_identity",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    override fun loadIdentity(): LocalIdentity? {
        val deviceId = prefs.getString("deviceId", null) ?: return null
        val name = prefs.getString("name", null) ?: return null
        val publicKey = prefs.getBase64("publicKey") ?: return null
        val privateKeySeed = prefs.getBase64("privateKeySeed") ?: return null
        return LocalIdentity(
            deviceId = deviceId,
            name = name,
            publicKey = publicKey,
            privateKeySeed = privateKeySeed
        )
    }

    override fun saveIdentity(identity: LocalIdentity) {
        prefs.edit()
            .putString("deviceId", identity.deviceId)
            .putString("name", identity.name)
            .putBase64("publicKey", identity.publicKey)
            .putBase64("privateKeySeed", identity.privateKeySeed)
            .apply()
    }
}

class SharedPreferencesPairingStore(context: Context) : PairingStore {
    private val prefs = context.getSharedPreferences("edgelink_pairing", Context.MODE_PRIVATE)

    override fun loadPeer(deviceId: String): PinnedPeer? {
        val prefix = "peer.$deviceId."
        val name = prefs.getString(prefix + "name", null) ?: return null
        val publicKey = prefs.getBase64(prefix + "publicKey") ?: return null
        val pairedAt = prefs.getString(prefix + "pairedAt", null)?.let(Instant::parse) ?: return null
        return PinnedPeer(deviceId = deviceId, name = name, publicKey = publicKey, pairedAt = pairedAt)
    }

    fun loadPeers(): List<PinnedPeer> =
        prefs.getStringSet("peerIds", emptySet()).orEmpty().mapNotNull(::loadPeer)

    override fun savePeer(peer: PinnedPeer) {
        val ids = prefs.getStringSet("peerIds", emptySet()).orEmpty().toMutableSet()
        ids.add(peer.deviceId)
        val prefix = "peer.${peer.deviceId}."
        prefs.edit()
            .putStringSet("peerIds", ids)
            .putString(prefix + "name", peer.name)
            .putBase64(prefix + "publicKey", peer.publicKey)
            .putString(prefix + "pairedAt", peer.pairedAt.toString())
            .apply()
    }
}

class SharedPreferencesSettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("edgelink_settings", Context.MODE_PRIVATE)

    fun autoReconnectEnabled(): Boolean =
        prefs.getBoolean("autoReconnectEnabled", true)

    fun saveAutoReconnectEnabled(enabled: Boolean) {
        prefs.edit()
            .putBoolean("autoReconnectEnabled", enabled)
            .apply()
    }
}

private fun SharedPreferences.getBase64(key: String): ByteArray? =
    getString(key, null)?.let(Base64.getDecoder()::decode)

private fun SharedPreferences.Editor.putBase64(key: String, value: ByteArray): SharedPreferences.Editor =
    putString(key, Base64.getEncoder().encodeToString(value))
