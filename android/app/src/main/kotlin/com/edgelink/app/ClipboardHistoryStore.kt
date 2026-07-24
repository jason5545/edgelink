package com.edgelink.app

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
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
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            db.execSQL(DROP_SQL)
            onCreate(db)
        }
    }

    fun append(item: ClipboardHistoryItemBody, itemIndex: Int = 0) {
        submit(Unit) {
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
                while (it.moveToNext()) {
                    out += ClipboardHistoryItemBody(
                        id = it.getString(idxId),
                        kind = ClipboardKind.fromInt(it.getInt(idxType))?.wireName ?: "text",
                        ts = it.getLong(idxTs),
                        hash = if (it.isNull(idxHash)) "" else it.getString(idxHash),
                        text = if (it.isNull(idxText)) null else it.getString(idxText),
                        thumbnailBase64 = if (it.isNull(idxThumb)) null else it.getString(idxThumb),
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
        }
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
        private const val DB_VERSION = 1
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

        private const val DROP_SQL = "DROP TABLE IF EXISTS $TABLE_NAME;"

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
    }
}