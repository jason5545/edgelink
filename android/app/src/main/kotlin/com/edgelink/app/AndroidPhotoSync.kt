package com.edgelink.app

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.security.MessageDigest

class AndroidPhotoSync(
    private val context: Context,
    private val settingsStore: SharedPreferencesSettingsStore
) {
    data class MediaItem(
        val id: String,
        val contentUri: Uri,
        val name: String,
        val mime: String,
        val bytes: Long,
        val dateTakenMs: Long,
        val dateAddedSec: Long,
        val isVideo: Boolean
    )

    fun hasPermission(): Boolean = requiredPermissions().all { permission ->
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    fun scanNewItems(maxItems: Int = 500): List<MediaItem> {
        if (!hasPermission()) return emptyList()
        val watermark = settingsStore.photoSyncWatermarkSec()
        if (watermark <= 0L) {
            val now = System.currentTimeMillis() / 1_000L
            settingsStore.savePhotoSyncWatermarkSec(now)
            EdgeLinkLog.info("photo.android.watermark_initialized now=$now")
            return emptyList()
        }
        val acked = settingsStore.photoSyncAckedIds()
        val items = mutableListOf<MediaItem>()
        items += queryCollection(
            collection = imagesCollection(),
            idPrefix = "img",
            isVideo = false,
            sinceSec = watermark
        )
        items += queryCollection(
            collection = videosCollection(),
            idPrefix = "vid",
            isVideo = true,
            sinceSec = watermark
        )
        val eligible = items.filter { it.dateTakenMs >= MIN_DATE_TAKEN_MS }
        val skippedOld = items.size - eligible.size
        if (skippedOld > 0) {
            EdgeLinkLog.info("photo.android.skip_old count=$skippedOld min_year=2015")
        }
        return eligible
            .filter { it.id !in acked }
            .sortedBy { it.dateAddedSec }
            .take(maxItems)
    }

    fun openItem(item: MediaItem): java.io.InputStream? =
        runCatching { context.contentResolver.openInputStream(item.contentUri) }.getOrNull()

    fun markAcknowledged(ids: Collection<String>) {
        if (ids.isEmpty()) return
        settingsStore.addPhotoSyncAckedIds(ids)
    }

    fun advanceWatermark(items: Collection<MediaItem>) {
        val maxAdded = items.maxOfOrNull { it.dateAddedSec } ?: return
        settingsStore.savePhotoSyncWatermarkSec(maxOf(settingsStore.photoSyncWatermarkSec(), maxAdded))
        settingsStore.prunePhotoSyncAckedIds()
    }

    private fun queryCollection(
        collection: Uri,
        idPrefix: String,
        isVideo: Boolean,
        sinceSec: Long
    ): List<MediaItem> {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED
        )
        val selection = "${MediaStore.MediaColumns.DATE_ADDED} > ?"
        val args = arrayOf(sinceSec.toString())
        val sort = "${MediaStore.MediaColumns.DATE_ADDED} ASC"
        val results = mutableListOf<MediaItem>()
        runCatching {
            context.contentResolver.query(collection, projection, selection, args, sort)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val takenCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
                val addedCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
                while (cursor.moveToNext()) {
                    val rowId = cursor.getLong(idCol)
                    val bytes = cursor.getLong(sizeCol)
                    if (bytes <= 0L) continue
                    val dateAdded = cursor.getLong(addedCol)
                    val takenRaw = if (cursor.isNull(takenCol)) 0L else cursor.getLong(takenCol)
                    val dateTaken = if (takenRaw > 0L) takenRaw else dateAdded * 1_000L
                    results += MediaItem(
                        id = "$idPrefix-$rowId",
                        contentUri = ContentUris.withAppendedId(collection, rowId),
                        name = cursor.getString(nameCol) ?: "$idPrefix-$rowId",
                        mime = cursor.getString(mimeCol) ?: if (isVideo) "video/mp4" else "image/jpeg",
                        bytes = bytes,
                        dateTakenMs = dateTaken,
                        dateAddedSec = dateAdded,
                        isVideo = isVideo
                    )
                }
            }
        }.onFailure { error ->
            EdgeLinkLog.error("photo.android.scan_failed prefix=$idPrefix", error)
        }
        return results
    }

    companion object {
        const val CHUNK_BYTES = 32 * 1024
        const val MIN_DATE_TAKEN_MS = 1_420_070_400_000L

        fun requiredPermissions(): Array<String> =
            when {
                Build.VERSION.SDK_INT >= 33 -> arrayOf(
                    Manifest.permission.READ_MEDIA_IMAGES,
                    Manifest.permission.READ_MEDIA_VIDEO
                )
                else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            }

        private fun imagesCollection(): Uri =
            if (Build.VERSION.SDK_INT >= 29) {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }

        private fun videosCollection(): Uri =
            if (Build.VERSION.SDK_INT >= 29) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }

        fun sha256Hex(digest: MessageDigest): String =
            digest.digest().joinToString("") { "%02x".format(it) }

        fun newDigest(): MessageDigest = MessageDigest.getInstance("SHA-256")
    }
}
