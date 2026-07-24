import XCTest
@testable import EdgeLinkKit

final class LyraTunnelProtocolTests: XCTestCase {
    // MARK: - TunnelActionFrameConnect round-trip

    func testConnectRoundTrip() {
        let connect = TunnelActionFrameConnect(
            tunnelHandle: 42,
            destinationAddress: "127.0.0.1:5555",
            feature: TunnelFeature(version: 1, maxConnections: 8, maxPayloadSize: 32768)
        )
        let data = connect.serialized()
        let parsed = TunnelActionFrameConnect(parsing: data)
        XCTAssertEqual(parsed?.tunnelHandle, 42)
        XCTAssertEqual(parsed?.destinationAddress, "127.0.0.1:5555")
        XCTAssertEqual(parsed?.feature?.version, 1)
        XCTAssertEqual(parsed?.feature?.maxConnections, 8)
        XCTAssertEqual(parsed?.feature?.maxPayloadSize, 32768)
    }

    func testConnectWithoutFeature() {
        let connect = TunnelActionFrameConnect(tunnelHandle: 1, destinationAddress: "10.0.0.1:8080")
        let data = connect.serialized()
        let parsed = TunnelActionFrameConnect(parsing: data)
        XCTAssertEqual(parsed?.tunnelHandle, 1)
        XCTAssertEqual(parsed?.destinationAddress, "10.0.0.1:8080")
        XCTAssertNil(parsed?.feature)
    }

    // MARK: - PushData round-trip

    func testPushDataRoundTrip() {
        let payload = Data((0..<1024).map { UInt8($0 % 256) })
        let pushData = TunnelActionFramePushData(tunnelHandle: 7, payload: payload, seq: 3)
        let data = pushData.serialized()
        let parsed = TunnelActionFramePushData(parsing: data)
        XCTAssertEqual(parsed?.tunnelHandle, 7)
        XCTAssertEqual(parsed?.payload, payload)
        XCTAssertEqual(parsed?.seq, 3)
    }

    func testPushDataEmptyPayload() {
        let pushData = TunnelActionFramePushData(tunnelHandle: 1, payload: Data(), seq: 0)
        let data = pushData.serialized()
        let parsed = TunnelActionFramePushData(parsing: data)
        XCTAssertEqual(parsed?.tunnelHandle, 1)
        XCTAssertEqual(parsed?.payload, Data())
    }

    // MARK: - AckData round-trip

    func testAckDataRoundTrip() {
        let ack = TunnelActionFrameAckData(tunnelHandle: 5, ackedBytes: 65536)
        let data = ack.serialized()
        let parsed = TunnelActionFrameAckData(parsing: data)
        XCTAssertEqual(parsed?.tunnelHandle, 5)
        XCTAssertEqual(parsed?.ackedBytes, 65536)
    }

    // MARK: - Accept/Reject/Finish/Pause/Resume round-trip

    func testAcceptRoundTrip() {
        let accept = TunnelActionFrameAccept(tunnelHandle: 99)
        let parsed = TunnelActionFrameAccept(parsing: accept.serialized())
        XCTAssertEqual(parsed?.tunnelHandle, 99)
    }

    func testRejectRoundTrip() {
        let reject = TunnelActionFrameReject(tunnelHandle: 3, reason: 2)
        let parsed = TunnelActionFrameReject(parsing: reject.serialized())
        XCTAssertEqual(parsed?.tunnelHandle, 3)
        XCTAssertEqual(parsed?.reason, 2)
    }

    func testFinishRoundTrip() {
        let finish = TunnelActionFrameFinish(tunnelHandle: 10)
        let parsed = TunnelActionFrameFinish(parsing: finish.serialized())
        XCTAssertEqual(parsed?.tunnelHandle, 10)
    }

    func testPauseRoundTrip() {
        let pause = TunnelActionFramePause(tunnelHandle: 11)
        let parsed = TunnelActionFramePause(parsing: pause.serialized())
        XCTAssertEqual(parsed?.tunnelHandle, 11)
    }

    func testResumeRoundTrip() {
        let resume = TunnelActionFrameResume(tunnelHandle: 12)
        let parsed = TunnelActionFrameResume(parsing: resume.serialized())
        XCTAssertEqual(parsed?.tunnelHandle, 12)
    }

    // MARK: - Error round-trip

    func testErrorRoundTrip() {
        let error = TunnelActionFrameError(tunnelHandle: 4, code: 52008, message: "timeout")
        let parsed = TunnelActionFrameError(parsing: error.serialized())
        XCTAssertEqual(parsed?.tunnelHandle, 4)
        XCTAssertEqual(parsed?.code, 52008)
        XCTAssertEqual(parsed?.message, "timeout")
    }

    // MARK: - TunnelActionFrame oneof wrapper

    func testActionFrameOneofConnect() {
        let frame = TunnelActionFrame.connect(TunnelActionFrameConnect(tunnelHandle: 1, destinationAddress: "127.0.0.1:5555"))
        let data = frame.serialized()
        let parsed = TunnelActionFrame(parsing: data)
        guard case .connect(let connect) = parsed else {
            XCTFail("Expected connect frame")
            return
        }
        XCTAssertEqual(connect.tunnelHandle, 1)
        XCTAssertEqual(connect.destinationAddress, "127.0.0.1:5555")
    }

    func testActionFrameOneofPushData() {
        let payload = Data("hello tunnel".utf8)
        let frame = TunnelActionFrame.pushData(TunnelActionFramePushData(tunnelHandle: 2, payload: payload, seq: 0))
        let data = frame.serialized()
        let parsed = TunnelActionFrame(parsing: data)
        guard case .pushData(let pushData) = parsed else {
            XCTFail("Expected pushData frame")
            return
        }
        XCTAssertEqual(pushData.tunnelHandle, 2)
        XCTAssertEqual(pushData.payload, payload)
    }

    func testActionFrameTunnelHandleAccessor() {
        let frame = TunnelActionFrame.finish(TunnelActionFrameFinish(tunnelHandle: 77))
        XCTAssertEqual(frame.tunnelHandle, 77)
    }

    // MARK: - TunnelActionFramePack (batch)

    func testFramePackRoundTrip() {
        let frames: [TunnelActionFrame] = [
            .accept(TunnelActionFrameAccept(tunnelHandle: 1)),
            .pushData(TunnelActionFramePushData(tunnelHandle: 1, payload: Data([0x01, 0x02]), seq: 0)),
            .ackData(TunnelActionFrameAckData(tunnelHandle: 1, ackedBytes: 100))
        ]
        let pack = TunnelActionFramePack(frames: frames)
        let data = pack.serialized()
        let parsed = TunnelActionFramePack(parsing: data)
        XCTAssertEqual(parsed?.frames.count, 3)
        guard case .accept(let accept) = parsed?.frames[0] else { XCTFail(); return }
        XCTAssertEqual(accept.tunnelHandle, 1)
        guard case .pushData(let push) = parsed?.frames[1] else { XCTFail(); return }
        XCTAssertEqual(push.payload, Data([0x01, 0x02]))
    }

    // MARK: - TcpTunnelProfile

    func testTcpTunnelProfileRoundTrip() {
        let profile = TcpTunnelProfile(
            sourceAddress: "192.168.1.10:0",
            destinationAddress: "127.0.0.1:5555",
            proxyAddress: "192.168.1.20:15555"
        )
        let data = profile.serialized()
        let parsed = TcpTunnelProfile(parsing: data)
        XCTAssertEqual(parsed?.sourceAddress, "192.168.1.10:0")
        XCTAssertEqual(parsed?.destinationAddress, "127.0.0.1:5555")
        XCTAssertEqual(parsed?.proxyAddress, "192.168.1.20:15555")
    }

    // MARK: - TunnelCapacity

    func testTunnelCapacityRoundTrip() {
        let capacity = TunnelCapacity(maxTunnels: 32, supported: true)
        let data = capacity.serialized()
        let parsed = TunnelCapacity(parsing: data)
        XCTAssertEqual(parsed?.maxTunnels, 32)
        XCTAssertEqual(parsed?.supported, true)
    }

    // MARK: - TunnelFeature

    func testTunnelFeatureRoundTrip() {
        let feature = TunnelFeature(version: 2, maxConnections: 64, maxPayloadSize: 131072)
        let data = feature.serialized()
        let parsed = TunnelFeature(parsing: data)
        XCTAssertEqual(parsed?.version, 2)
        XCTAssertEqual(parsed?.maxConnections, 64)
        XCTAssertEqual(parsed?.maxPayloadSize, 131072)
    }

    // MARK: - TunnelPortPairInfoFrame

    func testPortPairInfoRoundTrip() {
        let info = TunnelPortPairInfoFrame(localPort: 15555, remotePort: 5555)
        let data = info.serialized()
        let parsed = TunnelPortPairInfoFrame(parsing: data)
        XCTAssertEqual(parsed?.localPort, 15555)
        XCTAssertEqual(parsed?.remotePort, 5555)
    }
}
