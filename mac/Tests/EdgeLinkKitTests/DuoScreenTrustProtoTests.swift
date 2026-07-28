import EdgeLinkKit
import Foundation
import XCTest

final class DuoScreenTrustProtoTests: XCTestCase {
    func testStatusActionRoundTrip() throws {
        var action = TrustStatusAction()
        action.authFeatures = [1]
        action.eventMode = 1
        let data = DuoScreenTrustProto.encodeStatusAction(action)
        let decoded = try DuoScreenTrustProto.decodeStatusAction(data)
        XCTAssertEqual(decoded, action)
    }

    func testTrustEnvelopeRoundTrip() throws {
        var action = TrustAuthAction()
        action.feature = 1
        action.method = 5
        action.unlockUi = true
        action.extras = #"{"externalCall":false}"#
        let trust = DuoScreenTrust(sessionID: 0x0123456789ABCDEF, msg: .authAction(action))
        XCTAssertEqual(trust.type, DuoScreenTrustType.authAction.rawValue)
        let decoded = try DuoScreenTrustProto.decode(DuoScreenTrustProto.encode(trust))
        XCTAssertEqual(decoded, trust)
    }

    func testStatusEventWithAuthStatusRoundTrip() throws {
        var auth = TrustAuthStatus()
        auth.features = [1]
        auth.enableStatus = 1
        auth.bindStatus = 0
        auth.localRisk = 0
        auth.remoteRisk = 2
        var method = TrustAuthMethod()
        method.method = 5
        method.strength = 3
        auth.methods = [method]
        var event = TrustStatusEvent()
        event.code = 0
        event.localKeyguardStatus = 0
        event.remoteKeyguardStatus = 2
        event.auth = auth
        let trust = DuoScreenTrust(sessionID: 42, msg: .statusEvent(event))
        let decoded = try DuoScreenTrustProto.decode(DuoScreenTrustProto.encode(trust))
        XCTAssertEqual(decoded, trust)
    }

    func testNegativeInt32Encoding() throws {
        var event = TrustStatusEvent()
        event.code = -2000
        let decoded = try DuoScreenTrustProto.decodeStatusEvent(DuoScreenTrustProto.encodeStatusEvent(event))
        XCTAssertEqual(decoded.code, -2000)
    }

    func testNegativeMethodEncoding() throws {
        var action = TrustAuthAction()
        action.feature = 1
        action.method = -1
        action.minStrength = 2
        let decoded = try DuoScreenTrustProto.decodeAuthAction(DuoScreenTrustProto.encodeAuthAction(action))
        XCTAssertEqual(decoded.method, -1)
        XCTAssertEqual(decoded.minStrength, 2)
    }

    func testBindActionRoundTrip() throws {
        var action = TrustBindAction()
        action.feature = 1
        action.unlockUi = true
        action.reason = 1
        let trust = DuoScreenTrust(sessionID: 7, msg: .bindAction(action))
        XCTAssertEqual(trust.type, DuoScreenTrustType.bindAction.rawValue)
        let decoded = try DuoScreenTrustProto.decode(DuoScreenTrustProto.encode(trust))
        XCTAssertEqual(decoded, trust)
    }

    func testProtocolV1FrameRoundTrip() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = DuoScreenProtocolV1.encodeFrame(type: DuoScreenProtocolV1.typeTrust, payload: payload)
        XCTAssertEqual(frame.count, 9)
        XCTAssertEqual(frame[0], 68)
        XCTAssertEqual(frame[1], 4)
        XCTAssertEqual(frame[2], 0)
        let (type, decoded) = try DuoScreenProtocolV1.decodeFrame(frame)
        XCTAssertEqual(type, 68)
        XCTAssertEqual(decoded, payload)
    }

    func testProtocolV1FrameTruncated() {
        XCTAssertThrowsError(try DuoScreenProtocolV1.decodeFrame(Data([68, 10, 0, 0, 0, 1]))) { error in
            XCTAssertEqual(error as? DuoScreenProtocolV1.FrameError, .truncated)
        }
    }

    func testEventCodeRoundTrip() throws {
        for code: Int32 in [0, 1, 3, 20, 21, 256, -2000] {
            let event = TrustAuthEvent(feature: 1, code: code)
            let decoded = try DuoScreenTrustProto.decodeAuthEvent(DuoScreenTrustProto.encodeAuthEvent(event))
            XCTAssertEqual(decoded, event)
        }
    }

    func testMiscRoundTrip() throws {
        var misc = TrustMisc()
        misc.type = 1
        let trust = DuoScreenTrust(sessionID: 1, msg: .misc(misc))
        let decoded = try DuoScreenTrustProto.decode(DuoScreenTrustProto.encode(trust))
        XCTAssertEqual(decoded, trust)
    }
}
