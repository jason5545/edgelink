import EdgeLinkKit
import Foundation
import Network
import XCTest

// Relay-carried virtual pipes against real-phone wire behavior observed on
// the cloud relay path:
// - the phone's mesh service can answer a dial with an ack-command datagram
//   carrying the response payload (0x52 + data) instead of a push;
// - session teardown (LyraCastTrustSession.finishLocked) stops the pipe from
//   inside the pipe's own frame handler, which used to deadlock the serial
//   queue (SIGTRAP, __DISPATCH_WAIT_FOR_QUEUE__).
final class LyraRelayTransportTests: XCTestCase {

    private func meshDatagram(
        command: UInt8 = LyraMeshDatagram.commandPush,
        sn: UInt32,
        payload: Data
    ) -> Data {
        LyraMeshDatagram.encode(command: command, tick: LyraMeshSocket.tick(), sn: sn, una: 0, payload: payload)
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("timeout waiting for: \(description)")
    }

    // The phys-sync response that wedged the relay cast dial: command 0x52
    // with a 227-byte payload, dropped by the push-only guard. The pipe must
    // deliver payload-bearing segments regardless of the command byte.
    func testVirtualMeshPipeAcceptsAckCommandWithPayload() throws {
        let pipe = LyraVirtualMeshPipe()
        var sent = [Data]()
        pipe.attachOutbound { datagram in sent.append(datagram) }
        try pipe.start(preferredPort: nil)

        var frames = [LyraMeshPack.Frame]()
        pipe.onFrame = { frame, _, _ in frames.append(frame) }

        let payload = Data((0..<227).map { UInt8($0 & 0xFF) })
        let frame = LyraMeshPack.Frame(packType: 2, payload: payload)
        let encoded = try LyraMeshPack.encode(frame)
        pipe.deliver(datagram: meshDatagram(command: LyraMeshDatagram.commandAck, sn: 0, payload: encoded))

        waitFor("frame delivered from ack-command datagram") { frames.count == 1 }
        XCTAssertEqual(frames.first?.packType, 2)
        XCTAssertEqual(frames.first?.payload, payload)
        waitFor("ack emitted for the payload-bearing segment") { sent.count == 1 }
        let ack = try LyraMeshDatagram.decodeSegment(sent[0])
        XCTAssertEqual(ack.command, LyraMeshDatagram.commandAck)
        XCTAssertEqual(ack.payload.count, 0)
    }

    // Pure acks (no payload) carry no data and must not produce frames.
    func testVirtualMeshPipeIgnoresPureAck() throws {
        let pipe = LyraVirtualMeshPipe()
        var sent = [Data]()
        pipe.attachOutbound { datagram in sent.append(datagram) }
        try pipe.start(preferredPort: nil)

        var frameCount = 0
        pipe.onFrame = { _, _, _ in frameCount += 1 }

        pipe.deliver(datagram: LyraMeshDatagram.encodeAck(tick: LyraMeshSocket.tick(), sn: 0, una: 1))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(frameCount, 0)
        XCTAssertTrue(sent.isEmpty)
    }

    // Ordering across mixed push/ack-framed segments: sn ordering and acks
    // follow the segment sn, not the command byte.
    func testVirtualMeshPipeOrdersMixedCommandSegments() throws {
        let pipe = LyraVirtualMeshPipe()
        pipe.attachOutbound { _ in }
        try pipe.start(preferredPort: nil)

        var packTypes = [UInt8]()
        pipe.onFrame = { frame, _, _ in packTypes.append(frame.packType) }

        let frameA = try LyraMeshPack.encode(LyraMeshPack.Frame(packType: 1, payload: Data([0xAA])))
        let frameB = try LyraMeshPack.encode(LyraMeshPack.Frame(packType: 2, payload: Data([0xBB])))
        pipe.deliver(datagram: meshDatagram(command: LyraMeshDatagram.commandAck, sn: 1, payload: frameB))
        pipe.deliver(datagram: meshDatagram(command: LyraMeshDatagram.commandPush, sn: 0, payload: frameA))

        waitFor("both frames delivered in sn order") { packTypes.count == 2 }
        XCTAssertEqual(packTypes, [1, 2])
    }

    // Regression: LyraCastTrustSession.finishLocked() stops the mesh pipe from
    // inside the pipe's frame handler (the phone's logi disconnect arrives on
    // the pipe queue). The sync stop deadlocked the queue (3 crashes on
    // 2026-08-08). Must complete.
    func testVirtualMeshPipeStopFromFrameHandlerDoesNotDeadlock() throws {
        let pipe = LyraVirtualMeshPipe()
        pipe.attachOutbound { _ in }
        try pipe.start(preferredPort: nil)

        let stopped = expectation(description: "stop() returned inside frame handler")
        pipe.onFrame = { _, _, _ in
            pipe.stop()
            stopped.fulfill()
        }
        let frame = try LyraMeshPack.encode(LyraMeshPack.Frame(packType: 2, payload: Data([0x01])))
        pipe.deliver(datagram: meshDatagram(sn: 0, payload: frame))
        wait(for: [stopped], timeout: 5)
    }

    // Channel side of the same ack-framed behavior: a 0x52 datagram with
    // payload counts as data (peer announced + acked), a pure ack is ignored.
    func testVirtualChannelPipeAcceptsAckCommandWithPayload() throws {
        let pipe = LyraVirtualChannelPipe()
        var sent = [Data]()
        pipe.attachOutbound { datagram in sent.append(datagram) }

        var peerConnected = false
        pipe.onPeerConnected = { _ in peerConnected = true }

        pipe.deliver(datagram: LyraMeshDatagram.encodeAck(tick: LyraMeshSocket.tick(), sn: 0, una: 1))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(peerConnected)
        XCTAssertTrue(sent.isEmpty)

        pipe.deliver(datagram: meshDatagram(command: LyraMeshDatagram.commandAck, sn: 0, payload: Data([0x01, 0x01])))
        waitFor("peer announced after payload-bearing ack") { peerConnected }
        waitFor("ack emitted") { sent.count == 1 }
        let ack = try LyraMeshDatagram.decodeSegment(sent[0])
        XCTAssertEqual(ack.command, LyraMeshDatagram.commandAck)
    }

    // Channel teardown from inside the pipe's own handlers must not deadlock
    // either (same crash shape as the mesh pipe).
    func testVirtualChannelPipeStopFromPeerConnectedHandlerDoesNotDeadlock() {
        let pipe = LyraVirtualChannelPipe()
        pipe.attachOutbound { _ in }
        let stopped = expectation(description: "stop() returned inside peer-connected handler")
        pipe.onPeerConnected = { _ in
            pipe.stop()
            stopped.fulfill()
        }
        pipe.deliver(datagram: meshDatagram(sn: 0, payload: Data([0x01])))
        wait(for: [stopped], timeout: 5)
    }

    // The fake-phone knob: flipping dataCommand reproduces the real phone's
    // ack-framed responses for the mirror-over-relay E2E tests.
    func testDataCommandStampsOutboundSegments() throws {
        let pipe = LyraVirtualMeshPipe()
        var sent = [Data]()
        pipe.attachOutbound { datagram in sent.append(datagram) }
        try pipe.start(preferredPort: nil)
        pipe.dataCommand = LyraMeshDatagram.commandAck
        try pipe.send(frame: LyraMeshPack.Frame(packType: 2, payload: Data([0x42])), to: "127.0.0.1", port: 1)
        waitFor("datagram sent") { sent.count == 1 }
        let segment = try LyraMeshDatagram.decodeSegment(sent[0])
        XCTAssertEqual(segment.command, LyraMeshDatagram.commandAck)
    }
}
