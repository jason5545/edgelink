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

        val phoneActionBytes = EnvelopeCodec.encode(
            EnvelopeTypes.PHONE_ACTION,
            PhoneActionBody(
                requestId = "call-1",
                action = "dial",
                number = "+886912345678",
                relayHost = "10.0.0.42",
                relayPort = 7102,
                relaySessionId = "session-1",
                relayControlPort = 17104,
                lanHost = "192.168.50.10",
                lanPort = 7102,
                lanProbePort = 7103
            )
        )
        val phoneAction = EnvelopeCodec.decode<PhoneActionBody>(phoneActionBytes)
        assertEquals(EnvelopeTypes.PHONE_ACTION, phoneAction.t)
        assertEquals("dial", phoneAction.b.action)
        assertEquals("+886912345678", phoneAction.b.number)
        assertEquals("10.0.0.42", phoneAction.b.relayHost)
        assertEquals(7102, phoneAction.b.relayPort)
        assertEquals("session-1", phoneAction.b.relaySessionId)
        assertEquals(17104, phoneAction.b.relayControlPort)
        assertEquals("192.168.50.10", phoneAction.b.lanHost)
        assertEquals(7102, phoneAction.b.lanPort)
        assertEquals(7103, phoneAction.b.lanProbePort)

        val legacyPhoneAction = EnvelopeCodec.decode<PhoneActionBody>(
            """{"t":"phone.action","b":{"requestId":"legacy-call","action":"dial","relayHost":"127.0.0.1","relayPort":7102}}"""
                .encodeToByteArray()
        )
        assertEquals(null, legacyPhoneAction.b.lanHost)
        assertEquals(null, legacyPhoneAction.b.lanProbePort)

        val phoneResultBytes = EnvelopeCodec.encode(
            EnvelopeTypes.PHONE_ACTION_RESULT,
            PhoneActionResultBody(requestId = "call-1", action = "dial", success = true, ts = 1783510255)
        )
        val phoneResult = EnvelopeCodec.decode<PhoneActionResultBody>(phoneResultBytes)
        assertEquals(EnvelopeTypes.PHONE_ACTION_RESULT, phoneResult.t)
        assertEquals(true, phoneResult.b.success)

        val relayStartBytes = EnvelopeCodec.encode(
            EnvelopeTypes.PHONE_RELAY_START,
            PhoneRelayStartRequestBody(requestId = "relay-1", reason = "incallui_relayAnswer", ts = 1783510256)
        )
        val relayStart = EnvelopeCodec.decode<PhoneRelayStartRequestBody>(relayStartBytes)
        assertEquals(EnvelopeTypes.PHONE_RELAY_START, relayStart.t)
        assertEquals("incallui_relayAnswer", relayStart.b.reason)

        val relayEndpointBytes = EnvelopeCodec.encode(
            EnvelopeTypes.PHONE_RELAY_ENDPOINT,
            PhoneRelayEndpointBody(
                requestId = "relay-1",
                relayHost = "127.0.0.1",
                relayPort = 7102,
                relaySessionId = "cloudflare-session-1",
                lanHost = "192.168.50.10",
                lanPort = 7102,
                lanProbePort = 7103,
                success = true,
                ts = 1783510257
            )
        )
        val relayEndpoint = EnvelopeCodec.decode<PhoneRelayEndpointBody>(relayEndpointBytes)
        assertEquals(EnvelopeTypes.PHONE_RELAY_ENDPOINT, relayEndpoint.t)
        assertEquals("127.0.0.1", relayEndpoint.b.relayHost)
        assertEquals(7102, relayEndpoint.b.relayPort)
        assertEquals("cloudflare-session-1", relayEndpoint.b.relaySessionId)
        assertEquals("192.168.50.10", relayEndpoint.b.lanHost)
        assertEquals(7103, relayEndpoint.b.lanProbePort)

        val relayMediaBytes = EnvelopeCodec.encode(
            EnvelopeTypes.PHONE_RELAY_MEDIA,
            PhoneRelayMediaBody(
                sessionId = "cloudflare-session-1",
                direction = "android_to_mac",
                kind = "rtp",
                dataBase64 = "gIA=",
                bytes = 2,
                sequence = 7,
                ts = 1783510257
            )
        )
        val relayMedia = EnvelopeCodec.decode<PhoneRelayMediaBody>(relayMediaBytes)
        assertEquals(EnvelopeTypes.PHONE_RELAY_MEDIA, relayMedia.t)
        assertEquals("cloudflare-session-1", relayMedia.b.sessionId)
        assertEquals("android_to_mac", relayMedia.b.direction)
        assertEquals(7, relayMedia.b.sequence)

        val mirrorMediaBytes = EnvelopeCodec.encode(
            EnvelopeTypes.MILINK_MIRROR_MEDIA,
            MiLinkMirrorMediaBody(
                sessionId = "mirror-session-1",
                direction = "android_to_mac",
                kind = "rtp",
                dataBase64 = "gIA=",
                bytes = 2,
                sequence = 8,
                ts = 1783510258
            )
        )
        val mirrorMedia = EnvelopeCodec.decode<MiLinkMirrorMediaBody>(mirrorMediaBytes)
        assertEquals(EnvelopeTypes.MILINK_MIRROR_MEDIA, mirrorMedia.t)
        assertEquals("mirror-session-1", mirrorMedia.b.sessionId)
        assertEquals("android_to_mac", mirrorMedia.b.direction)
        assertEquals(8, mirrorMedia.b.sequence)

        val phoneStatusBytes = EnvelopeCodec.encode(
            EnvelopeTypes.PHONE_CALL_STATUS,
            PhoneCallStatusBody(
                callId = "call-1",
                state = "ringing",
                handle = "+886912345678",
                displayName = "客服",
                direction = "incoming",
                canAnswer = true,
                canHangUp = true,
                isActive = false,
                reason = "added",
                ts = 1783510258
            )
        )
        val phoneStatus = EnvelopeCodec.decode<PhoneCallStatusBody>(phoneStatusBytes)
        assertEquals(EnvelopeTypes.PHONE_CALL_STATUS, phoneStatus.t)
        assertEquals("ringing", phoneStatus.b.state)
        assertEquals(true, phoneStatus.b.canAnswer)
        assertEquals("客服", phoneStatus.b.displayName)
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

    @Test
    fun miLinkStatusBodyRoundTrips() {
        val bytes = EnvelopeCodec.encode(
            EnvelopeTypes.MILINK_STATUS,
            MiLinkStatusBody(
                sourceDeviceId = "android-1",
                available = true,
                rootProbeOk = true,
                attributionProbeOk = false,
                messengerTransportOk = true,
                castServiceOk = true,
                phoneContinuityOk = true,
                phoneCallRelayServiceOk = true,
                phoneMediaRelayCallbackOk = false,
                phoneRemoteDeviceCount = 2,
                phoneMediaRelayCandidateCount = 1,
                services = listOf(
                    MiLinkServiceCapabilityBody(
                        id = "xiaomi.mirror.synergy",
                        packageName = "com.xiaomi.mirror",
                        appName = "com.xiaomi.mirror",
                        serviceName = "synergy",
                        category = "screen",
                        route = "xiaomi.mirror",
                        available = true,
                        preferred = true,
                        bindAction = "com.xiaomi.mirror.ACTION_SYNERGY_SERVICE",
                        evidence = "bind=ok"
                    )
                ),
                preferredRoutes = mapOf("screen" to "xiaomi.mirror.synergy"),
                summary = "MiLink messenger transport ok",
                ts = 1_783_510_256
            )
        )

        val decoded = EnvelopeCodec.decode<MiLinkStatusBody>(bytes)
        assertEquals(EnvelopeTypes.MILINK_STATUS, decoded.t)
        assertEquals("edgelink.secure", decoded.b.route)
        assertEquals(false, decoded.b.officialDiscoveryRequired)
        assertEquals(true, decoded.b.messengerTransportOk)
        assertEquals(true, decoded.b.castServiceOk)
        assertEquals(true, decoded.b.phoneContinuityOk)
        assertEquals(true, decoded.b.phoneCallRelayServiceOk)
        assertEquals(false, decoded.b.phoneMediaRelayCallbackOk)
        assertEquals(2, decoded.b.phoneRemoteDeviceCount)
        assertEquals(1, decoded.b.phoneMediaRelayCandidateCount)
        assertEquals("xiaomi.mirror.synergy", decoded.b.preferredRoutes["screen"])
        assertEquals("synergy", decoded.b.services.single().serviceName)
    }

    @Test
    fun miLinkFrameBodyRoundTrips() {
        val bytes = EnvelopeCodec.encode(
            EnvelopeTypes.MILINK_FRAME,
            MiLinkFrameBody(
                sourceDeviceId = "android-1",
                clientNo = "10340-30593",
                sequence = 7,
                dataBase64 = "AQIDBA==",
                bytes = 4,
                hasNext = false,
                ts = 1_783_510_257
            )
        )

        val decoded = EnvelopeCodec.decode<MiLinkFrameBody>(bytes)
        assertEquals(EnvelopeTypes.MILINK_FRAME, decoded.t)
        assertEquals("edgelink.secure", decoded.b.route)
        assertEquals("10340-30593", decoded.b.clientNo)
        assertEquals(7, decoded.b.sequence)
        assertEquals("AQIDBA==", decoded.b.dataBase64)
        assertEquals(4, decoded.b.bytes)
    }

    @Test
    fun miLinkCommandBodiesRoundTrip() {
        val commandBytes = EnvelopeCodec.encode(
            EnvelopeTypes.MILINK_COMMAND,
            MiLinkCommandBody(
                requestId = "req-1",
                command = "xiaomi.mirror.startMainDisplay",
                args = emptyMap(),
                ts = 1_783_510_258
            )
        )
        val command = EnvelopeCodec.decode<MiLinkCommandBody>(commandBytes)
        assertEquals(EnvelopeTypes.MILINK_COMMAND, command.t)
        assertEquals("xiaomi.mirror.startMainDisplay", command.b.command)
        assertEquals(null, command.b.args["remoteDeviceId"])

        val resultBytes = EnvelopeCodec.encode(
            EnvelopeTypes.MILINK_COMMAND_RESULT,
            MiLinkCommandResultBody(
                requestId = "req-1",
                command = "xiaomi.mirror.startMainDisplay",
                success = true,
                route = "xiaomi.mirror",
                message = "value=0",
                data = mapOf("value" to "0"),
                ts = 1_783_510_259
            )
        )
        val result = EnvelopeCodec.decode<MiLinkCommandResultBody>(resultBytes)
        assertEquals(EnvelopeTypes.MILINK_COMMAND_RESULT, result.t)
        assertEquals(true, result.b.success)
        assertEquals("xiaomi.mirror", result.b.route)
        assertEquals("0", result.b.data["value"])
    }

    @Test
    fun batteryStatusBodyRoundTrip() {
        val fullBytes = EnvelopeCodec.encode(
            EnvelopeTypes.BATTERY_STATUS,
            BatteryStatusBody(level = 85, charging = true, plugged = "usb", temperature = 27.5, ts = 1_751_941_000)
        )
        assertEquals(EnvelopeTypes.BATTERY_STATUS, EnvelopeCodec.type(fullBytes))
        val full = EnvelopeCodec.decode<BatteryStatusBody>(fullBytes)
        assertEquals(
            BatteryStatusBody(level = 85, charging = true, plugged = "usb", temperature = 27.5, ts = 1_751_941_000),
            full.b
        )

        val minimalBytes = EnvelopeCodec.encode(
            EnvelopeTypes.BATTERY_STATUS,
            BatteryStatusBody(level = 19, charging = false, ts = 1_751_941_100)
        )
        val minimal = EnvelopeCodec.decode<BatteryStatusBody>(minimalBytes)
        assertEquals(19, minimal.b.level)
        assertEquals(false, minimal.b.charging)
        assertEquals(null, minimal.b.plugged)
        assertEquals(null, minimal.b.temperature)

        val wireBytes = """{"t":"battery.status","b":{"level":42,"charging":false,"ts":1751941200}}"""
            .encodeToByteArray()
        val wire = EnvelopeCodec.decode<BatteryStatusBody>(wireBytes)
        assertEquals(BatteryStatusBody(level = 42, charging = false, ts = 1_751_941_200), wire.b)
    }
}
