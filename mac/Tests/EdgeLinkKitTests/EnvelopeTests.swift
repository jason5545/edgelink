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
}
