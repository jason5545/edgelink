package com.edgelink.app

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import com.edgelink.core.ClipboardBlobTransfer
import com.edgelink.core.ClipboardHistoryItemBody
import com.edgelink.core.ClipboardHistoryResponseBody
import com.edgelink.core.ClipboardKind
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors

class ClipboardHistoryStore(context: Context) {
    private val appContext = context.applicationContext
    private val executor = Executors.newSingleThreadExecutor()

    private val helper = object : SQLiteOpenHelper(appContext, DB_NAME, null, DB_VERSION) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(CREATE_TABLE_SQL)
            db.execSQL(CREATE_INDEX_SQL)
            db.execSQL(CREATE_BLOB_TABLE_SQL)
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2) {
                db.execSQL(CREATE_BLOB_TABLE_SQL)
                db.execSQL(PURGE_OVERSIZED_TEXT_SQL)
            }
        }
    }

    data class Blob(
        val id: String,
        val mime: String?,
        val hash: String,
        val data: ByteArray
    )

    fun append(item: ClipboardHistoryItemBody, itemIndex: Int = 0) {
        submit(Unit) {
            if (isOversizedText(item.text)) {
                EdgeLinkLog.info("clipboard.android.history_text_too_large_dropped id=${item.id}")
                return@submit
            }
            val db = helper.writableDatabase
            val values = ContentValues().apply {
                put(COL_EVENT_ID, item.id)
                put(COL_ITEM_INDEX, itemIndex)
                put(COL_TIMESTAMP, item.ts)
                put(COL_CLIPBOARD_TYPE, ClipboardKind.fromWire(item.kind)?.intValue ?: 0)
                put(COL_TEXT_DATA, item.text)
                putNull(COL_FILE_PATH)
                put(COL_THUMBNAIL_BASE64, item.thumbnailBase64)
                put(COL_HASH, item.hash)
                put(COL_SOURCE_DEVICE_ID, item.sourceDeviceId)
            }
            db.insertWithOnConflict(
                TABLE_NAME,
                null,
                values,
                SQLiteDatabase.CONFLICT_REPLACE
            )
        }
    }

    fun importRemote(items: List<ClipboardHistoryItemBody>): Int =
        submit(0) {
            val db = helper.writableDatabase
            var inserted = 0
            items.forEach { item ->
                if (isOversizedText(item.text)) {
                    return@forEach
                }
                val values = ContentValues().apply {
                    put(COL_EVENT_ID, item.id)
                    put(COL_ITEM_INDEX, 0)
                    put(COL_TIMESTAMP, item.ts)
                    put(COL_CLIPBOARD_TYPE, ClipboardKind.fromWire(item.kind)?.intValue ?: 0)
                    put(COL_TEXT_DATA, item.text)
                    putNull(COL_FILE_PATH)
                    put(COL_THUMBNAIL_BASE64, item.thumbnailBase64)
                    put(COL_HASH, item.hash)
                    put(COL_SOURCE_DEVICE_ID, item.sourceDeviceId)
                }
                val rowId = db.insertWithOnConflict(
                    TABLE_NAME,
                    null,
                    values,
                    SQLiteDatabase.CONFLICT_IGNORE
                )
                if (rowId != -1L) {
                    inserted++
                }
            }
            inserted
        }

    fun recent(sinceTs: Long? = null, limit: Int = 50): List<ClipboardHistoryItemBody> =
        submit(emptyList()) {
            val clamped = limit.coerceIn(0, 200)
            val db = helper.readableDatabase
            val cursor = if (sinceTs != null) {
                db.rawQuery(
                    SELECT_WHERE_SQL,
                    arrayOf(sinceTs.toString(), clamped.toString())
                )
            } else {
                db.rawQuery(SELECT_SQL, arrayOf(clamped.toString()))
            }
            cursor.use {
                val idxId = it.getColumnIndexOrThrow(COL_EVENT_ID)
                val idxTs = it.getColumnIndexOrThrow(COL_TIMESTAMP)
                val idxType = it.getColumnIndexOrThrow(COL_CLIPBOARD_TYPE)
                val idxText = it.getColumnIndexOrThrow(COL_TEXT_DATA)
                val idxThumb = it.getColumnIndexOrThrow(COL_THUMBNAIL_BASE64)
                val idxHash = it.getColumnIndexOrThrow(COL_HASH)
                val idxSrc = it.getColumnIndexOrThrow(COL_SOURCE_DEVICE_ID)
                val out = mutableListOf<ClipboardHistoryItemBody>()
                var totalBytes = 0
                while (it.moveToNext()) {
                    val text = if (it.isNull(idxText)) null else it.getString(idxText)
                    val thumb = if (it.isNull(idxThumb)) null else it.getString(idxThumb)
                    val itemBytes = (text?.toByteArray(Charsets.UTF_8)?.size ?: 0) +
                        (thumb?.toByteArray(Charsets.UTF_8)?.size ?: 0)
                    if (itemBytes > WIRE_ITEM_MAX_BYTES) {
                        continue
                    }
                    if (totalBytes + itemBytes > WIRE_TOTAL_MAX_BYTES) {
                        break
                    }
                    totalBytes += itemBytes
                    out += ClipboardHistoryItemBody(
                        id = it.getString(idxId),
                        kind = ClipboardKind.fromInt(it.getInt(idxType))?.wireName ?: "text",
                        ts = it.getLong(idxTs),
                        hash = if (it.isNull(idxHash)) "" else it.getString(idxHash),
                        text = text,
                        thumbnailBase64 = thumb,
                        sourceDeviceId = if (it.isNull(idxSrc)) null else it.getString(idxSrc)
                    )
                }
                out
            }
        }

    fun prune(maxCount: Int = 200) {
        submit(Unit) {
            val db = helper.writableDatabase
            db.execSQL("$DELETE_OFFSET_SQL_PREFIX$maxCount$DELETE_OFFSET_SQL_SUFFIX")
        }
    }

    fun clear() {
        submit(Unit) {
            val db = helper.writableDatabase
            db.execSQL(DELETE_ALL_SQL)
            db.execSQL(DELETE_ALL_BLOBS_SQL)
        }
    }

    fun saveBlob(id: String, mime: String?, data: ByteArray) {
        submit(Unit) {
            if (data.isEmpty() || data.size > ClipboardBlobTransfer.MAX_BLOB_BYTES) {
                EdgeLinkLog.info("clipboard.android.blob_rejected id=$id bytes=${data.size}")
                return@submit
            }
            val db = helper.writableDatabase
            val values = ContentValues().apply {
                put(COL_BLOB_EVENT_ID, id)
                put(COL_BLOB_MIME, mime)
                put(COL_BLOB_HASH, ClipboardBlobTransfer.sha256Hex(data))
                put(COL_BLOB_DATA, data)
                put(COL_BLOB_LAST_ACCESS, System.currentTimeMillis() / 1000)
                put(COL_BLOB_BYTES, data.size)
            }
            db.insertWithOnConflict(
                BLOB_TABLE_NAME,
                null,
                values,
                SQLiteDatabase.CONFLICT_REPLACE
            )
            pruneBlobsLocked(db)
        }
    }

    fun loadBlob(id: String): Blob? =
        submit(null) {
            val db = helper.writableDatabase
            val cursor = db.rawQuery(SELECT_BLOB_SQL, arrayOf(id))
            val blob = cursor.use {
                if (!it.moveToFirst()) {
                    null
                } else {
                    Blob(
                        id = it.getString(0),
                        mime = if (it.isNull(1)) null else it.getString(1),
                        hash = it.getString(2),
                        data = it.getBlob(3)
                    )
                }
            }
            if (blob != null) {
                val values = ContentValues().apply {
                    put(COL_BLOB_LAST_ACCESS, System.currentTimeMillis() / 1000)
                }
                db.update(BLOB_TABLE_NAME, values, "$COL_BLOB_EVENT_ID = ?", arrayOf(id))
            }
            blob
        }

    fun deleteBlob(id: String) {
        submit(Unit) {
            val db = helper.writableDatabase
            db.delete(BLOB_TABLE_NAME, "$COL_BLOB_EVENT_ID = ?", arrayOf(id))
        }
    }

    private fun pruneBlobsLocked(db: SQLiteDatabase) {
        var total = 0L
        db.rawQuery(SUM_BLOBS_SQL, null).use {
            if (it.moveToFirst() && !it.isNull(0)) total = it.getLong(0)
        }
        if (total <= BLOB_QUOTA_BYTES) return
        val cursor = db.rawQuery(SELECT_BLOBS_BY_ACCESS_SQL, null)
        val toDelete = mutableListOf<String>()
        cursor.use {
            while (it.moveToNext() && total > BLOB_QUOTA_BYTES) {
                toDelete += it.getString(0)
                total -= it.getLong(1)
            }
        }
        toDelete.forEach { id ->
            db.delete(BLOB_TABLE_NAME, "$COL_BLOB_EVENT_ID = ?", arrayOf(id))
        }
        if (toDelete.isNotEmpty()) {
            EdgeLinkLog.info("clipboard.android.blob_lru_evicted count=${toDelete.size}")
        }
    }

    private fun isOversizedText(text: String?): Boolean {
        val bytes = text?.toByteArray(Charsets.UTF_8)?.size ?: return false
        return bytes > TEXT_STORE_MAX_BYTES
    }

    val count: Int
        get() = submit(0) {
            val db = helper.readableDatabase
            val cursor = db.rawQuery(COUNT_SQL, null)
            cursor.use {
                if (it.moveToFirst()) it.getInt(0) else 0
            }
        }

    private inline fun <T> submit(default: T, crossinline block: () -> T): T =
        try {
            executor.submit<T> { block() }.get()
        } catch (e: ExecutionException) {
            EdgeLinkLog.warn("ClipboardHistoryStore operation failed", e.cause ?: e)
            default
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            EdgeLinkLog.warn("ClipboardHistoryStore operation interrupted", e)
            default
        }

    fun recentAsResponse(sinceTs: Long? = null, limit: Int = 50): ClipboardHistoryResponseBody =
        ClipboardHistoryResponseBody(items = recent(sinceTs, limit))

    companion object {
        private const val DB_NAME = "clipboard_history.db"
        private const val DB_VERSION = 2
        private const val WIRE_ITEM_MAX_BYTES = 24 * 1024
        private const val WIRE_TOTAL_MAX_BYTES = 48 * 1024
        private const val TEXT_STORE_MAX_BYTES = 256 * 1024
        private const val BLOB_QUOTA_BYTES = 50L * 1024 * 1024
        private const val TABLE_NAME = "clipboard_history"
        private const val COL_EVENT_ID = "event_id"
        private const val COL_ITEM_INDEX = "item_index"
        private const val COL_TIMESTAMP = "timestamp"
        private const val COL_CLIPBOARD_TYPE = "clipboard_type"
        private const val COL_TEXT_DATA = "text_data"
        private const val COL_FILE_PATH = "file_path"
        private const val COL_THUMBNAIL_BASE64 = "thumbnail_base64"
        private const val COL_HASH = "hash"
        private const val COL_SOURCE_DEVICE_ID = "source_device_id"

        private val CREATE_TABLE_SQL =
            """CREATE TABLE IF NOT EXISTS $TABLE_NAME (
    $COL_EVENT_ID TEXT NOT NULL,
    $COL_ITEM_INDEX INTEGER NOT NULL DEFAULT 0,
    $COL_TIMESTAMP INTEGER NOT NULL,
    $COL_CLIPBOARD_TYPE INTEGER NOT NULL,
    $COL_TEXT_DATA TEXT,
    $COL_FILE_PATH TEXT,
    $COL_THUMBNAIL_BASE64 TEXT,
    $COL_HASH TEXT NOT NULL,
    $COL_SOURCE_DEVICE_ID TEXT,
    PRIMARY KEY ($COL_EVENT_ID, $COL_ITEM_INDEX)
);""".trimIndent()

        private const val CREATE_INDEX_SQL =
            "CREATE INDEX IF NOT EXISTS idx_clip_hist_ts ON $TABLE_NAME($COL_TIMESTAMP DESC);"

        private val SELECT_SQL =
            """SELECT $COL_EVENT_ID, $COL_TIMESTAMP, $COL_CLIPBOARD_TYPE, $COL_TEXT_DATA,
       $COL_THUMBNAIL_BASE64, $COL_HASH, $COL_SOURCE_DEVICE_ID
  FROM $TABLE_NAME
 ORDER BY $COL_TIMESTAMP DESC
 LIMIT ?""".trimIndent()

        private val SELECT_WHERE_SQL =
            """SELECT $COL_EVENT_ID, $COL_TIMESTAMP, $COL_CLIPBOARD_TYPE, $COL_TEXT_DATA,
       $COL_THUMBNAIL_BASE64, $COL_HASH, $COL_SOURCE_DEVICE_ID
  FROM $TABLE_NAME
 WHERE $COL_TIMESTAMP > ?
 ORDER BY $COL_TIMESTAMP DESC
 LIMIT ?""".trimIndent()

        private const val DELETE_OFFSET_SQL_PREFIX =
            """DELETE FROM $TABLE_NAME WHERE ($COL_EVENT_ID, $COL_ITEM_INDEX) IN (
        SELECT $COL_EVENT_ID, $COL_ITEM_INDEX
          FROM $TABLE_NAME
         ORDER BY $COL_TIMESTAMP DESC
         LIMIT -1 OFFSET """

        private const val DELETE_OFFSET_SQL_SUFFIX = ");"

        private const val DELETE_ALL_SQL = "DELETE FROM $TABLE_NAME;"

        private const val COUNT_SQL = "SELECT COUNT(*) FROM $TABLE_NAME;"

        private const val BLOB_TABLE_NAME = "clipboard_blobs"
        private const val COL_BLOB_EVENT_ID = "event_id"
        private const val COL_BLOB_MIME = "mime"
        private const val COL_BLOB_HASH = "hash"
        private const val COL_BLOB_DATA = "data"
        private const val COL_BLOB_LAST_ACCESS = "last_access"
        private const val COL_BLOB_BYTES = "bytes"

        private val CREATE_BLOB_TABLE_SQL =
            """CREATE TABLE IF NOT EXISTS $BLOB_TABLE_NAME (
    $COL_BLOB_EVENT_ID TEXT PRIMARY KEY,
    $COL_BLOB_MIME TEXT,
    $COL_BLOB_HASH TEXT NOT NULL,
    $COL_BLOB_DATA BLOB NOT NULL,
    $COL_BLOB_LAST_ACCESS INTEGER NOT NULL,
    $COL_BLOB_BYTES INTEGER NOT NULL
);""".trimIndent()

        private const val PURGE_OVERSIZED_TEXT_SQL =
            "DELETE FROM $TABLE_NAME WHERE LENGTH(CAST($COL_TEXT_DATA AS BLOB)) > $TEXT_STORE_MAX_BYTES;"

        private const val SELECT_BLOB_SQL =
            "SELECT $COL_BLOB_EVENT_ID, $COL_BLOB_MIME, $COL_BLOB_HASH, $COL_BLOB_DATA FROM $BLOB_TABLE_NAME WHERE $COL_BLOB_EVENT_ID = ?;"

        private const val SUM_BLOBS_SQL = "SELECT SUM($COL_BLOB_BYTES) FROM $BLOB_TABLE_NAME;"

        private const val SELECT_BLOBS_BY_ACCESS_SQL =
            "SELECT $COL_BLOB_EVENT_ID, $COL_BLOB_BYTES FROM $BLOB_TABLE_NAME ORDER BY $COL_BLOB_LAST_ACCESS ASC;"

        private const val DELETE_ALL_BLOBS_SQL = "DELETE FROM $BLOB_TABLE_NAME;"
    }
}