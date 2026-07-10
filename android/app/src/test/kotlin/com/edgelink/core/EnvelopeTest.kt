package com.edgelink.core

import org.junit.Assert.assertEquals
import org.junit.Test

class EnvelopeTest {
    @Test
    fun screenSessionBodiesRoundTrip() {
        val startBytes = EnvelopeCodec.encode(EnvelopeTypes.SCREEN_START, EmptyBody)
        assertEquals(EnvelopeTypes.SCREEN_START, EnvelopeCodec.type(startBytes))

        val metaBytes = EnvelopeCodec.encode(
            EnvelopeTypes.SCREEN_META,
            ScreenMetaBody(w = 1080, h = 2400, scale = 1.0, dpi = 420)
        )
        val meta = EnvelopeCodec.decode<ScreenMetaBody>(metaBytes)
        assertEquals(EnvelopeTypes.SCREEN_META, meta.t)
        assertEquals(ScreenMetaBody(w = 1080, h = 2400, scale = 1.0, dpi = 420), meta.b)

        val visibilityBytes = EnvelopeCodec.encode(
            EnvelopeTypes.SCREEN_VIEWER_VISIBILITY,
            ScreenViewerVisibilityBody(visible = false)
        )
        val visibility = EnvelopeCodec.decode<ScreenViewerVisibilityBody>(visibilityBytes)
        assertEquals(EnvelopeTypes.SCREEN_VIEWER_VISIBILITY, visibility.t)
        assertEquals(ScreenViewerVisibilityBody(visible = false), visibility.b)

        val pointerBytes = EnvelopeCodec.encode(
            EnvelopeTypes.CTRL_POINTER,
            CtrlPointerBody(x = 540, y = 1200, action = "wheel", wheelDy = -120)
        )
        val pointer = EnvelopeCodec.decode<CtrlPointerBody>(pointerBytes)
        assertEquals(EnvelopeTypes.CTRL_POINTER, pointer.t)
        assertEquals(CtrlPointerBody(x = 540, y = 1200, action = "wheel", wheelDy = -120), pointer.b)

        val globalBytes = EnvelopeCodec.encode(EnvelopeTypes.CTRL_GLOBAL, CtrlGlobalBody(action = "back"))
        val global = EnvelopeCodec.decode<CtrlGlobalBody>(globalBytes)
        assertEquals(EnvelopeTypes.CTRL_GLOBAL, global.t)
        assertEquals(CtrlGlobalBody(action = "back"), global.b)
    }

    @Test
    fun rtcSignalingBodiesRoundTrip() {
        val offerBytes = EnvelopeCodec.encode(EnvelopeTypes.RTC_OFFER, RtcSdpBody(sdp = "v=0\r\n..."))
        val offer = EnvelopeCodec.decode<RtcSdpBody>(offerBytes)
        assertEquals(EnvelopeTypes.RTC_OFFER, offer.t)
        assertEquals(RtcSdpBody(sdp = "v=0\r\n..."), offer.b)

        val answerBytes = EnvelopeCodec.encode(EnvelopeTypes.RTC_ANSWER, RtcSdpBody(sdp = "v=0\r\nanswer"))
        val answer = EnvelopeCodec.decode<RtcSdpBody>(answerBytes)
        assertEquals(EnvelopeTypes.RTC_ANSWER, answer.t)
        assertEquals(RtcSdpBody(sdp = "v=0\r\nanswer"), answer.b)

        val iceBytes = EnvelopeCodec.encode(
            EnvelopeTypes.RTC_ICE,
            RtcIceBody(mid = "0", index = 0, candidate = "candidate:...")
        )
        val ice = EnvelopeCodec.decode<RtcIceBody>(iceBytes)
        assertEquals(EnvelopeTypes.RTC_ICE, ice.t)
        assertEquals(RtcIceBody(mid = "0", index = 0, candidate = "candidate:..."), ice.b)
    }

    @Test
    fun smsBodiesRoundTrip() {
        val messageBytes = EnvelopeCodec.encode(
            EnvelopeTypes.SMS_MESSAGE,
            SmsMessageBody(
                id = "sms:inbox:42",
                sourceDeviceId = "123456789",
                sourcePlatform = "android",
                address = "123720",
                text = "hello",
                direction = "inbound",
                isBackfill = true,
                ts = 1783510253
            )
        )
        val message = EnvelopeCodec.decode<SmsMessageBody>(messageBytes)
        assertEquals(EnvelopeTypes.SMS_MESSAGE, message.t)
        assertEquals("123720", message.b.address)
        assertEquals(true, message.b.isBackfill)

        val sendBytes = EnvelopeCodec.encode(
            EnvelopeTypes.SMS_SEND,
            SmsSendBody(requestId = "req-1", to = "0912345678", text = "ping")
        )
        val send = EnvelopeCodec.decode<SmsSendBody>(sendBytes)
        assertEquals(EnvelopeTypes.SMS_SEND, send.t)
        assertEquals("0912345678", send.b.to)

        val resultBytes = EnvelopeCodec.encode(
            EnvelopeTypes.SMS_SEND_RESULT,
            SmsSendResultBody(requestId = "req-1", to = "0912345678", success = true, ts = 1783510254)
        )
        val result = EnvelopeCodec.decode<SmsSendResultBody>(resultBytes)
        assertEquals(EnvelopeTypes.SMS_SEND_RESULT, result.t)
        assertEquals(true, result.b.success)
    }

    @Test
    fun notificationBodyRoundTripsAndroidAppIcon() {
        val bytes = EnvelopeCodec.encode(
            EnvelopeTypes.NOTIFICATION_POST,
            NotificationPostBody(
                id = "android:chat:42",
                sourcePlatform = "android",
                app = "Chat",
                bundle = "com.example.chat",
                iconPngBase64 = "iVBORw0KGgo=",
                title = "Alice",
                text = "Hello",
                ts = 1_783_510_255
            )
        )

        val decoded = EnvelopeCodec.decode<NotificationPostBody>(bytes)
        assertEquals("iVBORw0KGgo=", decoded.b.iconPngBase64)

        val legacy = EnvelopeCodec.decode<NotificationPostBody>(
            """{"t":"notification.post","b":{"id":"legacy","app":"Chat","title":"Alice","text":"Hello","ts":1}}"""
                .encodeToByteArray()
        )
        assertEquals(null, legacy.b.iconPngBase64)
    }
}
