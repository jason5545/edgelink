import EdgeLinkKit
import Foundation
import XCTest

final class ClipboardBlobTransferTests: XCTestCase {

    func testChunkRoundTrip() {
        let data = Data((0..<100_000).map { UInt8($0 % 251) })
        let chunks = ClipboardBlobTransfer.chunk(data)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.dropLast().allSatisfy { !$0.fin })
        XCTAssertTrue(chunks.last?.fin == true)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.seq, index)
        }

        var reassembler = ClipboardBlobReassembler()
        let hash = ClipboardBlobTransfer.sha256Hex(data)
        var outcome: ClipboardBlobReassembler.AppendOutcome = .pending
        for chunk in chunks {
            outcome = reassembler.append(
                id: "id-1",
                seq: chunk.seq,
                fin: chunk.fin,
                hash: chunk.seq == 0 ? hash : nil,
                mime: chunk.seq == 0 ? "image/png" : nil,
                payloadBase64: chunk.payloadBase64
            )
        }
        guard case .complete(let result) = outcome else {
            return XCTFail("expected complete, got \(outcome)")
        }
        XCTAssertEqual(result.data, data)
        XCTAssertEqual(result.mime, "image/png")
    }

    func testSingleChunkBlob() {
        let data = Data(repeating: 7, count: 1_000)
        let chunks = ClipboardBlobTransfer.chunk(data)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].fin)
    }

    func testEmptyChunkMeansNotAvailable() {
        var reassembler = ClipboardBlobReassembler()
        let outcome = reassembler.append(
            id: "id-1", seq: 0, fin: true, hash: nil, mime: nil, payloadBase64: ""
        )
        XCTAssertEqual(outcome, .notAvailable)
    }

    func testHashMismatchDetected() {
        let data = Data(repeating: 3, count: 2_000)
        let chunk = ClipboardBlobTransfer.chunk(data)[0]
        var reassembler = ClipboardBlobReassembler()
        let outcome = reassembler.append(
            id: "id-1",
            seq: 0,
            fin: true,
            hash: String(repeating: "0", count: 64),
            mime: nil,
            payloadBase64: chunk.payloadBase64
        )
        XCTAssertEqual(outcome, .hashMismatch)
    }

    func testOutOfOrderChunksReassemble() {
        let data = Data((0..<70_000).map { UInt8($0 % 13) })
        let chunks = ClipboardBlobTransfer.chunk(data)
        XCTAssertEqual(chunks.count, 3)
        var reassembler = ClipboardBlobReassembler()
        let hash = ClipboardBlobTransfer.sha256Hex(data)
        let order = [chunks[1], chunks[0], chunks[2]]
        var outcome: ClipboardBlobReassembler.AppendOutcome = .pending
        for chunk in order {
            outcome = reassembler.append(
                id: "id-1",
                seq: chunk.seq,
                fin: chunk.fin,
                hash: chunk.seq == 0 ? hash : nil,
                mime: nil,
                payloadBase64: chunk.payloadBase64
            )
        }
        guard case .complete(let result) = outcome else {
            return XCTFail("expected complete, got \(outcome)")
        }
        XCTAssertEqual(result.data, data)
    }

    func testInvalidBase64Rejected() {
        var reassembler = ClipboardBlobReassembler()
        let outcome = reassembler.append(
            id: "id-1", seq: 0, fin: false, hash: nil, mime: nil, payloadBase64: "!!!not-base64!!!"
        )
        XCTAssertEqual(outcome, .invalidChunk)
    }

    func testBlobEnvelopeRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let chunk = ClipboardBlobChunkBody(
            id: "137245816#1751941001-0",
            seq: 0,
            fin: false,
            hash: "abc",
            mime: "image/png",
            payloadBase64: "iVBOR"
        )
        let data = try encoder.encode(Envelope(t: EnvelopeType.clipboardBlobChunk, b: chunk))
        let envelope = try decoder.decode(Envelope<ClipboardBlobChunkBody>.self, from: data)
        XCTAssertEqual(envelope.t, EnvelopeType.clipboardBlobChunk)
        XCTAssertEqual(envelope.b.id, "137245816#1751941001-0")
        XCTAssertEqual(envelope.b.hash, "abc")
        XCTAssertEqual(envelope.b.mime, "image/png")

        let request = ClipboardBlobRequestBody(id: "137245816#1751941001-0")
        let requestData = try encoder.encode(Envelope(t: EnvelopeType.clipboardBlobRequest, b: request))
        let decodedRequest = try decoder.decode(Envelope<ClipboardBlobRequestBody>.self, from: requestData)
        XCTAssertEqual(decodedRequest.t, EnvelopeType.clipboardBlobRequest)
        XCTAssertEqual(decodedRequest.b.id, "137245816#1751941001-0")
    }

    func testStatusCapsDecodesLegacyWithoutBlobFlag() throws {
        let json = #"{"t":"status.caps","b":{"clipboardHistory":true,"clipboardThumbnail":true}}"#.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(Envelope<StatusCapsBody>.self, from: json)
        XCTAssertTrue(envelope.b.clipboardHistory)
        XCTAssertTrue(envelope.b.clipboardThumbnail)
        XCTAssertFalse(envelope.b.clipboardBlob)
    }
}
