import EdgeLinkKit
import Foundation
import XCTest

// Pin the relay channel demux: phone-dialed channel envelopes carry the
// Mac-side port the phone bridge snooped from responseOfPeerPort ("p") and
// must land on the matching server pipe (mitrustservice); unstamped or
// unknown-port envelopes keep the legacy behavior of landing on the single
// Mac-dialed channel pipe (the cast/relayCall channel).
final class LyraRelayTransportBridgeTests: XCTestCase {
    private func makeBridge() -> LyraRelayTransportBridge {
        LyraRelayTransportBridge(sendHandler: { _ in })
    }

    private func channelEnvelope(datagram: Data, port: UInt16?) -> Data {
        let body = RelayDatagramBody(
            payload: datagram.base64EncodedString(),
            p: port.map { Int($0) }
        )
        return try! JSONEncoder().encode(Envelope(t: EnvelopeType.relayChannelDatagram, b: body))
    }

    private func dataSegment(sn: UInt32) -> Data {
        LyraMeshDatagram.encode(tick: 1, sn: sn, una: 0, payload: Data([0xAA]))
    }

    func testStampedPortRoutesToRegisteredServerPipe() async throws {
        let bridge = makeBridge()
        let serverPipe = bridge.channelPipe(port: 45_678)
        let castHit = expectation(description: "cast pipe must not fire")
        castHit.isInverted = true
        let serverHit = expectation(description: "server pipe fired")
        bridge.channel.onPeerConnected = { _ in castHit.fulfill() }
        serverPipe.onPeerConnected = { _ in serverHit.fulfill() }

        bridge.handleEnvelope(
            type: EnvelopeType.relayChannelDatagram,
            plaintext: channelEnvelope(datagram: dataSegment(sn: 0), port: 45_678)
        )

        await fulfillment(of: [serverHit, castHit], timeout: 2)
    }

    func testUnstampedEnvelopeLandsOnCastPipe() async throws {
        let bridge = makeBridge()
        let serverPipe = bridge.channelPipe(port: 45_679)
        let castHit = expectation(description: "cast pipe fired")
        let serverHit = expectation(description: "server pipe must not fire")
        serverHit.isInverted = true
        bridge.channel.onPeerConnected = { _ in castHit.fulfill() }
        serverPipe.onPeerConnected = { _ in serverHit.fulfill() }

        bridge.handleEnvelope(
            type: EnvelopeType.relayChannelDatagram,
            plaintext: channelEnvelope(datagram: dataSegment(sn: 0), port: nil)
        )

        await fulfillment(of: [castHit, serverHit], timeout: 2)
    }

    func testUnknownPortFallsBackToCastPipe() async throws {
        let bridge = makeBridge()
        _ = bridge.channelPipe(port: 45_680)
        let castHit = expectation(description: "cast pipe fired")
        bridge.channel.onPeerConnected = { _ in castHit.fulfill() }

        bridge.handleEnvelope(
            type: EnvelopeType.relayChannelDatagram,
            plaintext: channelEnvelope(datagram: dataSegment(sn: 0), port: 59_999)
        )

        await fulfillment(of: [castHit], timeout: 2)
    }

    func testRemovedPipeFallsBackToCastPipe() async throws {
        let bridge = makeBridge()
        let serverPipe = bridge.channelPipe(port: 45_681)
        bridge.removeChannelPipe(port: 45_681)
        let castHit = expectation(description: "cast pipe fired")
        let serverHit = expectation(description: "server pipe must not fire")
        serverHit.isInverted = true
        bridge.channel.onPeerConnected = { _ in castHit.fulfill() }
        serverPipe.onPeerConnected = { _ in serverHit.fulfill() }

        bridge.handleEnvelope(
            type: EnvelopeType.relayChannelDatagram,
            plaintext: channelEnvelope(datagram: dataSegment(sn: 0), port: 45_681)
        )

        await fulfillment(of: [castHit, serverHit], timeout: 2)
    }

    func testAllocateChannelPortIsUniqueWithinBridge() {
        let bridge = makeBridge()
        var seen = Set<UInt16>()
        for _ in 0..<50 {
            let port = bridge.allocateChannelPort()
            _ = bridge.channelPipe(port: port)
            XCTAssertFalse(seen.contains(port))
            seen.insert(port)
        }
    }
}
