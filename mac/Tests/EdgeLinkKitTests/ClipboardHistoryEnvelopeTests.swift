import EdgeLinkKit
import Foundation
import XCTest

final class ClipboardHistoryEnvelopeTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testClipboardKindIntMapping() {
        XCTAssertEqual(ClipboardKind.text.intValue, 0)
        XCTAssertEqual(ClipboardKind.image.intValue, 1)
        XCTAssertEqual(ClipboardKind.html.intValue, 2)
        XCTAssertEqual(ClipboardKind.file.intValue, 3)
        XCTAssertEqual(ClipboardKind(intValue: 0), .text)
        XCTAssertEqual(ClipboardKind(intValue: 1), .image)
        XCTAssertEqual(ClipboardKind(intValue: 2), .html)
        XCTAssertEqual(ClipboardKind(intValue: 3), .file)
        XCTAssertNil(ClipboardKind(intValue: 99))
        XCTAssertEqual(ClipboardKind(rawValue: "image"), .image)
        XCTAssertNil(ClipboardKind(rawValue: "unknown"))
    }

    func testClipboardSetLegacyPayloadDecodes() throws {
        let json = #"{"t":"clipboard.set","b":{"text":"hi","ts":1751941000,"hash":"abc"}}"#.data(using: .utf8)!
        let envelope = try decoder.decode(Envelope<ClipboardSetBody>.self, from: json)
        XCTAssertEqual(envelope.t, "clipboard.set")
        XCTAssertEqual(envelope.b.text, "hi")
        XCTAssertEqual(envelope.b.ts, 1751941000)
        XCTAssertEqual(envelope.b.hash, "abc")
        XCTAssertNil(envelope.b.kind)
        XCTAssertNil(envelope.b.thumbnailBase64)
        XCTAssertNil(envelope.b.sourceDeviceId)
    }

    func testClipboardSetExtendedRoundTrip() throws {
        let body = ClipboardSetBody(
            text: "",
            ts: 1751941001,
            hash: "h",
            kind: "image",
            thumbnailBase64: "iVBOR",
            sourceDeviceId: "137245816"
        )
        let data = try encoder.encode(Envelope(t: EnvelopeType.clipboardSet, b: body))
        let envelope = try decoder.decode(Envelope<ClipboardSetBody>.self, from: data)
        XCTAssertEqual(envelope.t, EnvelopeType.clipboardSet)
        XCTAssertEqual(envelope.b.kind, "image")
        XCTAssertEqual(envelope.b.thumbnailBase64, "iVBOR")
        XCTAssertEqual(envelope.b.sourceDeviceId, "137245816")
    }

    func testStatusCapsRoundTrip() throws {
        let body = StatusCapsBody(clipboardHistory: true, clipboardThumbnail: false)
        let data = try encoder.encode(Envelope(t: EnvelopeType.statusCaps, b: body))
        let envelope = try decoder.decode(Envelope<StatusCapsBody>.self, from: data)
        XCTAssertEqual(envelope.t, EnvelopeType.statusCaps)
        XCTAssertTrue(envelope.b.clipboardHistory)
        XCTAssertFalse(envelope.b.clipboardThumbnail)
    }

    func testClipboardHistoryRequestRoundTrip() throws {
        let body = ClipboardHistoryRequestBody(sinceTs: 1751940600, limit: 20)
        let data = try encoder.encode(Envelope(t: EnvelopeType.clipboardHistoryRequest, b: body))
        let envelope = try decoder.decode(Envelope<ClipboardHistoryRequestBody>.self, from: data)
        XCTAssertEqual(envelope.t, EnvelopeType.clipboardHistoryRequest)
        XCTAssertEqual(envelope.b.sinceTs, 1751940600)
        XCTAssertEqual(envelope.b.limit, 20)
    }

    func testClipboardHistoryResponseRoundTrip() throws {
        let item = ClipboardHistoryItemBody(
            id: "137245816#1751941001-0",
            kind: "image",
            ts: 1751941001,
            hash: "h",
            thumbnailBase64: "iVBOR",
            sourceDeviceId: "137245816"
        )
        let response = ClipboardHistoryResponseBody(items: [item])
        let data = try encoder.encode(Envelope(t: EnvelopeType.clipboardHistoryResponse, b: response))
        let envelope = try decoder.decode(Envelope<ClipboardHistoryResponseBody>.self, from: data)
        XCTAssertEqual(envelope.b.items.count, 1)
        let decoded = envelope.b.items[0]
        XCTAssertEqual(decoded.id, "137245816#1751941001-0")
        XCTAssertEqual(decoded.kind, "image")
        XCTAssertNil(decoded.text)
        XCTAssertEqual(decoded.thumbnailBase64, "iVBOR")
        XCTAssertEqual(decoded.sourceDeviceId, "137245816")
    }

    func testEnvelopeTypeConstants() {
        XCTAssertEqual(EnvelopeType.statusCaps, "status.caps")
        XCTAssertEqual(EnvelopeType.clipboardHistoryRequest, "clipboard.history.request")
        XCTAssertEqual(EnvelopeType.clipboardHistoryResponse, "clipboard.history.response")
    }
}