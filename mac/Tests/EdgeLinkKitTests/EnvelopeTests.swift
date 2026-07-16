import XCTest
@testable import EdgeLinkKit

final class EnvelopeTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testScreenSessionBodiesRoundTrip() throws {
        let startData = try encoder.encode(Envelope(t: EnvelopeType.screenStart, b: EmptyBody()))
        let start = try decoder.decode(Envelope<EmptyBody>.self, from: startData)
        XCTAssertEqual(start.t, "screen.start")

        let metaData = try encoder.encode(
            Envelope(t: EnvelopeType.screenMeta, b: ScreenMetaBody(w: 1080, h: 2400, scale: 1.0, dpi: 420))
        )
        let meta = try decoder.decode(Envelope<ScreenMetaBody>.self, from: metaData)
        XCTAssertEqual(meta.t, "screen.meta")
        XCTAssertEqual(meta.b, ScreenMetaBody(w: 1080, h: 2400, scale: 1.0, dpi: 420))

        let visibilityData = try encoder.encode(
            Envelope(t: EnvelopeType.screenViewerVisibility, b: ScreenViewerVisibilityBody(visible: false))
        )
        let visibility = try decoder.decode(Envelope<ScreenViewerVisibilityBody>.self, from: visibilityData)
        XCTAssertEqual(visibility.t, "screen.viewerVisibility")
        XCTAssertEqual(visibility.b, ScreenViewerVisibilityBody(visible: false))

        let pointerData = try encoder.encode(
            Envelope(t: EnvelopeType.ctrlPointer, b: CtrlPointerBody(x: 540, y: 1200, action: "wheel", wheelDy: -120))
        )
        let pointer = try decoder.decode(Envelope<CtrlPointerBody>.self, from: pointerData)
        XCTAssertEqual(pointer.t, "ctrl.pointer")
        XCTAssertEqual(pointer.b, CtrlPointerBody(x: 540, y: 1200, action: "wheel", wheelDy: -120))

        let globalData = try encoder.encode(Envelope(t: EnvelopeType.ctrlGlobal, b: CtrlGlobalBody(action: "back")))
        let global = try decoder.decode(Envelope<CtrlGlobalBody>.self, from: globalData)
        XCTAssertEqual(global.t, "ctrl.global")
        XCTAssertEqual(global.b, CtrlGlobalBody(action: "back"))
    }

    func testRtcSignalingBodiesRoundTrip() throws {
        let offerData = try encoder.encode(Envelope(t: EnvelopeType.rtcOffer, b: RtcSdpBody(sdp: "v=0\r\n...")))
        let offer = try decoder.decode(Envelope<RtcSdpBody>.self, from: offerData)
        XCTAssertEqual(offer.t, "rtc.offer")
        XCTAssertEqual(offer.b, RtcSdpBody(sdp: "v=0\r\n..."))

        let answerData = try encoder.encode(Envelope(t: EnvelopeType.rtcAnswer, b: RtcSdpBody(sdp: "v=0\r\nanswer")))
        let answer = try decoder.decode(Envelope<RtcSdpBody>.self, from: answerData)
        XCTAssertEqual(answer.t, "rtc.answer")
        XCTAssertEqual(answer.b, RtcSdpBody(sdp: "v=0\r\nanswer"))

        let iceData = try encoder.encode(
            Envelope(t: EnvelopeType.rtcIce, b: RtcIceBody(mid: "0", index: 0, candidate: "candidate:..."))
        )
        let ice = try decoder.decode(Envelope<RtcIceBody>.self, from: iceData)
        XCTAssertEqual(ice.t, "rtc.ice")
        XCTAssertEqual(ice.b, RtcIceBody(mid: "0", index: 0, candidate: "candidate:..."))
    }

    func testSmsBodiesRoundTrip() throws {
        let messageData = try encoder.encode(
            Envelope(
                t: EnvelopeType.smsMessage,
                b: SmsMessageBody(
                    id: "sms:inbox:42",
                    sourceDeviceId: "123456789",
                    sourcePlatform: "android",
                    address: "123720",
                    text: "hello",
                    direction: "inbound",
                    isBackfill: true,
                    ts: 1_783_510_253
                )
            )
        )
        let message = try decoder.decode(Envelope<SmsMessageBody>.self, from: messageData)
        XCTAssertEqual(message.t, "sms.message")
        XCTAssertEqual(message.b.address, "123720")
        XCTAssertTrue(message.b.isBackfill)

        let sendData = try encoder.encode(
            Envelope(t: EnvelopeType.smsSend, b: SmsSendBody(requestId: "req-1", to: "0912345678", text: "ping"))
        )
        let send = try decoder.decode(Envelope<SmsSendBody>.self, from: sendData)
        XCTAssertEqual(send.t, "sms.send")
        XCTAssertEqual(send.b.to, "0912345678")

        let resultData = try encoder.encode(
            Envelope(
                t: EnvelopeType.smsSendResult,
                b: SmsSendResultBody(requestId: "req-1", to: "0912345678", success: true, ts: 1_783_510_254)
            )
        )
        let result = try decoder.decode(Envelope<SmsSendResultBody>.self, from: resultData)
        XCTAssertEqual(result.t, "sms.send.result")
        XCTAssertTrue(result.b.success)

        let phoneActionData = try encoder.encode(
            Envelope(
                t: EnvelopeType.phoneAction,
                b: PhoneActionBody(
                    requestId: "call-1",
                    action: "dial",
                    number: "+886912345678",
                    relayHost: "10.0.0.42",
                    relayPort: 7102,
                    relaySessionId: "session-1",
                    relayControlPort: 17104
                )
            )
        )
        let phoneAction = try decoder.decode(Envelope<PhoneActionBody>.self, from: phoneActionData)
        XCTAssertEqual(phoneAction.t, "phone.action")
        XCTAssertEqual(phoneAction.b.action, "dial")
        XCTAssertEqual(phoneAction.b.number, "+886912345678")
        XCTAssertEqual(phoneAction.b.relayHost, "10.0.0.42")
        XCTAssertEqual(phoneAction.b.relayPort, 7102)
        XCTAssertEqual(phoneAction.b.relaySessionId, "session-1")
        XCTAssertEqual(phoneAction.b.relayControlPort, 17104)

        let phoneResultData = try encoder.encode(
            Envelope(
                t: EnvelopeType.phoneActionResult,
                b: PhoneActionResultBody(requestId: "call-1", action: "dial", success: true, ts: 1_783_510_255)
            )
        )
        let phoneResult = try decoder.decode(Envelope<PhoneActionResultBody>.self, from: phoneResultData)
        XCTAssertEqual(phoneResult.t, "phone.action.result")
        XCTAssertTrue(phoneResult.b.success)

        let relayStartData = try encoder.encode(
            Envelope(
                t: EnvelopeType.phoneRelayStart,
                b: PhoneRelayStartRequestBody(
                    requestId: "relay-1",
                    reason: "incallui_relayAnswer",
                    ts: 1_783_510_256
                )
            )
        )
        let relayStart = try decoder.decode(Envelope<PhoneRelayStartRequestBody>.self, from: relayStartData)
        XCTAssertEqual(relayStart.t, "phone.relay.start")
        XCTAssertEqual(relayStart.b.reason, "incallui_relayAnswer")

        let relayEndpointData = try encoder.encode(
            Envelope(
                t: EnvelopeType.phoneRelayEndpoint,
                b: PhoneRelayEndpointBody(
                    requestId: "relay-1",
                    relayHost: "172.238.24.219",
                    relayPort: 17104,
                    relaySessionId: "gateway-session-1",
                    relayControlPort: 17104,
                    success: true,
                    ts: 1_783_510_257
                )
            )
        )
        let relayEndpoint = try decoder.decode(Envelope<PhoneRelayEndpointBody>.self, from: relayEndpointData)
        XCTAssertEqual(relayEndpoint.t, "phone.relay.endpoint")
        XCTAssertEqual(relayEndpoint.b.relayHost, "172.238.24.219")
        XCTAssertEqual(relayEndpoint.b.relayPort, 17104)
        XCTAssertEqual(relayEndpoint.b.relaySessionId, "gateway-session-1")

        let micStatusData = try encoder.encode(
            Envelope(
                t: EnvelopeType.androidMicStatus,
                b: AndroidMicStatusBody(
                    active: true,
                    source: 6,
                    sourceName: "voice_recognition",
                    sessionId: 42,
                    silenced: false,
                    activeRecordingCount: 1,
                    reason: "callback",
                    ts: 1_783_510_256
                )
            )
        )
        let micStatus = try decoder.decode(Envelope<AndroidMicStatusBody>.self, from: micStatusData)
        XCTAssertEqual(micStatus.t, "android.mic.status")
        XCTAssertTrue(micStatus.b.active)
        XCTAssertEqual(micStatus.b.sourceName, "voice_recognition")
    }

    func testNotificationBodyRoundTripsAndroidAppIcon() throws {
        let data = try encoder.encode(
            Envelope(
                t: EnvelopeType.notificationPost,
                b: NotificationPostBody(
                    id: "android:chat:42",
                    sourcePlatform: "android",
                    app: "Chat",
                    bundle: "com.example.chat",
                    iconPngBase64: "iVBORw0KGgo=",
                    title: "Alice",
                    text: "Hello",
                    ts: 1_783_510_255
                )
            )
        )

        let decoded = try decoder.decode(Envelope<NotificationPostBody>.self, from: data)
        XCTAssertEqual(decoded.b.iconPngBase64, "iVBORw0KGgo=")

        let legacyData = Data(
            #"{"t":"notification.post","b":{"id":"legacy","app":"Chat","title":"Alice","text":"Hello","ts":1}}"#.utf8
        )
        let legacy = try decoder.decode(Envelope<NotificationPostBody>.self, from: legacyData)
        XCTAssertNil(legacy.b.iconPngBase64)
    }

    func testMiLinkStatusBodyRoundTrips() throws {
        let data = try encoder.encode(
            Envelope(
                t: EnvelopeType.miLinkStatus,
                b: MiLinkStatusBody(
                    sourceDeviceId: "android-1",
                    available: true,
                    rootProbeOk: true,
                    attributionProbeOk: false,
                    messengerTransportOk: true,
                    castServiceOk: true,
                    phoneContinuityOk: true,
                    phoneCallRelayServiceOk: true,
                    phoneMediaRelayCallbackOk: false,
                    phoneRemoteDeviceCount: 2,
                    phoneMediaRelayCandidateCount: 1,
                    summary: "MiLink messenger transport ok",
                    ts: 1_783_510_256
                )
            )
        )

        let decoded = try decoder.decode(Envelope<MiLinkStatusBody>.self, from: data)
        XCTAssertEqual(decoded.t, "milink.status")
        XCTAssertEqual(decoded.b.route, "edgelink.secure")
        XCTAssertFalse(decoded.b.officialDiscoveryRequired)
        XCTAssertTrue(decoded.b.messengerTransportOk)
        XCTAssertTrue(decoded.b.castServiceOk)
        XCTAssertTrue(decoded.b.phoneContinuityOk == true)
        XCTAssertTrue(decoded.b.phoneCallRelayServiceOk == true)
        XCTAssertFalse(decoded.b.phoneMediaRelayCallbackOk ?? true)
        XCTAssertEqual(decoded.b.phoneRemoteDeviceCount, 2)
        XCTAssertEqual(decoded.b.phoneMediaRelayCandidateCount, 1)
    }

    func testMiLinkFrameBodyRoundTrips() throws {
        let data = try encoder.encode(
            Envelope(
                t: EnvelopeType.miLinkFrame,
                b: MiLinkFrameBody(
                    sourceDeviceId: "android-1",
                    clientNo: "10340-30593",
                    sequence: 7,
                    dataBase64: "AQIDBA==",
                    bytes: 4,
                    hasNext: false,
                    ts: 1_783_510_257
                )
            )
        )

        let decoded = try decoder.decode(Envelope<MiLinkFrameBody>.self, from: data)
        XCTAssertEqual(decoded.t, "milink.frame")
        XCTAssertEqual(decoded.b.route, "edgelink.secure")
        XCTAssertEqual(decoded.b.clientNo, "10340-30593")
        XCTAssertEqual(decoded.b.sequence, 7)
        XCTAssertEqual(decoded.b.dataBase64, "AQIDBA==")
        XCTAssertEqual(decoded.b.bytes, 4)
    }
}
