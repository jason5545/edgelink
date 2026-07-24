package com.edgelink.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import com.edgelink.core.ClipboardKind
import java.security.MessageDigest
import java.time.Instant

data class AndroidClipboardSnapshot(
    val text: String,
    val timestampSeconds: Long,
    val hash: String,
    val kind: ClipboardKind,
    val thumbnailBase64: String? = null
)

class AndroidClipboardSync(context: Context) {
    private val appContext = context.applicationContext
    private val clipboard = appContext.getSystemService(ClipboardManager::class.java)
    private var lastHash: String?
    private var suppressedHash: String? = null

    init {
        lastHash = currentText()?.let(::hash)
    }

    fun pollLocalClip(): AndroidClipboardSnapshot? {
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) {
            return null
        }

        val description = clip.description
        val mimeTypes = if (description != null) {
            (0 until description.mimeTypeCount).map { description.getMimeType(it) }
        } else {
            emptyList()
        }
        val isImage = mimeTypes.any { it.startsWith("image/") }

        var text = ""
        var thumbnailBase64: String? = null
        val kind: ClipboardKind
        if (isImage) {
            kind = ClipboardKind.IMAGE
            thumbnailBase64 = ClipboardThumbnailGenerator.thumbnailBase64(clip, appContext)
            text = clip.getItemAt(0).coerceToText(appContext)?.toString() ?: ""
        } else {
            val t = clip.getItemAt(0).coerceToText(appContext)?.toString() ?: ""
            if (t.isEmpty()) {
                return null
            }
            kind = ClipboardKind.TEXT
            text = t
        }

        val computedHash = if (kind == ClipboardKind.IMAGE) {
            hash("\u0001" + (thumbnailBase64 ?: ""))
        } else {
            hash(text)
        }
        if (computedHash == lastHash) {
            return null
        }
        lastHash = computedHash
        if (computedHash == suppressedHash) {
            suppressedHash = null
            return null
        }
        return AndroidClipboardSnapshot(
            text = text,
            timestampSeconds = Instant.now().epochSecond,
            hash = computedHash,
            kind = kind,
            thumbnailBase64 = thumbnailBase64
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
