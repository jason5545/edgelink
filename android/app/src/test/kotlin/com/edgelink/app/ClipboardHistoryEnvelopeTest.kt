package com.edgelink.app

import com.edgelink.core.ClipboardHistoryItemBody
import com.edgelink.core.ClipboardHistoryRequestBody
import com.edgelink.core.ClipboardHistoryResponseBody
import com.edgelink.core.ClipboardKind
import com.edgelink.core.ClipboardSetBody
import com.edgelink.core.Envelope
import com.edgelink.core.EnvelopeCodec
import com.edgelink.core.EnvelopeTypes
import com.edgelink.core.StatusCapsBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClipboardHistoryEnvelopeTest {

    @Test
    fun clipboardKindIntMapping() {
        assertEquals(0, ClipboardKind.TEXT.intValue)
        assertEquals(1, ClipboardKind.IMAGE.intValue)
        assertEquals(2, ClipboardKind.HTML.intValue)
        assertEquals(3, ClipboardKind.FILE.intValue)
        assertEquals(ClipboardKind.TEXT, ClipboardKind.fromInt(0))
        assertEquals(ClipboardKind.IMAGE, ClipboardKind.fromInt(1))
        assertEquals(ClipboardKind.HTML, ClipboardKind.fromInt(2))
        assertEquals(ClipboardKind.FILE, ClipboardKind.fromInt(3))
        assertNull(ClipboardKind.fromInt(99))
        assertEquals(ClipboardKind.IMAGE, ClipboardKind.fromWire("image"))
        assertEquals("image", ClipboardKind.IMAGE.wireName)
        assertNull(ClipboardKind.fromWire("unknown"))
    }

    @Test
    fun clipboardSetLegacyPayloadDecodes() {
        val json = """{"t":"clipboard.set","b":{"text":"hi","ts":1751941000,"hash":"abc"}}"""
        val envelope = EnvelopeCodec.json.decodeFromString<Envelope<ClipboardSetBody>>(json)
        assertEquals(EnvelopeTypes.CLIPBOARD_SET, envelope.t)
        assertEquals("hi", envelope.b.text)
        assertEquals(1751941000L, envelope.b.ts)
        assertEquals("abc", envelope.b.hash)
        assertNull(envelope.b.kind)
        assertNull(envelope.b.thumbnailBase64)
        assertNull(envelope.b.sourceDeviceId)
    }

    @Test
    fun clipboardSetExtendedRoundTrip() {
        val body = ClipboardSetBody(
            text = "",
            ts = 1751941001L,
            hash = "h",
            kind = ClipboardKind.IMAGE.wireName,
            thumbnailBase64 = "iVBOR",
            sourceDeviceId = "137245816"
        )
        val bytes = EnvelopeCodec.encode(EnvelopeTypes.CLIPBOARD_SET, body)
        val envelope = EnvelopeCodec.json.decodeFromString<Envelope<ClipboardSetBody>>(bytes.decodeToString())
        assertEquals(EnvelopeTypes.CLIPBOARD_SET, envelope.t)
        assertEquals(ClipboardKind.IMAGE.wireName, envelope.b.kind)
        assertEquals("iVBOR", envelope.b.thumbnailBase64)
        assertEquals("137245816", envelope.b.sourceDeviceId)
    }

    @Test
    fun statusCapsRoundTrip() {
        val body = StatusCapsBody(clipboardHistory = true, clipboardThumbnail = false)
        val bytes = EnvelopeCodec.encode(EnvelopeTypes.STATUS_CAPS, body)
        val envelope = EnvelopeCodec.json.decodeFromString<Envelope<StatusCapsBody>>(bytes.decodeToString())
        assertEquals(EnvelopeTypes.STATUS_CAPS, envelope.t)
        assertEquals(true, envelope.b.clipboardHistory)
        assertEquals(false, envelope.b.clipboardThumbnail)
    }

    @Test
    fun clipboardHistoryRequestRoundTrip() {
        val body = ClipboardHistoryRequestBody(sinceTs = 1751940600L, limit = 20)
        val bytes = EnvelopeCodec.encode(EnvelopeTypes.CLIPBOARD_HISTORY_REQUEST, body)
        val envelope = EnvelopeCodec.json.decodeFromString<Envelope<ClipboardHistoryRequestBody>>(bytes.decodeToString())
        assertEquals(EnvelopeTypes.CLIPBOARD_HISTORY_REQUEST, envelope.t)
        assertEquals(1751940600L, envelope.b.sinceTs)
        assertEquals(20, envelope.b.limit)
    }

    @Test
    fun clipboardHistoryResponseRoundTrip() {
        val item = ClipboardHistoryItemBody(
            id = "137245816#1751941001-0",
            kind = ClipboardKind.IMAGE.wireName,
            ts = 1751941001L,
            hash = "h",
            thumbnailBase64 = "iVBOR",
            sourceDeviceId = "137245816"
        )
        val response = ClipboardHistoryResponseBody(items = listOf(item))
        val bytes = EnvelopeCodec.encode(EnvelopeTypes.CLIPBOARD_HISTORY_RESPONSE, response)
        val envelope = EnvelopeCodec.json.decodeFromString<Envelope<ClipboardHistoryResponseBody>>(bytes.decodeToString())
        assertEquals(1, envelope.b.items.size)
        val decoded = envelope.b.items[0]
        assertEquals("137245816#1751941001-0", decoded.id)
        assertEquals(ClipboardKind.IMAGE.wireName, decoded.kind)
        assertEquals("iVBOR", decoded.thumbnailBase64)
        assertEquals("137245816", decoded.sourceDeviceId)
    }
}