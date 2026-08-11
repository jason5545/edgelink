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

    // Regression (2026-08-11 live, relay path): the phone's channel client
    // KCP-dials the phone-side bridge on loopback, so its RTO is tuned for
    // ~0ms RTT — but the real ack takes a full relay RTT, so every segment
    // is retransmitted and the stateless bridge forwards each copy. The
    // pipe had no sn dedup (LyraChannelSocket has it), so a retransmitted
    // negotiation was answered again with a FRESH sn; the phone's KCP
    // accepts it as a distinct segment, and the late plaintext reply lands
    // after the phone entered encrypted mode — its channel layer hits
    // GCM DecodeFailed and DESTROYS the channel (logcat: DecodeFailed →
    // DestroyChannel → SendBytes err 33001), so the unlock 562 never
    // arrives and the Mac sat on 解鎖中 until the auth-event timeout.
    func testVirtualChannelPipeDeduplicatesRetransmittedSegments() throws {
        let pipe = LyraVirtualChannelPipe()
        var sent = [Data]()
        pipe.attachOutbound { datagram in sent.append(datagram) }
        try pipe.start(socketKey: Data(repeating: 0x42, count: 32), serverChannelId: 6)

        var negotiations = 0
        pipe.onNegotiated = { _, _ in negotiations += 1 }

        let negotiation = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 0,
            child: LyraExpressTLV.containerNode(tag: 0, children: [
                LyraExpressTLV.int32Node(tag: 0, value: 6),
                LyraExpressTLV.int32Node(tag: 1, value: 1),
                LyraExpressTLV.int32Node(tag: 2, value: 0xFF00)
            ])
        )
        pipe.deliver(datagram: meshDatagram(sn: 0, payload: negotiation))
        pipe.deliver(datagram: meshDatagram(sn: 0, payload: negotiation))
        pipe.deliver(datagram: meshDatagram(sn: 0, payload: negotiation))

        waitFor("negotiation handled") { negotiations == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(negotiations, 1, "retransmitted segments must be deduped by sn")
        // Every inbound segment still gets an ack (idempotent, stops the
        // peer's retransmits), but only ONE payload-bearing reply goes out.
        let replies = sent.filter { (try? LyraMeshDatagram.decodeSegment($0))?.payload.isEmpty == false }
        XCTAssertEqual(replies.count, 1, "duplicate negotiation replies kill the phone's channel")
        XCTAssertEqual(sent.count, 4, "one ack per inbound segment, exactly one reply")
    }

    // Out-of-order delivery (post-blackout relay reordering): neither side
    // retransmits outbound payloads on this path, so a gap never fills —
    // the pipe must process out-of-order segments on arrival instead of
    // buffering behind a permanent gap (a lost CLOSE must not stall the
    // following OPEN, live 2026-08-09 flip test).
    func testVirtualChannelPipeProcessesOutOfOrderSegmentsAcrossGaps() throws {
        let pipe = LyraVirtualChannelPipe()
        var sent = [Data]()
        pipe.attachOutbound { datagram in sent.append(datagram) }
        try pipe.start(socketKey: Data(repeating: 0x42, count: 32), serverChannelId: 6)

        var negotiated = [UInt32]()
        pipe.onNegotiated = { channelId, _ in negotiated.append(channelId) }

        let confirm = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 4,
            child: LyraExpressTLV.containerNode(tag: 4, children: [
                LyraExpressTLV.int32Node(tag: 0, value: 6),
                LyraExpressTLV.int32Node(tag: 1, value: 0xFF00)
            ])
        )
        let negotiation = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 0,
            child: LyraExpressTLV.containerNode(tag: 0, children: [
                LyraExpressTLV.int32Node(tag: 0, value: 7),
                LyraExpressTLV.int32Node(tag: 1, value: 1),
                LyraExpressTLV.int32Node(tag: 2, value: 0xFF00)
            ])
        )
        pipe.deliver(datagram: meshDatagram(sn: 1, payload: negotiation))
        waitFor("out-of-order segment processed on arrival") { negotiated == [7] }

        pipe.deliver(datagram: meshDatagram(sn: 0, payload: confirm))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        // The late sn=0 is now behind recvUna — a gap that will never fill —
        // so it is treated like a retransmit: acked, not processed.
        XCTAssertEqual(negotiated, [7])
        let replies = sent.filter { (try? LyraMeshDatagram.decodeSegment($0))?.payload.isEmpty == false }
        XCTAssertEqual(replies.count, 1, "only the negotiation request gets a reply")
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
