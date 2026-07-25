package com.edgelink.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import androidx.core.content.FileProvider
import com.edgelink.core.ClipboardBlobTransfer
import com.edgelink.core.ClipboardKind
import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest
import java.time.Instant

data class AndroidClipboardSnapshot(
    val text: String,
    val timestampSeconds: Long,
    val hash: String,
    val kind: ClipboardKind,
    val thumbnailBase64: String? = null,
    val blobData: ByteArray? = null,
    val blobMime: String? = null
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
        var blobData: ByteArray? = null
        var blobMime: String? = null
        val kind: ClipboardKind
        if (isImage) {
            kind = ClipboardKind.IMAGE
            thumbnailBase64 = ClipboardThumbnailGenerator.thumbnailBase64(clip, appContext)
            text = clip.getItemAt(0).coerceToText(appContext)?.toString()
                ?.take(IMAGE_TEXT_MAX_CHARS) ?: ""
            if (thumbnailBase64 != null &&
                thumbnailBase64.length + text.length > WIRE_IMAGE_MAX_CHARS
            ) {
                EdgeLinkLog.info(
                    "clipboard.android.image_thumbnail_dropped bytes=${thumbnailBase64.length}"
                )
                thumbnailBase64 = null
            }
            val uri = (0 until clip.itemCount).map(clip::getItemAt).firstNotNullOfOrNull { it.uri }
            if (uri != null) {
                val bytes = runCatching {
                    appContext.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                }.getOrNull()
                if (bytes != null && bytes.isNotEmpty()) {
                    if (bytes.size <= ClipboardBlobTransfer.MAX_BLOB_BYTES) {
                        blobData = bytes
                        blobMime = mimeTypes.firstOrNull { it.startsWith("image/") } ?: "image/png"
                    } else {
                        EdgeLinkLog.info("clipboard.android.image_blob_too_large bytes=${bytes.size}")
                    }
                }
            }
        } else {
            val t = clip.getItemAt(0).coerceToText(appContext)?.toString() ?: ""
            if (t.isEmpty()) {
                return null
            }
            val textBytes = t.toByteArray(Charsets.UTF_8).size
            if (textBytes > TEXT_STORE_MAX_BYTES) {
                EdgeLinkLog.info("clipboard.android.text_too_large_skipped bytes=$textBytes")
                return null
            }
            kind = ClipboardKind.TEXT
            if (textBytes > TEXT_WIRE_MAX_BYTES) {
                blobData = t.toByteArray(Charsets.UTF_8)
                blobMime = "text/plain"
                text = utf8Preview(t, TEXT_PREVIEW_MAX_BYTES)
            } else {
                text = t
            }
        }

        val computedHash = if (kind == ClipboardKind.IMAGE) {
            hash("\u0001" + (thumbnailBase64 ?: ""))
        } else if (blobData != null) {
            ClipboardBlobTransfer.sha256Hex(blobData)
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
            thumbnailBase64 = thumbnailBase64,
            blobData = blobData,
            blobMime = blobMime
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

    fun applyRemoteImage(data: ByteArray, mime: String?) {
        val bitmap = BitmapFactory.decodeStream(ByteArrayInputStream(data)) ?: run {
            EdgeLinkLog.info("clipboard.android.remote_image_undecodable bytes=${data.size}")
            return
        }
        val thumbnail = ClipboardThumbnailGenerator.thumbnailBase64(bitmap) ?: run {
            EdgeLinkLog.info("clipboard.android.remote_image_thumbnail_failed bytes=${data.size}")
            return
        }
        val computedHash = hash("\u0001" + thumbnail)
        val extension = when (mime) {
            "image/jpeg" -> "jpg"
            "image/gif" -> "gif"
            "image/webp" -> "webp"
            else -> "png"
        }
        val directory = File(appContext.cacheDir, "clipboard-blobs").apply { mkdirs() }
        val file = File(directory, "${ClipboardBlobTransfer.sha256Hex(data)}.$extension")
        runCatching { file.writeBytes(data) }.onFailure { error ->
            EdgeLinkLog.warn("clipboard.android.remote_image_write_failed", error)
            return
        }
        val uri = runCatching {
            FileProvider.getUriForFile(appContext, "${appContext.packageName}.clipboardblobs", file)
        }.getOrElse { error ->
            EdgeLinkLog.warn("clipboard.android.remote_image_uri_failed", error)
            return
        }
        val clip = ClipData.newUri(appContext.contentResolver, "EdgeLink", uri)
        clipboard.setPrimaryClip(clip)
        lastHash = computedHash
        suppressedHash = computedHash
    }

    private fun currentText(): String? {
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) {
            return null
        }
        return clip.getItemAt(0).coerceToText(appContext)?.toString()
    }

    companion object {
        private const val IMAGE_TEXT_MAX_CHARS = 2_048
        private const val WIRE_IMAGE_MAX_CHARS = 24 * 1024
        private const val TEXT_WIRE_MAX_BYTES = 48 * 1024
        private const val TEXT_STORE_MAX_BYTES = 256 * 1024
        private const val TEXT_PREVIEW_MAX_BYTES = 16 * 1024

        fun hash(text: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(text.encodeToByteArray())
            return digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }

        fun utf8Preview(text: String, maxBytes: Int): String {
            val bytes = text.toByteArray(Charsets.UTF_8)
            if (bytes.size <= maxBytes) return text
            var end = maxBytes
            while (end > 0 && bytes[end - 1].toInt() and 0xC0 == 0x80) {
                end -= 1
            }
            return String(bytes, 0, end, Charsets.UTF_8)
        }
    }
}
