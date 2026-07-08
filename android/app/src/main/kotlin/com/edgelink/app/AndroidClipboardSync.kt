package com.edgelink.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import java.security.MessageDigest
import java.time.Instant

data class AndroidClipboardSnapshot(
    val text: String,
    val timestampSeconds: Long,
    val hash: String
)

class AndroidClipboardSync(context: Context) {
    private val appContext = context.applicationContext
    private val clipboard = appContext.getSystemService(ClipboardManager::class.java)
    private var lastHash: String?
    private var suppressedHash: String? = null

    init {
        lastHash = currentText()?.let(::hash)
    }

    fun pollLocalText(): AndroidClipboardSnapshot? {
        val text = currentText()?.takeIf { it.isNotEmpty() } ?: return null
        val hash = hash(text)
        if (hash == lastHash) {
            return null
        }
        lastHash = hash
        if (hash == suppressedHash) {
            suppressedHash = null
            return null
        }
        return AndroidClipboardSnapshot(
            text = text,
            timestampSeconds = Instant.now().epochSecond,
            hash = hash
        )
    }

    fun applyRemoteText(text: String, remoteHash: String) {
        val hash = remoteHash.ifEmpty { hash(text) }
        if (hash == lastHash) {
            suppressedHash = hash
            return
        }
        clipboard.setPrimaryClip(ClipData.newPlainText("EdgeLink", text))
        lastHash = hash
        suppressedHash = hash
    }

    private fun currentText(): String? {
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) {
            return null
        }
        return clip.getItemAt(0).coerceToText(appContext)?.toString()
    }

    companion object {
        fun hash(text: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(text.encodeToByteArray())
            return digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }
    }
}
