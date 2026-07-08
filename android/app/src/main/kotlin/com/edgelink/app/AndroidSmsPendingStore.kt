package com.edgelink.app

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private const val SMS_PENDING_PREFS = "edgelink_sms_pending"
private const val SMS_PENDING_KEY = "pendingBroadcasts"
private const val SMS_PENDING_LIMIT = 100

object AndroidSmsPendingStore {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Synchronized
    fun enqueue(context: Context, address: String, text: String, timestampMs: Long): PendingSmsRecord {
        val appContext = context.applicationContext
        val record = PendingSmsRecord(
            id = pendingId(address = address, text = text, timestampMs = timestampMs),
            address = address.trim(),
            text = text,
            timestampMs = timestampMs
        )
        val records = readRecords(appContext).toMutableList()
        if (records.none { it.id == record.id }) {
            records.add(record)
            writeRecords(appContext, records.takeLast(SMS_PENDING_LIMIT))
            EdgeLinkLog.info(
                "sms.android.pending_enqueued id=${record.id} addressFp=${AndroidSmsSync.fingerprint(record.address)}"
            )
        } else {
            EdgeLinkLog.info("sms.android.pending_duplicate id=${record.id}")
        }
        return record
    }

    @Synchronized
    fun pending(context: Context, limit: Int = SMS_PENDING_LIMIT): List<PendingSmsRecord> =
        readRecords(context.applicationContext).take(limit)

    @Synchronized
    fun acknowledge(context: Context, ids: Collection<String>): List<PendingSmsRecord> {
        if (ids.isEmpty()) {
            return emptyList()
        }
        val idSet = ids.toSet()
        val records = readRecords(context.applicationContext)
        val acknowledged = records.filter { it.id in idSet }
        if (acknowledged.isNotEmpty()) {
            writeRecords(context.applicationContext, records.filterNot { it.id in idSet })
        }
        return acknowledged
    }

    private fun pendingId(address: String, text: String, timestampMs: Long): String {
        val normalizedAddress = address.trim()
        val stableHash = AndroidSmsSync.fingerprint("$normalizedAddress\n$timestampMs\n$text")
        return "sms:received:$timestampMs:$stableHash"
    }

    private fun readRecords(context: Context): List<PendingSmsRecord> {
        val raw = prefs(context).getString(SMS_PENDING_KEY, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString<List<PendingSmsRecord>>(raw)
        }.getOrElse { error ->
            EdgeLinkLog.error("sms.android.pending_decode_failed", error)
            emptyList()
        }
    }

    private fun writeRecords(context: Context, records: List<PendingSmsRecord>) {
        prefs(context).edit()
            .putString(SMS_PENDING_KEY, json.encodeToString(records))
            .commit()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(SMS_PENDING_PREFS, Context.MODE_PRIVATE)
}

@Serializable
data class PendingSmsRecord(
    val id: String,
    val address: String,
    val text: String,
    val timestampMs: Long
)
