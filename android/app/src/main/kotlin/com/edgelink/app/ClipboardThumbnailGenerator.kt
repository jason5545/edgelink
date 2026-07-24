package com.edgelink.app

import android.content.ClipData
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

object ClipboardThumbnailGenerator {
    const val MAX_EDGE = 96

    fun thumbnailBase64(clip: ClipData, context: Context): String? =
        runCatching {
            val description = clip.description
            val mime0 =
                if (description.mimeTypeCount > 0) description.getMimeType(0) else null
            val imageLike = mime0?.startsWith("image/") == true
            val uri = (0 until clip.itemCount)
                .map(clip::getItemAt)
                .firstNotNullOfOrNull { it.uri }
            if (uri == null && !imageLike) return@runCatching null
            val targetUri = uri ?: return@runCatching null
            val resolver = context.contentResolver
            val bytes = resolver.openInputStream(targetUri)?.use { it.readBytes() }
                ?: return@runCatching null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeStream(ByteArrayInputStream(bytes), null, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                return@runCatching null
            }
            val sample =
                computeInSampleSize(bounds.outWidth, bounds.outHeight, MAX_EDGE)
            val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sample }
            val source =
                BitmapFactory.decodeStream(ByteArrayInputStream(bytes), null, decodeOpts)
                    ?: return@runCatching null
            thumbnailBase64(source)
        }.getOrElse { error ->
            EdgeLinkLog.warn("ClipboardThumbnailGenerator.clip thumbnail failed", error)
            null
        }

    fun thumbnailBase64(bitmap: Bitmap): String? =
        runCatching {
            val scaled = scaleToFit(bitmap)
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
            if (scaled !== bitmap) scaled.recycle()
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        }.getOrElse { error ->
            EdgeLinkLog.warn("ClipboardThumbnailGenerator.bitmap thumbnail failed", error)
            null
        }

    private fun computeInSampleSize(width: Int, height: Int, maxEdge: Int): Int {
        if (width <= 0 || height <= 0) return 1
        var sample = 1
        while (maxOf(width, height) / sample > maxEdge * 2) {
            sample *= 2
        }
        return sample
    }

    private fun scaleToFit(source: Bitmap): Bitmap {
        val width = source.width
        val height = source.height
        if (width <= 0 || height <= 0) return source
        val target = minOf(
            MAX_EDGE.toFloat() / width,
            MAX_EDGE.toFloat() / height,
            1f
        )
        val newW = maxOf(1, (width * target).toInt())
        val newH = maxOf(1, (height * target).toInt())
        if (newW == width && newH == height) return source
        return try {
            Bitmap.createScaledBitmap(source, newW, newH, true)
        } catch (error: OutOfMemoryError) {
            EdgeLinkLog.warn("ClipboardThumbnailGenerator OOM scaling", error)
            source
        }
    }
}