@testable import EdgeLinkKit
import XCTest

final class MiplayKcpTransportTests: XCTestCase {
    private let testConv: UInt32 = 0xAABBCCDD

    private func makeSegment(
        conv: UInt32? = nil,
        command: UInt8,
        window: UInt16 = 600,
        ts: UInt32 = 42,
        sn: UInt32,
        una: UInt32 = 0,
        payload: Data = Data()
    ) -> Data {
        MiplayKcpSegment.encode(
            conv: conv ?? testConv,
            command: command,
            window: window,
            ts: ts,
            sn: sn,
            una: una,
            payload: payload
        )
    }

    private func push(sn: UInt32, conv: UInt32? = nil, ts: UInt32 = 42) -> Data {
        makeSegment(conv: conv, command: MiplayKcpTransport.commandPush, ts: ts, sn: sn, payload: Data([UInt8(sn & 0xff)]))
    }

    private func makeSink(
        configuration: MiplayKcpTransport.Configuration = MiplayKcpTransport.Configuration()
    ) -> MiplayKcpTransport {
        MiplayKcpTransport(
            sinkMode: true,
            configuration: configuration,
            sessionDescription: "test",
            nowUptimeNanoseconds: { 1_000_000_000 }
        )
    }

    func testSegmentCodecRoundTrip() {
        let payload = Data((0..<100).map { UInt8($0 & 0xff) })
        let encoded = makeSegment(command: 0x51, window: 511, ts: 0x01020304, sn: 0x05060708, una: 0x090A0B0C, payload: payload)
        XCTAssertEqual(encoded.count, 24 + payload.count)
        XCTAssertEqual(encoded[0], 0xDD)
        XCTAssertEqual(encoded[3], 0xAA)
        XCTAssertEqual(encoded[4], 0x51)
        XCTAssertEqual(encoded[5], 0x00)
        guard let segment = MiplayKcpSegment(data: encoded) else {
            return XCTFail("segment should parse")
        }
        XCTAssertEqual(segment.conv, testConv)
        XCTAssertEqual(segment.command, 0x51)
        XCTAssertEqual(segment.fragment, 0)
        XCTAssertEqual(segment.window, 511)
        XCTAssertEqual(segment.ts, 0x01020304)
        XCTAssertEqual(segment.sn, 0x05060708)
        XCTAssertEqual(segment.una, 0x090A0B0C)
        XCTAssertEqual(segment.length, UInt32(payload.count))
        XCTAssertEqual(segment.payload, payload)
    }

    func testSegmentParseRejectsShortData() {
        XCTAssertNil(MiplayKcpSegment(data: Data()))
        XCTAssertNil(MiplayKcpSegment(data: Data(repeating: 0, count: 23)))
        XCTAssertNotNil(MiplayKcpSegment(data: Data(repeating: 0, count: 24)))
    }

    func testReceiveDatagramRejectsTruncatedPayload() {
        let transport = makeSink()
        var delivered: [Data] = []
        var sent: [Data] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { sent.append($0) }
        var datagram = push(sn: 0)
        datagram.removeLast(1)
        transport.receiveDatagram(datagram)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(transport.conversationID)
        transport.receiveDatagram(Data(repeating: 0xFF, count: 10))
        XCTAssertNil(transport.conversationID)
    }

    func testSinkConversationEstablishedByFirstPush() {
        let transport = makeSink()
        var delivered: [(Data, UInt32)] = []
        var sent: [Data] = []
        transport.onRTPPayload = { payload, sn in delivered.append((payload, sn)) }
        transport.onSendDatagram = { sent.append($0) }
        transport.receiveDatagram(push(sn: 7, ts: 0x11223344))
        XCTAssertEqual(transport.conversationID, testConv)
        XCTAssertEqual(transport.remoteNextReceiveSN, 8)
        XCTAssertEqual(transport.pushReceived, 1)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.0, Data([7]))
        XCTAssertEqual(delivered.first?.1, 7)
        XCTAssertEqual(sent.count, 1)
        guard let ack = sent.first.flatMap({ MiplayKcpSegment(data: $0) }) else {
            return XCTFail("ACK should parse")
        }
        XCTAssertEqual(ack.conv, testConv)
        XCTAssertEqual(ack.command, MiplayKcpTransport.commandACK)
        XCTAssertEqual(ack.sn, 7)
        XCTAssertEqual(ack.ts, 0x11223344)
        XCTAssertEqual(ack.una, 8)
        XCTAssertEqual(ack.window, 2_048)
        XCTAssertTrue(ack.payload.isEmpty)
        XCTAssertEqual(transport.acksSent, 1)
    }

    func testSinkIgnoresInvalidFirstSegments() {
        let transport = makeSink()
        var sent: [Data] = []
        transport.onSendDatagram = { sent.append($0) }
        transport.receiveDatagram(makeSegment(command: 0x99, sn: 0))
        XCTAssertNil(transport.conversationID)
        XCTAssertEqual(transport.conversationIgnoredCount, 1)
        transport.receiveDatagram(makeSegment(conv: 0, command: MiplayKcpTransport.commandPush, sn: 0, payload: Data([1])))
        XCTAssertNil(transport.conversationID)
        XCTAssertEqual(transport.conversationIgnoredCount, 2)
        XCTAssertTrue(sent.isEmpty)
    }

    func testSinkIgnoresWrongConversationAfterEstablish() {
        let transport = makeSink()
        var delivered: [Data] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { _ in }
        transport.receiveDatagram(push(sn: 0))
        transport.receiveDatagram(push(sn: 1, conv: 0x12345678))
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(transport.conversationIgnoredCount, 1)
        XCTAssertEqual(transport.pushReceived, 1)
    }

    func testInOrderPushDeliveryAndACKs() {
        let transport = makeSink()
        var delivered: [Data] = []
        var sent: [Data] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { sent.append($0) }
        transport.receiveDatagram(push(sn: 7))
        transport.receiveDatagram(push(sn: 8))
        transport.receiveDatagram(push(sn: 9))
        XCTAssertEqual(delivered, [Data([7]), Data([8]), Data([9])])
        XCTAssertEqual(sent.count, 3)
        let acks = sent.compactMap { MiplayKcpSegment(data: $0) }
        XCTAssertEqual(acks.map(\.sn), [7, 8, 9])
        XCTAssertEqual(acks.map(\.una), [8, 9, 10])
        XCTAssertEqual(transport.acksSent, 3)
        XCTAssertEqual(transport.remoteNextReceiveSN, 10)
    }

    func testMultipleSegmentsInSingleDatagram() {
        let transport = makeSink()
        var delivered: [Data] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { _ in }
        var datagram = push(sn: 7)
        datagram.append(push(sn: 8))
        transport.receiveDatagram(datagram)
        XCTAssertEqual(delivered, [Data([7]), Data([8])])
        XCTAssertEqual(transport.acksSent, 2)
    }

    func testOutOfOrderPushBufferedThenDrainedInOrder() {
        let transport = makeSink()
        var delivered: [Data] = []
        var sent: [Data] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { sent.append($0) }
        transport.receiveDatagram(push(sn: 7))
        transport.receiveDatagram(push(sn: 9))
        XCTAssertEqual(delivered, [Data([7])])
        XCTAssertEqual(transport.outOfOrderBufferedCount, 1)
        transport.receiveDatagram(push(sn: 8))
        XCTAssertEqual(delivered, [Data([7]), Data([8]), Data([9])])
        XCTAssertEqual(transport.remoteNextReceiveSN, 10)
        XCTAssertEqual(sent.count, 3)
        let acks = sent.compactMap { MiplayKcpSegment(data: $0) }
        XCTAssertEqual(acks.map(\.sn), [7, 9, 8])
        XCTAssertEqual(acks.map(\.una), [8, 8, 10])
    }

    func testDuplicatePushDroppedButACKed() {
        let transport = makeSink()
        var delivered: [Data] = []
        var sent: [Data] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { sent.append($0) }
        transport.receiveDatagram(push(sn: 7))
        transport.receiveDatagram(push(sn: 7))
        XCTAssertEqual(delivered, [Data([7])])
        XCTAssertEqual(transport.duplicateDroppedCount, 1)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(transport.remoteNextReceiveSN, 8)
    }

    func testFirstPushResyncWhenConversationCameFromNonPush() {
        let transport = makeSink()
        var delivered: [Data] = []
        var losses: [(String, String)] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { _ in }
        transport.onTransportLoss = { reason, detail in losses.append((reason, detail)) }
        transport.receiveDatagram(makeSegment(command: MiplayKcpTransport.commandWASK, sn: 0))
        XCTAssertEqual(transport.conversationID, testConv)
        transport.receiveDatagram(push(sn: 5))
        XCTAssertEqual(losses.map(\.0), ["kcp_first_push_resync"])
        XCTAssertEqual(delivered, [Data([5])])
        XCTAssertEqual(transport.remoteNextReceiveSN, 6)
    }

    func testWASKTriggersWINSResponse() {
        let transport = makeSink()
        var sent: [Data] = []
        transport.onRTPPayload = { _, _ in }
        transport.onSendDatagram = { sent.append($0) }
        transport.receiveDatagram(push(sn: 7))
        transport.receiveDatagram(makeSegment(command: MiplayKcpTransport.commandWASK, ts: 0x55667788, sn: 3, una: 2))
        XCTAssertEqual(transport.waskReceived, 1)
        XCTAssertEqual(transport.winsSent, 1)
        XCTAssertEqual(sent.count, 2)
        guard let wins = sent.last.flatMap({ MiplayKcpSegment(data: $0) }) else {
            return XCTFail("WINS should parse")
        }
        XCTAssertEqual(wins.conv, testConv)
        XCTAssertEqual(wins.command, MiplayKcpTransport.commandWINS)
        XCTAssertEqual(wins.ts, 0x55667788)
        XCTAssertEqual(wins.sn, 3)
        XCTAssertEqual(wins.una, 8)
        XCTAssertTrue(wins.payload.isEmpty)
    }

    func testReceiveResyncOnGapBeyondLimit() {
        let transport = makeSink()
        var delivered: [Data] = []
        var losses: [(String, String)] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { _ in }
        transport.onTransportLoss = { reason, detail in losses.append((reason, detail)) }
        transport.receiveDatagram(push(sn: 7))
        transport.receiveDatagram(push(sn: 7 + 5000))
        XCTAssertEqual(transport.receiveResyncCount, 1)
        XCTAssertEqual(losses.map(\.0), ["kcp_receive_resync"])
        XCTAssertEqual(delivered, [Data([7]), Data([UInt8((7 + 5000) & 0xff)])])
        XCTAssertEqual(transport.remoteNextReceiveSN, 7 + 5001)
    }

    func testStalledReceiveBufferResyncOnGap() {
        var configuration = MiplayKcpTransport.Configuration()
        configuration.stallResyncDelayNanoseconds = 0
        configuration.stallResyncMinGap = 128
        configuration.stallResyncMaxStallNanoseconds = .max
        let transport = makeSink(configuration: configuration)
        var delivered: [Data] = []
        var losses: [(String, String)] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { _ in }
        transport.onTransportLoss = { reason, detail in losses.append((reason, detail)) }
        transport.receiveDatagram(push(sn: 7))
        transport.receiveDatagram(push(sn: 200))
        XCTAssertEqual(transport.receiveResyncCount, 1)
        XCTAssertEqual(losses.map(\.0), ["kcp_out_of_order_stalled_resync"])
        XCTAssertEqual(delivered, [Data([7]), Data([200])])
        XCTAssertEqual(transport.remoteNextReceiveSN, 201)
    }

    func testStalledReceiveBufferResyncOnBufferedCount() {
        var configuration = MiplayKcpTransport.Configuration()
        configuration.stallResyncDelayNanoseconds = 0
        configuration.stallResyncMinGap = .max
        configuration.stallResyncMinBuffered = 2
        configuration.stallResyncMaxStallNanoseconds = .max
        let transport = makeSink(configuration: configuration)
        var delivered: [Data] = []
        transport.onRTPPayload = { payload, _ in delivered.append(payload) }
        transport.onSendDatagram = { _ in }
        transport.receiveDatagram(push(sn: 7))
        transport.receiveDatagram(push(sn: 9))
        XCTAssertEqual(transport.receiveResyncCount, 0)
        transport.receiveDatagram(push(sn: 10))
        XCTAssertEqual(transport.receiveResyncCount, 1)
        XCTAssertEqual(delivered, [Data([7]), Data([9]), Data([10])])
        XCTAssertEqual(transport.remoteNextReceiveSN, 11)
    }

    func testACKBatchingFlushesAtMaxCount() {
        var configuration = MiplayKcpTransport.Configuration()
        configuration.ackBatchMaxCount = 3
        configuration.ackBatchDelaySeconds = 60
        let transport = makeSink(configuration: configuration)
        var batches: [[Data]] = []
        transport.onRTPPayload = { _, _ in }
        transport.onSendDatagramBatch = { batches.append($0) }
        transport.receiveDatagram(push(sn: 7))
        transport.receiveDatagram(push(sn: 8))
        XCTAssertTrue(batches.isEmpty)
        transport.receiveDatagram(push(sn: 9))
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 3)
        let acks = batches.first?.compactMap { MiplayKcpSegment(data: $0) } ?? []
        XCTAssertEqual(acks.map(\.sn), [7, 8, 9])
        XCTAssertEqual(transport.acksSent, 3)
    }

    func testACKBatchingFlushesAfterDelay() {
        var configuration = MiplayKcpTransport.Configuration()
        configuration.ackBatchMaxCount = 16
        configuration.ackBatchDelaySeconds = 0.05
        let transport = makeSink(configuration: configuration)
        let flushed = expectation(description: "ACK batch flushed")
        var batches: [[Data]] = []
        transport.onRTPPayload = { _, _ in }
        transport.onSendDatagramBatch = { packets in
            batches.append(packets)
            flushed.fulfill()
        }
        transport.receiveDatagram(push(sn: 7))
        XCTAssertTrue(batches.isEmpty)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 1)
    }

    func testSenderModePushEncoding() {
        let transport = MiplayKcpTransport(
            sinkMode: false,
            conversationID: MiplayKcpTransport.defaultConversationID,
            sessionDescription: "test",
            nowUptimeNanoseconds: { 1_000_000_000 }
        )
        var sent: [Data] = []
        transport.onSendDatagram = { sent.append($0) }
        XCTAssertTrue(transport.sendPush(payload: Data([1, 2, 3]), rtpSequence: 10))
        XCTAssertTrue(transport.sendPush(payload: Data([4]), rtpSequence: 11))
        XCTAssertEqual(transport.packetsSent, 2)
        XCTAssertEqual(transport.bytesSent, UInt64(sent.reduce(0) { $0 + $1.count }))
        let pushes = sent.compactMap { MiplayKcpSegment(data: $0) }
        XCTAssertEqual(pushes.count, 2)
        XCTAssertEqual(pushes[0].conv, MiplayKcpTransport.defaultConversationID)
        XCTAssertEqual(pushes[0].command, MiplayKcpTransport.commandPush)
        XCTAssertEqual(pushes[0].sn, 0)
        XCTAssertEqual(pushes[0].una, 0)
        XCTAssertEqual(pushes[0].payload, Data([1, 2, 3]))
        XCTAssertEqual(pushes[1].sn, 1)
        XCTAssertEqual(pushes[1].payload, Data([4]))
    }

    func testSendPushSkippedWithoutConversation() {
        let transport = makeSink()
        var sent: [Data] = []
        transport.onSendDatagram = { sent.append($0) }
        XCTAssertFalse(transport.sendPush(payload: Data([1]), rtpSequence: 1))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(transport.packetsSent, 0)
    }

    func testACKReceivedUpdatesStats() {
        let transport = MiplayKcpTransport(
            sinkMode: false,
            conversationID: MiplayKcpTransport.defaultConversationID,
            sessionDescription: "test",
            nowUptimeNanoseconds: { 1_000_000_000 }
        )
        transport.onSendDatagram = { _ in }
        transport.receiveDatagram(makeSegment(
            conv: MiplayKcpTransport.defaultConversationID,
            command: MiplayKcpTransport.commandACK,
            sn: 3,
            una: 4
        ))
        XCTAssertEqual(transport.acksReceived, 1)
        XCTAssertEqual(transport.latestACKSN, 3)
        XCTAssertEqual(transport.latestRemoteUNA, 4)
    }
}
