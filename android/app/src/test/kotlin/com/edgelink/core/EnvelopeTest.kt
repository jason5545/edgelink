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
}
