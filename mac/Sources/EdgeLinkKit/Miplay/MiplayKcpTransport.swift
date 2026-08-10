import Foundation

public struct MiplayKcpSegment {
    public let conv: UInt32
    public let command: UInt8
    public let fragment: UInt8
    public let window: UInt16
    public let ts: UInt32
    public let sn: UInt32
    public let una: UInt32
    public let length: UInt32
    public let payload: Data

    public init?(data: Data, offset: Int = 0) {
        guard offset + MiplayKcpTransport.headerLength <= data.count,
              let conv = data.readUInt32LE(at: offset),
              let window = data.readUInt16LE(at: offset + 6),
              let ts = data.readUInt32LE(at: offset + 8),
              let sn = data.readUInt32LE(at: offset + 12),
              let una = data.readUInt32LE(at: offset + 16),
              let length = data.readUInt32LE(at: offset + 20) else {
            return nil
        }
        self.conv = conv
        self.command = data[offset + 4]
        self.fragment = data[offset + 5]
        self.window = window
        self.ts = ts
        self.sn = sn
        self.una = una
        self.length = length
        let payloadStart = offset + MiplayKcpTransport.headerLength
        let payloadEnd = payloadStart + Int(length)
        self.payload = payloadEnd <= data.count ? data[payloadStart..<payloadEnd] : Data()
    }

    public static func encode(
        conv: UInt32,
        command: UInt8,
        fragment: UInt8 = 0,
        window: UInt16,
        ts: UInt32,
        sn: UInt32,
        una: UInt32,
        payload: Data
    ) -> Data {
        var packet = Data(capacity: MiplayKcpTransport.headerLength + payload.count)
        packet.appendUInt32LE(conv)
        packet.append(command)
        packet.append(fragment)
        packet.appendUInt16LE(window)
        packet.appendUInt32LE(ts)
        packet.appendUInt32LE(sn)
        packet.appendUInt32LE(una)
        packet.appendUInt32LE(UInt32(truncatingIfNeeded: payload.count))
        packet.append(payload)
        return packet
    }
}

public final class MiplayKcpTransport {
    public enum LogLevel {
        case info
        case warning
    }

    public struct Configuration {
        public var receiveWindow: UInt16 = 2_048
        public var receiveBufferLimit = 2_048
        public var receiveMaxGap: UInt32 = 4_096
        public var stallResyncDelayNanoseconds: UInt64 = 900_000_000
        public var stallResyncMaxStallNanoseconds: UInt64 = 2_500_000_000
        public var stallResyncMinGap: Int64 = 128
        public var stallResyncMinBuffered = 48
        public var ackBatchMaxCount = 16
        public var ackBatchDelaySeconds: Double = 0.005

        public init() {}
    }

    public static let defaultConversationID: UInt32 = 0x1234_5678
    public static let commandPush: UInt8 = 0x51
    public static let commandACK: UInt8 = 0x52
    public static let commandWASK: UInt8 = 0x53
    public static let commandWINS: UInt8 = 0x54
    public static let headerLength = 24

    public var onSendDatagram: ((Data) -> Void)?
    public var onSendDatagramBatch: (([Data]) -> Void)?
    public var onRTPPayload: ((Data, UInt32) -> Void)?
    public var onTransportLoss: ((String, String) -> Void)?
    public var onLog: ((LogLevel, String) -> Void)?

    public private(set) var conversationID: UInt32?
    public private(set) var remoteNextReceiveSN: UInt32 = 0
    public private(set) var packetsSent: UInt64 = 0
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var acksReceived: UInt64 = 0
    public private(set) var acksSent: UInt64 = 0
    public private(set) var waskReceived: UInt64 = 0
    public private(set) var winsSent: UInt64 = 0
    public private(set) var winsReceived: UInt64 = 0
    public private(set) var pushReceived: UInt64 = 0
    public private(set) var latestACKSN: UInt32?
    public private(set) var latestRemoteUNA: UInt32?
    public private(set) var conversationIgnoredCount: UInt64 = 0
    public private(set) var outOfOrderBufferedCount: UInt64 = 0
    public private(set) var duplicateDroppedCount: UInt64 = 0
    public private(set) var receiveResyncCount: UInt64 = 0
    public var lastPushUptimeNanoseconds: UInt64

    private let sinkMode: Bool
    private let configuration: Configuration
    private let sessionDescription: String
    private let nowUptimeNanoseconds: () -> UInt64
    private var sendSN: UInt32 = 0
    private var receiveBuffer: [UInt32: MiplayKcpSegment] = [:]
    private var outOfOrderStartedUptimeNanoseconds: UInt64 = 0
    private var outOfOrderExpectedSN: UInt32?
    private var ackBatch: [Data] = []
    private var ackBatchWorkItem: DispatchWorkItem?
    private let ackBatchLock = NSLock()

    public init(
        sinkMode: Bool,
        conversationID: UInt32? = nil,
        configuration: Configuration = Configuration(),
        sessionDescription: String = "",
        nowUptimeNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.sinkMode = sinkMode
        self.conversationID = conversationID
        self.configuration = configuration
        self.sessionDescription = sessionDescription
        self.nowUptimeNanoseconds = nowUptimeNanoseconds
        self.lastPushUptimeNanoseconds = nowUptimeNanoseconds()
    }

    deinit {
        ackBatchWorkItem?.cancel()
    }

    public func receiveDatagram(_ data: Data) {
        var offset = 0
        var parsedSegments = 0
        while offset + Self.headerLength <= data.count {
            guard let segment = MiplayKcpSegment(data: data, offset: offset) else {
                break
            }
            let segmentLength = Self.headerLength + Int(segment.length)
            guard offset + segmentLength <= data.count else {
                log(
                    .warning,
                    "xiaomi.mirror.mpt.kcp_malformed session=\(sessionDescription) bytes=\(data.count) " +
                        "offset=\(offset) declaredLength=\(segment.length)"
                )
                break
            }
            handleSegment(segment)
            offset += segmentLength
            parsedSegments += 1
        }
        if parsedSegments == 0 {
            log(
                .warning,
                "xiaomi.mirror.mpt.kcp_malformed session=\(sessionDescription) bytes=\(data.count) " +
                    "firstBytes=\(Self.hexPreview(data, limit: 16))"
            )
        }
    }

    @discardableResult
    public func sendPush(payload: Data, rtpSequence: UInt16) -> Bool {
        let sn = sendSN
        sendSN &+= 1
        guard let packet = makeSegment(
            command: Self.commandPush,
            ts: Self.monotonicMilliseconds(),
            sn: sn,
            una: remoteNextReceiveSN,
            payload: payload
        ) else {
            log(
                .warning,
                "xiaomi.mirror.mpt.kcp_push_skipped session=\(sessionDescription) reason=missing_conv sn=\(sn) rtpSeq=\(rtpSequence)"
            )
            return false
        }
        guard emitDatagram(packet) else {
            log(
                .warning,
                "xiaomi.mirror.mpt.kcp_push_failed session=\(sessionDescription) sn=\(sn) rtpSeq=\(rtpSequence)"
            )
            return false
        }
        packetsSent += 1
        bytesSent += UInt64(packet.count)
        if packetsSent <= 5 || packetsSent % 300 == 0 {
            log(
                .info,
                "xiaomi.mirror.mpt.kcp_push_sent session=\(sessionDescription) sn=\(sn) rtpSeq=\(rtpSequence) " +
                    "bytes=\(packet.count) payloadBytes=\(payload.count) una=\(remoteNextReceiveSN) " +
                    "packetsSent=\(packetsSent) bytesSent=\(bytesSent)"
            )
        }
        return true
    }

    private func handleSegment(_ segment: MiplayKcpSegment) {
        guard establishConversationIfNeeded(from: segment) else {
            logIgnoredConversation(segment)
            return
        }
        guard segment.conv == conversationID else {
            logIgnoredConversation(segment)
            return
        }
        switch segment.command {
        case Self.commandACK:
            acksReceived += 1
            latestACKSN = segment.sn
            latestRemoteUNA = segment.una
            if acksReceived <= 5 || acksReceived % 100 == 0 {
                log(
                    .info,
                    "xiaomi.mirror.mpt.kcp_ack_received session=\(sessionDescription) sn=\(segment.sn) " +
                        "una=\(segment.una) ts=\(segment.ts) acks=\(acksReceived) packetsSent=\(packetsSent)"
                )
            }
        case Self.commandWASK:
            waskReceived += 1
            sendWINS(responseTo: segment)
            log(
                .info,
                "xiaomi.mirror.mpt.kcp_wask_received session=\(sessionDescription) count=\(waskReceived) " +
                    "sn=\(segment.sn) una=\(segment.una)"
            )
        case Self.commandWINS:
            winsReceived += 1
            if winsReceived <= 5 || winsReceived % 20 == 0 {
                log(
                    .info,
                    "xiaomi.mirror.mpt.kcp_wins_received session=\(sessionDescription) count=\(winsReceived) " +
                        "sn=\(segment.sn) una=\(segment.una)"
                )
            }
        case Self.commandPush:
            pushReceived += 1
            handlePush(segment)
        default:
            log(
                .warning,
                "xiaomi.mirror.mpt.kcp_unknown_received session=\(sessionDescription) " +
                    "cmd=0x\(String(segment.command, radix: 16)) sn=\(segment.sn) len=\(segment.length)"
            )
        }
    }

    private func handlePush(_ segment: MiplayKcpSegment) {
        // Any arriving push — even out-of-order or buffered — proves the
        // source is still sending. Head-of-line blocking behind a lost
        // segment must not read as "no packets from source".
        lastPushUptimeNanoseconds = nowUptimeNanoseconds()
        if sinkMode,
           receiveBuffer.isEmpty,
           remoteNextReceiveSN == 0,
           segment.sn != 0 {
            remoteNextReceiveSN = segment.sn
            notifyTransportLoss(
                reason: "kcp_first_push_resync",
                detail: "sn=\(segment.sn)"
            )
        }
        let delta = Self.sequenceDelta(segment.sn, from: remoteNextReceiveSN)
        if delta == 0 {
            deliverPush(segment)
            remoteNextReceiveSN &+= 1
            drainReceiveBuffer()
            sendACK(responseTo: segment)
            return
        }
        if delta < 0 {
            duplicateDroppedCount += 1
            sendACK(responseTo: segment)
            if duplicateDroppedCount <= 5 || duplicateDroppedCount % 50 == 0 {
                log(
                    .warning,
                    "xiaomi.mirror.mpt.kcp_duplicate_dropped session=\(sessionDescription) " +
                        "sn=\(segment.sn) expected=\(remoteNextReceiveSN) duplicates=\(duplicateDroppedCount)"
                )
            }
            return
        }

        if receiveBuffer.count >= configuration.receiveBufferLimit || delta > Int64(configuration.receiveMaxGap) {
            receiveResyncCount += 1
            if let oldest = receiveBuffer.keys.min() {
                // Salvage resync: declare lost only the hole before the
                // oldest buffered segment and deliver the contiguous
                // buffered run. Jumping to the newest arrival instead would
                // discard up to receiveBufferLimit healthy segments per
                // loss, which at high packet rates collapses goodput to a
                // few percent and stalls the decoder permanently (observed
                // on the 2026-08-10 high-rate soak: 2% loss at ~3.4k pkt/s
                // delivered only ~7% of segments).
                let dropped = Self.sequenceDelta(oldest, from: remoteNextReceiveSN)
                notifyTransportLoss(
                    reason: "kcp_receive_resync",
                    detail: "sn=\(segment.sn) expected=\(remoteNextReceiveSN) gap=\(delta) " +
                        "salvaged=\(receiveBuffer.count) dropped=\(dropped)"
                )
                receiveBuffer[segment.sn] = segment
                remoteNextReceiveSN = oldest
                resetOutOfOrderTracking()
                drainReceiveBuffer()
                if !receiveBuffer.isEmpty {
                    outOfOrderStartedUptimeNanoseconds = nowUptimeNanoseconds()
                    outOfOrderExpectedSN = remoteNextReceiveSN
                }
            } else {
                receiveBuffer.removeAll(keepingCapacity: true)
                resetOutOfOrderTracking()
                notifyTransportLoss(
                    reason: "kcp_receive_resync",
                    detail: "sn=\(segment.sn) expected=\(remoteNextReceiveSN) gap=\(delta)"
                )
                remoteNextReceiveSN = segment.sn
                deliverPush(segment)
                remoteNextReceiveSN &+= 1
            }
            sendACK(responseTo: segment)
            return
        }

        noteOutOfOrderBufferingIfNeeded()
        if receiveBuffer[segment.sn] == nil {
            receiveBuffer[segment.sn] = segment
            outOfOrderBufferedCount += 1
        }
        if shouldResyncStalledReceiveBuffer(delta: delta) {
            resyncStalledReceiveBuffer(responseTo: segment, delta: delta)
            return
        }
        sendACK(responseTo: segment)
        if outOfOrderBufferedCount <= 5 || outOfOrderBufferedCount % 50 == 0 {
            log(
                .warning,
                "xiaomi.mirror.mpt.kcp_out_of_order_buffered session=\(sessionDescription) " +
                    "sn=\(segment.sn) expected=\(remoteNextReceiveSN) gap=\(delta) " +
                    "buffered=\(receiveBuffer.count) total=\(outOfOrderBufferedCount)"
            )
        }
    }

    private func drainReceiveBuffer() {
        while let segment = receiveBuffer.removeValue(forKey: remoteNextReceiveSN) {
            deliverPush(segment)
            remoteNextReceiveSN &+= 1
        }
        if receiveBuffer.isEmpty {
            resetOutOfOrderTracking()
        }
    }

    private func noteOutOfOrderBufferingIfNeeded() {
        guard receiveBuffer.isEmpty,
              outOfOrderStartedUptimeNanoseconds == 0 else {
            return
        }
        outOfOrderStartedUptimeNanoseconds = nowUptimeNanoseconds()
        outOfOrderExpectedSN = remoteNextReceiveSN
    }

    private func shouldResyncStalledReceiveBuffer(delta: Int64) -> Bool {
        guard sinkMode,
              !receiveBuffer.isEmpty,
              outOfOrderStartedUptimeNanoseconds > 0 else {
            return false
        }
        let now = nowUptimeNanoseconds()
        guard now - outOfOrderStartedUptimeNanoseconds >= configuration.stallResyncDelayNanoseconds else {
            return false
        }
        // At low packet rates (static screen) the count/gap thresholds below
        // can take longer than the 6s stall watchdog, so bound any
        // head-of-line stall by time as well.
        if !receiveBuffer.isEmpty,
           now - outOfOrderStartedUptimeNanoseconds >= configuration.stallResyncMaxStallNanoseconds {
            return true
        }
        return delta >= configuration.stallResyncMinGap ||
            receiveBuffer.count >= configuration.stallResyncMinBuffered
    }

    private func resyncStalledReceiveBuffer(responseTo segment: MiplayKcpSegment, delta: Int64) {
        guard let targetSN = receiveBuffer.keys.min() else {
            return
        }
        let previousExpected = outOfOrderExpectedSN ?? remoteNextReceiveSN
        let buffered = receiveBuffer.count
        let elapsedMs = Double(nowUptimeNanoseconds() - outOfOrderStartedUptimeNanoseconds) / 1_000_000
        receiveResyncCount += 1
        notifyTransportLoss(
            reason: "kcp_out_of_order_stalled_resync",
            detail: "target=\(targetSN) expected=\(previousExpected) gap=\(delta) buffered=\(buffered) elapsedMs=\(String(format: "%.0f", elapsedMs))"
        )
        remoteNextReceiveSN = targetSN
        drainReceiveBuffer()
        sendACK(responseTo: segment)
        if !receiveBuffer.isEmpty {
            // Re-arm the stall timer for the next hole: leaving the stale
            // start time in place makes every later out-of-order arrival
            // re-trigger a resync instantly, turning one hole episode into
            // a declaration storm that tears every access unit (observed on
            // the 2026-08-10 high-rate soak).
            outOfOrderStartedUptimeNanoseconds = nowUptimeNanoseconds()
            outOfOrderExpectedSN = remoteNextReceiveSN
        }
        log(
            .warning,
            "xiaomi.mirror.mpt.kcp_out_of_order_stalled_resync session=\(sessionDescription) " +
                "target=\(targetSN) previousExpected=\(previousExpected) gap=\(delta) " +
                "buffered=\(buffered) elapsedMs=\(String(format: "%.0f", elapsedMs)) " +
                "resyncs=\(receiveResyncCount)"
        )
    }

    private func resetOutOfOrderTracking() {
        outOfOrderStartedUptimeNanoseconds = 0
        outOfOrderExpectedSN = nil
    }

    private func deliverPush(_ segment: MiplayKcpSegment) {
        if pushReceived <= 5 || pushReceived % 20 == 0 {
            log(
                .info,
                "xiaomi.mirror.mpt.kcp_push_received session=\(sessionDescription) sn=\(segment.sn) " +
                    "payloadBytes=\(segment.length) remoteNext=\(remoteNextReceiveSN) " +
                    "pushReceived=\(pushReceived) payloadFirstBytes=\(Self.hexPreview(segment.payload, limit: 12))"
            )
        }
        onRTPPayload?(segment.payload, segment.sn)
    }

    private func notifyTransportLoss(reason: String, detail: String) {
        onTransportLoss?(reason, detail)
    }

    private func sendACK(responseTo segment: MiplayKcpSegment) {
        guard let packet = makeSegment(
            command: Self.commandACK,
            ts: segment.ts,
            sn: segment.sn,
            una: remoteNextReceiveSN,
            payload: Data()
        ) else {
            log(
                .warning,
                "xiaomi.mirror.mpt.kcp_ack_send_skipped session=\(sessionDescription) reason=missing_conv " +
                    "peerConv=\(Self.hex32(segment.conv)) sn=\(segment.sn)"
            )
            return
        }
        if sendACKPacket(packet) {
            acksSent += 1
            if acksSent <= 5 || acksSent % 50 == 0 {
                log(
                    .info,
                    "xiaomi.mirror.mpt.kcp_ack_sent session=\(sessionDescription) sn=\(segment.sn) " +
                        "una=\(remoteNextReceiveSN) conv=\(Self.hex32(segment.conv)) ackSent=\(acksSent)"
                )
            }
        } else {
            log(
                .warning,
                "xiaomi.mirror.mpt.kcp_ack_send_failed session=\(sessionDescription) sn=\(segment.sn)"
            )
        }
    }

    private func sendACKPacket(_ packet: Data) -> Bool {
        guard onSendDatagramBatch != nil else {
            return emitDatagram(packet)
        }
        var flushNow = false
        ackBatchLock.lock()
        ackBatch.append(packet)
        if ackBatch.count >= configuration.ackBatchMaxCount {
            flushNow = true
        } else if ackBatchWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushACKBatch()
            }
            ackBatchWorkItem = workItem
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + configuration.ackBatchDelaySeconds,
                execute: workItem
            )
        }
        ackBatchLock.unlock()
        if flushNow {
            flushACKBatch()
        }
        return true
    }

    private func flushACKBatch() {
        ackBatchLock.lock()
        ackBatchWorkItem?.cancel()
        ackBatchWorkItem = nil
        let packets = ackBatch
        ackBatch.removeAll(keepingCapacity: true)
        ackBatchLock.unlock()
        guard !packets.isEmpty else {
            return
        }
        if let onSendDatagramBatch {
            onSendDatagramBatch(packets)
        } else {
            for packet in packets {
                _ = emitDatagram(packet)
            }
        }
    }

    private func sendWINS(responseTo segment: MiplayKcpSegment) {
        guard let packet = makeSegment(
            command: Self.commandWINS,
            ts: segment.ts,
            sn: segment.sn,
            una: remoteNextReceiveSN,
            payload: Data()
        ) else {
            log(
                .warning,
                "xiaomi.mirror.mpt.kcp_wins_send_skipped session=\(sessionDescription) reason=missing_conv " +
                    "peerConv=\(Self.hex32(segment.conv)) sn=\(segment.sn)"
            )
            return
        }
        if emitDatagram(packet) {
            winsSent += 1
        } else {
            log(.warning, "xiaomi.mirror.mpt.kcp_wins_send_failed session=\(sessionDescription)")
        }
    }

    private func emitDatagram(_ packet: Data) -> Bool {
        guard let onSendDatagram else {
            return false
        }
        onSendDatagram(packet)
        return true
    }

    private func makeSegment(command: UInt8, ts: UInt32, sn: UInt32, una: UInt32, payload: Data) -> Data? {
        guard let conv = conversationID else {
            return nil
        }
        return MiplayKcpSegment.encode(
            conv: conv,
            command: command,
            window: configuration.receiveWindow,
            ts: ts,
            sn: sn,
            una: una,
            payload: payload
        )
    }

    private func establishConversationIfNeeded(from segment: MiplayKcpSegment) -> Bool {
        if conversationID != nil {
            return true
        }
        guard sinkMode else {
            conversationID = Self.defaultConversationID
            return true
        }
        guard Self.isKnownCommand(segment.command), segment.conv != 0 else {
            return false
        }
        conversationID = segment.conv
        if segment.command == Self.commandPush {
            remoteNextReceiveSN = segment.sn
        }
        log(
            .info,
            "xiaomi.mirror.mpt.kcp_conv_initialized session=\(sessionDescription) " +
                "role=sink_receiver conv=\(Self.hex32(segment.conv)) cmd=0x\(String(segment.command, radix: 16)) " +
                "sn=\(segment.sn) una=\(segment.una) len=\(segment.length)"
        )
        return true
    }

    private func logIgnoredConversation(_ segment: MiplayKcpSegment) {
        conversationIgnoredCount += 1
        if conversationIgnoredCount <= 5 || conversationIgnoredCount % 50 == 0 {
            let expected = conversationID.map { Self.hex32($0) } ?? "uninitialized"
            log(
                .warning,
                "xiaomi.mirror.mpt.kcp_conv_ignored session=\(sessionDescription) " +
                    "expected=\(expected) actual=\(Self.hex32(segment.conv)) " +
                    "cmd=0x\(String(segment.command, radix: 16)) sn=\(segment.sn) count=\(conversationIgnoredCount)"
            )
        }
    }

    private func log(_ level: LogLevel, _ message: String) {
        onLog?(level, message)
    }

    private static func isKnownCommand(_ command: UInt8) -> Bool {
        command == commandPush || command == commandACK || command == commandWASK || command == commandWINS
    }

    private static func sequenceDelta(_ current: UInt32, from previous: UInt32) -> Int64 {
        Int64(Int32(bitPattern: current &- previous))
    }

    private static func monotonicMilliseconds() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private static func hexPreview(_ data: Data, limit: Int) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func hex32(_ value: UInt32) -> String {
        String(format: "0x%08x", value)
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    func readUInt16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < count else {
            return nil
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < count else {
            return nil
        }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
