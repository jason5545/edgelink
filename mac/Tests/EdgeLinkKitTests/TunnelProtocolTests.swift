import XCTest
@testable import EdgeLinkKit

final class TunnelProtocolTests: XCTestCase {
    // MARK: - Chunking

    func testChunkSmallData() {
        let data = Data("hello".utf8)
        let chunks = TunnelChunker.chunk(data)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].seq, 0)
        XCTAssertEqual(chunks[0].data, data)
        XCTAssertTrue(chunks[0].isLast)
    }

    func testChunkEmptyData() {
        let chunks = TunnelChunker.chunk(Data())
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].isLast)
        XCTAssertTrue(chunks[0].data.isEmpty)
    }

    func testChunkLargeData() {
        let data = Data(count: TunnelChunker.maxChunkSize * 3 + 100)
        let chunks = TunnelChunker.chunk(data)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0].seq, 0)
        XCTAssertEqual(chunks[1].seq, 1)
        XCTAssertEqual(chunks[2].seq, 2)
        XCTAssertEqual(chunks[3].seq, 3)
        XCTAssertFalse(chunks[0].isLast)
        XCTAssertFalse(chunks[1].isLast)
        XCTAssertFalse(chunks[2].isLast)
        XCTAssertTrue(chunks[3].isLast)
        XCTAssertEqual(chunks[0].data.count, TunnelChunker.maxChunkSize)
        XCTAssertEqual(chunks[3].data.count, 100)
    }

    func testChunkReassembly() {
        let original = Data((0..<100_000).map { UInt8($0 % 256) })
        let chunks = TunnelChunker.chunk(original)
        var reassembled = Data()
        for chunk in chunks {
            reassembled.append(chunk.data)
        }
        XCTAssertEqual(reassembled, original)
    }

    // MARK: - Base64 payload

    func testPayloadBase64RoundTrip() {
        let data = Data([0x00, 0xFF, 0x80, 0x7F, 0x01])
        let base64 = TunnelChunker.payloadBase64(data)
        let decoded = TunnelChunker.payloadFromBase64(base64)
        XCTAssertEqual(decoded, data)
    }

    func testPayloadFromInvalidBase64() {
        XCTAssertNil(TunnelChunker.payloadFromBase64("not valid base64!!!"))
    }

    // MARK: - Reassembler

    func testReassemblerInOrder() {
        var reassembler = TunnelReassembler()
        let result = reassembler.append(tunnelId: "t1", streamId: 1, seq: 0, data: Data("hello".utf8), fin: true)
        XCTAssertEqual(result, Data("hello".utf8))
    }

    func testReassemblerMultiChunk() {
        var reassembler = TunnelReassembler()
        XCTAssertNil(reassembler.append(tunnelId: "t1", streamId: 1, seq: 0, data: Data("hel".utf8), fin: false))
        XCTAssertNil(reassembler.append(tunnelId: "t1", streamId: 1, seq: 1, data: Data("lo".utf8), fin: false))
        let result = reassembler.append(tunnelId: "t1", streamId: 1, seq: 2, data: Data("!".utf8), fin: true)
        XCTAssertEqual(result, Data("hello!".utf8))
    }

    func testReassemblerMultipleStreams() {
        var reassembler = TunnelReassembler()
        XCTAssertNil(reassembler.append(tunnelId: "t1", streamId: 1, seq: 0, data: Data("a".utf8), fin: false))
        XCTAssertNil(reassembler.append(tunnelId: "t1", streamId: 2, seq: 0, data: Data("x".utf8), fin: false))
        let r1 = reassembler.append(tunnelId: "t1", streamId: 1, seq: 1, data: Data("b".utf8), fin: true)
        let r2 = reassembler.append(tunnelId: "t1", streamId: 2, seq: 1, data: Data("y".utf8), fin: true)
        XCTAssertEqual(r1, Data("ab".utf8))
        XCTAssertEqual(r2, Data("xy".utf8))
    }

    func testReassemblerReset() {
        var reassembler = TunnelReassembler()
        _ = reassembler.append(tunnelId: "t1", streamId: 1, seq: 0, data: Data("a".utf8), fin: false)
        reassembler.reset(tunnelId: "t1", streamId: 1)
        let result = reassembler.append(tunnelId: "t1", streamId: 1, seq: 0, data: Data("fresh".utf8), fin: true)
        XCTAssertEqual(result, Data("fresh".utf8))
    }

    // MARK: - Allowlist

    func testAllowlistLoopbackAllowed() {
        let allowlist = TunnelAllowlist()
        XCTAssertTrue(allowlist.isAllowed(host: "127.0.0.1", port: 5555))
        XCTAssertTrue(allowlist.isAllowed(host: "::1", port: 8080))
        XCTAssertTrue(allowlist.isAllowed(host: "localhost", port: 22))
    }

    func testAllowlistPublicDenied() {
        let allowlist = TunnelAllowlist()
        XCTAssertFalse(allowlist.isAllowed(host: "8.8.8.8", port: 53))
        XCTAssertFalse(allowlist.isAllowed(host: "192.168.1.1", port: 80))
    }

    func testAllowlistCustomRule() {
        var allowlist = TunnelAllowlist()
        XCTAssertFalse(allowlist.isAllowed(host: "192.168.1.100", port: 22))
        allowlist.addRule(TunnelAllowlist.Rule(host: "192.168.1.100", port: 22))
        XCTAssertTrue(allowlist.isAllowed(host: "192.168.1.100", port: 22))
        XCTAssertFalse(allowlist.isAllowed(host: "192.168.1.100", port: 80))
    }

    func testAllowlistWildcardPort() {
        var allowlist = TunnelAllowlist()
        allowlist.addRule(TunnelAllowlist.Rule(host: "10.0.0.5", port: nil))
        XCTAssertTrue(allowlist.isAllowed(host: "10.0.0.5", port: 1))
        XCTAssertTrue(allowlist.isAllowed(host: "10.0.0.5", port: 65535))
    }

    // MARK: - Envelope body Codable

    func testTunnelOpenBodyCodable() throws {
        let body = TunnelOpenBody(tunnelId: "abc-123", direction: .local, targetHost: "127.0.0.1", targetPort: 5555, label: "adb")
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(TunnelOpenBody.self, from: data)
        XCTAssertEqual(decoded, body)
    }

    func testTunnelDataBodyCodable() throws {
        let body = TunnelDataBody(tunnelId: "t1", streamId: 3, seq: 7, payload: "aGVsbG8=", fin: false)
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(TunnelDataBody.self, from: data)
        XCTAssertEqual(decoded, body)
    }

    func testTunnelCloseBodyCodable() throws {
        let body = TunnelCloseBody(tunnelId: "t1", streamId: 1, fin: true, reset: false)
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(TunnelCloseBody.self, from: data)
        XCTAssertEqual(decoded, body)
    }

    func testTunnelErrorBodyCodable() throws {
        let body = TunnelErrorBody(tunnelId: "t1", streamId: nil, code: .notAllowed, message: "denied")
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(TunnelErrorBody.self, from: data)
        XCTAssertEqual(decoded, body)
    }

    func testTunnelFlowBodyCodable() throws {
        let body = TunnelFlowBody(tunnelId: "t1", streamId: 2, credit: 65536)
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(TunnelFlowBody.self, from: data)
        XCTAssertEqual(decoded, body)
    }

    // MARK: - Envelope type constants

    func testEnvelopeTypeConstants() {
        XCTAssertEqual(EnvelopeType.tunnelOpen, "tunnel.open")
        XCTAssertEqual(EnvelopeType.tunnelOpenResult, "tunnel.open.result")
        XCTAssertEqual(EnvelopeType.tunnelData, "tunnel.data")
        XCTAssertEqual(EnvelopeType.tunnelClose, "tunnel.close")
        XCTAssertEqual(EnvelopeType.tunnelError, "tunnel.error")
        XCTAssertEqual(EnvelopeType.tunnelFlow, "tunnel.flow")
    }

    // MARK: - Constants

    func testConstants() {
        XCTAssertEqual(TunnelConstants.initialCredit, 1024 * 1024)
        XCTAssertEqual(TunnelConstants.streamIdleTimeout, 60)
        XCTAssertEqual(TunnelConstants.tunnelIdleTimeout, 300)
        XCTAssertEqual(TunnelChunker.maxChunkSize, 32 * 1024)
    }
}
