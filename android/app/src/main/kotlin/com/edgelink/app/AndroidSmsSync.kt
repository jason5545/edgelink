@file:Suppress("DEPRECATION")

package com.edgelink.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.BaseColumns
import android.provider.Telephony
import android.telephony.SmsManager
import com.edgelink.core.SmsMessageBody
import com.edgelink.core.SmsSendBody
import com.edgelink.core.SmsSendResultBody
import java.security.MessageDigest
import java.time.Instant

private const val SMS_BACKFILL_LIMIT = 50
private const val SMS_MARKER_BROADCAST_ROW_ID = Long.MAX_VALUE

class AndroidSmsSync(
    private val context: Context,
    private val settingsStore: SharedPreferencesSettingsStore
) {
    private val appContext = context.applicationContext

    fun smsAccessGranted(): Boolean =
        requiredPermissions.all {
            appContext.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }

    fun readAccessGranted(): Boolean =
        appContext.checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED

    fun sendSms(body: SmsSendBody): SmsSendResultBody {
        val to = body.to.trim()
        val text = body.text.trim()
        val now = Instant.now().epochSecond
        if (to.isBlank()) {
            return SmsSendResultBody(body.requestId, body.to, success = false, error = "missing_recipient", ts = now)
        }
        if (text.isBlank()) {
            return SmsSendResultBody(body.requestId, to, success = false, error = "missing_text", ts = now)
        }
        if (appContext.checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            return SmsSendResultBody(body.requestId, to, success = false, error = "missing_send_sms_permission", ts = now)
        }

        return runCatching {
            val manager = SmsManager.getDefault()
            val parts = manager.divideMessage(text)
            if (parts.size <= 1) {
                manager.sendTextMessage(to, null, text, null, null)
            } else {
                manager.sendMultipartTextMessage(to, null, parts, null, null)
            }
            EdgeLinkLog.info("sms.android.send_queued requestId=${body.requestId} toFp=${fingerprint(to)} parts=${parts.size}")
            SmsSendResultBody(body.requestId, to, success = true, ts = now)
        }.getOrElse { error ->
            EdgeLinkLog.error("sms.android.send_failed requestId=${body.requestId} toFp=${fingerprint(to)}", error)
            SmsSendResultBody(body.requestId, to, success = false, error = error::class.java.simpleName, ts = now)
        }
    }

    fun backfillInbox(sourceDeviceId: String?): SmsBackfillBatch {
        if (!readAccessGranted()) {
            return SmsBackfillBatch(emptyList(), null)
        }

        val marker = currentMarker()
        val rows = mutableListOf<SmsRow>()
        val projection = arrayOf(
            BaseColumns._ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE
        )
        val hasMarker = marker.dateMs > 0L
        val selection = if (hasMarker) {
            "(${Telephony.Sms.DATE} > ?) OR (${Telephony.Sms.DATE} = ? AND ${BaseColumns._ID} > ?)"
        } else {
            null
        }
        val selectionArgs = if (hasMarker) {
            arrayOf(marker.dateMs.toString(), marker.dateMs.toString(), marker.rowId.toString())
        } else {
            null
        }
        val sortOrder = if (hasMarker) {
            "${Telephony.Sms.DATE} ASC, ${BaseColumns._ID} ASC"
        } else {
            "${Telephony.Sms.DATE} DESC, ${BaseColumns._ID} DESC"
        }

        appContext.contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            sortOrder
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(BaseColumns._ID)
            val addressIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.DATE)
            while (cursor.moveToNext() && rows.size < SMS_BACKFILL_LIMIT) {
                val row = SmsRow(
                    rowId = cursor.getLong(idIndex),
                    address = cursor.getString(addressIndex).orEmpty(),
                    text = cursor.getString(bodyIndex).orEmpty(),
                    dateMs = cursor.getLong(dateIndex)
                )
                if (row.text.isNotBlank()) {
                    rows.add(row)
                }
            }
        }

        val orderedRows = if (hasMarker) rows else rows.asReversed()
        val bodies = orderedRows.map { row ->
            SmsMessageBody(
                id = "sms:inbox:${row.rowId}",
                sourceDeviceId = sourceDeviceId,
                sourcePlatform = "android",
                address = row.address,
                text = row.text,
                direction = "inbound",
                isBackfill = true,
                ts = row.dateMs / 1000
            )
        }
        val nextMarker = orderedRows.lastOrNull()?.let { SmsMarker(dateMs = it.dateMs, rowId = it.rowId) }
        return SmsBackfillBatch(bodies, nextMarker)
    }

    fun messageFromBroadcast(sourceDeviceId: String?, address: String, text: String, timestampMs: Long): SmsMessageBody {
        val normalizedAddress = address.trim()
        val stableHash = fingerprint("$normalizedAddress\n$timestampMs\n$text")
        return SmsMessageBody(
            id = "sms:received:$timestampMs:$stableHash",
            sourceDeviceId = sourceDeviceId,
            sourcePlatform = "android",
            address = normalizedAddress,
            text = text,
            direction = "inbound",
            isBackfill = false,
            ts = timestampMs / 1000
        )
    }

    fun pendingBroadcastMessages(sourceDeviceId: String?): List<SmsMessageBody> =
        AndroidSmsPendingStore.pending(appContext).map { record ->
            SmsMessageBody(
                id = record.id,
                sourceDeviceId = sourceDeviceId,
                sourcePlatform = "android",
                address = record.address,
                text = record.text,
                direction = "inbound",
                isBackfill = false,
                ts = record.timestampMs / 1000
            )
        }

    fun acknowledgePendingBroadcasts(ids: Collection<String>) {
        val acknowledged = AndroidSmsPendingStore.acknowledge(appContext, ids)
        acknowledged.maxByOrNull { it.timestampMs }?.let { record ->
            markBroadcastSeen(record.timestampMs)
        }
    }

    fun markBroadcastSeen(timestampMs: Long) {
        saveMarkerIfNewer(SmsMarker(dateMs = timestampMs, rowId = SMS_MARKER_BROADCAST_ROW_ID))
    }

    fun saveMarkerIfNewer(marker: SmsMarker) {
        val current = currentMarker()
        if (marker.dateMs > current.dateMs || marker.dateMs == current.dateMs && marker.rowId > current.rowId) {
            settingsStore.saveSmsLastSeen(marker.dateMs, marker.rowId)
        }
    }

    private fun currentMarker(): SmsMarker =
        SmsMarker(
            dateMs = settingsStore.smsLastSeenDateMs(),
            rowId = settingsStore.smsLastSeenRowId()
        )

    companion object {
        val requiredPermissions = arrayOf(
            Manifest.permission.READ_SMS,
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.SEND_SMS
        )

        fun fingerprint(value: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(value.encodeToByteArray())
            return digest.take(6).joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }
    }
}

data class SmsBackfillBatch(
    val messages: List<SmsMessageBody>,
    val marker: SmsMarker?
)

data class SmsMarker(
    val dateMs: Long,
    val rowId: Long
)

private data class SmsRow(
    val rowId: Long,
    val address: String,
    val text: String,
    val dateMs: Long
)
