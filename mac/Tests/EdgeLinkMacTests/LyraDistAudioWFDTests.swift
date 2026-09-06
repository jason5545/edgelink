import CryptoKit
import Foundation
import Network
import XCTest

// Mock-based coverage for the distaudio WFD patch: the miplaycast 3.1.x
// session-key auth (shared by the client M1 answer and the server OPTIONS
// answer) and the downlink media plane (LyraDistAudioMediaDecoder fed with
// synthetic KCP/TS/PES/ff02 datagrams instead of a real phone).
//
// Auth vectors are the byte-for-byte captured phone sessions of 2026-08-06:
//   uplink sink key ****4fc2 = MD5(t("10.0.0.1546092610.0.0.12654110"))
//   downlink source key ****92a1 = MD5(t("10.0.0.126823610.0.0.15465051"))
// where t() adds 0x31 to every digit char, and the ack is
// HMAC-SHA256(key = that MD5 hex, msg = peer authMsg).
final class LyraDistAudioWFDTests: XCTestCase {

    // MARK: - Auth (client + server shared scheme)

    func testSessionKeyUplinkVectorMatchesPhoneCapture() {
        // 21:05 round: Mac was the RTSP server (listen 60927 → logged
        // 60926 in the phone's composite), phone client 10.0.0.126:54110.
        let key = LyraDistAudioWFD.miplaySessionKey(
            serverIP: "10.0.0.154", serverPort: 60926,
            clientIP: "10.0.0.126", clientPort: 54110
        )
        let keyHex = String(decoding: key, as: UTF8.self)
        XCTAssertEqual(keyHex, "681607611b22482676e92cceba384fc2")
        XCTAssertTrue(keyHex.hasSuffix("4fc2"))

        // The phone's own ack for our M1 authMsg reproduced exactly.
        let ack = LyraDistAudioWFD.sessionAuthMsgAck(
            for: "537bf8dc158795d4b3a57d9569867ab1", key: key
        )
        XCTAssertEqual(ack, "7ae32fc97f9942a1e52913ecf544a19ecbfed547125ad5d6b6003666d457cb41")
    }

    func testSessionKeyDownlinkVectorMatchesPhoneCapture() {
        // 21:15 round: phone server 10.0.0.126:8236, Mac client :65051.
        let key = LyraDistAudioWFD.miplaySessionKey(
            serverIP: "10.0.0.126", serverPort: 8236,
            clientIP: "10.0.0.154", clientPort: 65051
        )
        XCTAssertTrue(String(decoding: key, as: UTF8.self).hasSuffix("92a1"))
    }

    func testSessionKeyIsServerFirstThenClient() {
        // Swapping server/client must change the key (order matters).
        let a = LyraDistAudioWFD.miplaySessionKey(
            serverIP: "10.0.0.126", serverPort: 8236, clientIP: "10.0.0.154", clientPort: 65051
        )
        let b = LyraDistAudioWFD.miplaySessionKey(
            serverIP: "10.0.0.154", serverPort: 65051, clientIP: "10.0.0.126", clientPort: 8236
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Downlink client reuse (duplicate openSpeaker)

    // Live 2026-09-06: the phone re-issues openSpeaker ~1s apart
    // (connectDistAudioDevice once at relay setup, again when the call goes
    // ACTIVE) while its MiCastServer keeps streaming on the original TCP
    // connection. The Mac must reuse the live client, not reconnect.
    func testDownlinkClientMatchesOnlyIdenticalParamsAndStops() {
        let keyB64 = Data((0..<16).map { $0 }).base64EncodedString()
        let otherKeyB64 = Data((1...16).map { $0 }).base64EncodedString()
        let client = LyraDistAudioWFDClient(host: "10.0.0.238", port: 8236, mediaKeyBase64: keyB64)
        XCTAssertFalse(client.isStopped)
        XCTAssertTrue(client.matches(host: "10.0.0.238", port: 8236, mediaKeyBase64: keyB64))
        XCTAssertFalse(client.matches(host: "10.0.0.239", port: 8236, mediaKeyBase64: keyB64))
        XCTAssertFalse(client.matches(host: "10.0.0.238", port: 8237, mediaKeyBase64: keyB64))
        XCTAssertFalse(client.matches(host: "10.0.0.238", port: 8236, mediaKeyBase64: otherKeyB64))
        client.stop()
        XCTAssertTrue(client.isStopped)
    }

    // MARK: - AES-ECB round trip

    func testECBRoundTrip() {
        let key = Data((0..<16).map { UInt8($0 + 1) })
        let pcm = makePCM(pattern: 0x1234, blocks: 20)
        let encrypted = DistAudioECB.encrypt(pcm, key: key)
        XCTAssertNotEqual(encrypted.prefix(16), pcm.prefix(16))
        XCTAssertEqual(DistAudioECB.decrypt(encrypted, key: key), pcm)
    }

    // MARK: - Uplink direct feed

    // Regression for the 2026-09-06 uplink fix: the phone's native
    // MiPlayCastClient receives our RTP/TS uplink but never hands frames to
    // the SDK (the 0x100707/mIsPhoneRelay-gated shared-memory hop), so every
    // 20ms PCM frame must ALSO reach the audiomonitor hook's UDP listener
    // as one raw 656-byte AES-128-ECB datagram. Drives the sender through
    // the engine-free seam (startNetwork + enqueueCapturedPCM).
    func testUplinkDirectFeedSendsRawCipherFramesAlongsideRTP() throws {
        XCTAssertEqual(LyraDistAudioUplink.directFeedPort, 45671)
        let key = Data((0..<16).map { UInt8($0 &* 5 &+ 11) })
        let feed = try UDPDatagramCollector(port: LyraDistAudioUplink.directFeedPort)
        defer { feed.stop() }
        let rtp = try UDPDatagramCollector(port: 0)
        defer { rtp.stop() }
        // A plain UDP socket released immediately after bind(0) frees its
        // port deterministically — a cancelled NWListener lingers long
        // enough for the uplink's requiredLocalEndpoint bind to EADDRINUSE.
        let localPort = Self.freeUDPPort()

        let uplink = LyraDistAudioUplink(
            host: "127.0.0.1", port: rtp.boundPort, localPort: localPort, mediaKey: key
        )
        uplink.startNetwork()
        defer { uplink.stop() }

        // 3 full 640B frames with distinct contents, plus a 960B chunk
        // (1.5 frames) to pin the carry-split: exactly one more frame now,
        // the last half-frame stays buffered.
        var frames: [Data] = []
        for f in 0..<3 {
            frames.append(Data((0..<640).map { UInt8(($0 &+ f &* 37) & 0xFF) }))
        }
        var chunk = frames[0] + frames[1] + frames[2]
        let half = Data((0..<960).map { UInt8(($0 &+ 200) & 0xFF) })
        chunk.append(half)
        uplink.enqueueCapturedPCM(chunk)

        XCTAssertTrue(feed.waitForDatagrams(4), "feed datagrams: \(feed.count)")
        XCTAssertEqual(feed.count, 4)
        let expectedFrames = frames + [Data(half.prefix(640))]
        for (index, frame) in expectedFrames.enumerated() {
            guard let datagram = feed.datagram(at: index) else {
                XCTFail("missing feed datagram \(index)")
                continue
            }
            XCTAssertEqual(datagram.count, 656, "frame \(index) must be one ECB cipher block chain")
            XCTAssertEqual(
                DistAudioECB.decrypt(datagram, key: key), frame,
                "frame \(index) must decrypt back to the captured PCM"
            )
        }

        // The RTP/TS uplink still flows next to the feed (first packet
        // carries the ff03 announce + PAT/PMT + PES). Byte 1 is the
        // production dialect byte 0x61 as verified on-device.
        XCTAssertTrue(rtp.waitForDatagrams(1), "rtp packets: \(rtp.count)")
        guard let rtpPacket = rtp.datagram(at: 0) else {
            XCTFail("missing rtp packet")
            return
        }
        XCTAssertEqual(rtpPacket.first, 0x80)
        XCTAssertEqual(rtpPacket.dropFirst().first, 0x61)
    }

    private static func freeUDPPort() -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        addr.sin_port = 0
        var bindAddr = sockaddr()
        memcpy(&bindAddr, &addr, MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(Darwin.bind(fd, &bindAddr, socklen_t(MemoryLayout<sockaddr_in>.size)), 0)
        var out = sockaddr_in()
        var outLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &out) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                XCTAssertEqual(Darwin.getsockname(fd, sa, &outLen), 0)
            }
        }
        Darwin.close(fd)
        return UInt16(bigEndian: out.sin_port)
    }

    // MARK: - Media decoder (mock phone packets)

    func testDecoderEndToEndDeliversDecryptedPCMAndAcks() {
        let key = Data((0..<16).map { UInt8(0xA0 + $0) })
        let decoder = LyraDistAudioMediaDecoder(mediaKey: key)
        var pcmOut: [Data] = []
        var acks: [Data] = []
        decoder.onPCM = { pcmOut.append($0) }
        decoder.onSendACK = { acks.append($0) }

        let pcm = makePCM(pattern: 0x5678, blocks: 40)  // 640 bytes
        let datagram = makePushDatagram(conv: 0x0000_1234, ts: 111, sn: 0, tsPackets: makePESRun(
            pesPayload: makeFF02(encrypted: DistAudioECB.encrypt(pcm, key: key)),
            packetLength: nil
        ))
        decoder.feed(datagram: datagram)

        XCTAssertEqual(pcmOut.count, 1)
        XCTAssertEqual(pcmOut.first, pcm)
        XCTAssertEqual(decoder.pcmBytesDelivered, pcm.count)

        XCTAssertEqual(acks.count, 1)
        guard let ack = acks.first, ack.count == LyraDistAudioMediaDecoder.kcpHeaderLength else {
            return XCTFail("missing ACK")
        }
        XCTAssertEqual(ack[4], LyraDistAudioMediaDecoder.kcpCommandACK)
        XCTAssertEqual(readUInt32LE(ack, 0), 0x0000_1234)  // conv echoed
        XCTAssertEqual(readUInt32LE(ack, 8), 111)  // ts echoed
        XCTAssertEqual(readUInt32LE(ack, 12), 0)  // sn echoed
    }

    func testDecoderReordersOutOfOrderPushes() {
        let key = Data(repeating: 0x42, count: 16)
        let decoder = LyraDistAudioMediaDecoder(mediaKey: key)
        var pcmOut: [Data] = []
        decoder.onPCM = { pcmOut.append($0) }

        let pcmA = makePCM(pattern: 0x0101, blocks: 4)
        let pcmB = makePCM(pattern: 0x0202, blocks: 4)
        let pcmC = makePCM(pattern: 0x0303, blocks: 4)
        func datagram(sn: UInt32, pcm: Data) -> Data {
            makePushDatagram(conv: 7, ts: sn, sn: sn, tsPackets: makePESRun(
                pesPayload: makeFF02(encrypted: DistAudioECB.encrypt(pcm, key: key)), packetLength: nil
            ))
        }

        decoder.feed(datagram: datagram(sn: 0, pcm: pcmA))  // initializes sn
        XCTAssertEqual(pcmOut, [pcmA])
        decoder.feed(datagram: datagram(sn: 2, pcm: pcmC))  // gap → buffered
        XCTAssertEqual(pcmOut, [pcmA])
        decoder.feed(datagram: datagram(sn: 1, pcm: pcmB))  // fills → both flush
        XCTAssertEqual(pcmOut, [pcmA, pcmB, pcmC])
    }

    // Live 2026-09-05 21:03 ("語音被切掉，幾秒後接到切掉之後的內容"): a
    // single lost segment stalled the receiver while 256 follow-ups
    // buffered, and the 257th arrival (gap 257 > the window) resynced by
    // DROPPING all buffered speech. The recovery delivers the contiguous
    // pending run (only the one lost segment is skipped), and late
    // retransmits are ignored instead of rewinding the stream.
    func testDecoderRecoversPendingAudioOnWindowOverflowInsteadOfDropping() {
        let key = Data(repeating: 0x42, count: 16)
        let decoder = LyraDistAudioMediaDecoder(mediaKey: key)
        var pcmOut: [Data] = []
        decoder.onPCM = { pcmOut.append($0) }

        func datagram(sn: UInt32) -> Data {
            let pcm = makePCM(pattern: UInt16(truncatingIfNeeded: sn &+ 0x100), blocks: 4)
            return makePushDatagram(conv: 7, ts: sn, sn: sn, tsPackets: makePESRun(
                pesPayload: makeFF02(encrypted: DistAudioECB.encrypt(pcm, key: key)), packetLength: nil
            ))
        }

        decoder.feed(datagram: datagram(sn: 0))  // initializes sn, delivered
        XCTAssertEqual(pcmOut.count, 1)
        for sn in UInt32(2)...UInt32(257) {      // buffer the pending window
            decoder.feed(datagram: datagram(sn: sn))
        }
        XCTAssertEqual(pcmOut.count, 1, "in-window gaps must buffer, not deliver")
        // sn=1 is lost; sn=258 overflows the 256-slot window (delta 258).
        decoder.feed(datagram: datagram(sn: 258))
        // Old behavior: resync dropped all pending → 2 payloads.
        // Recovery: skip the lost sn=1, deliver 2...257 in order, then 258.
        XCTAssertEqual(pcmOut.count, 258)
        // A late retransmit of the lost segment must not rewind the stream.
        decoder.feed(datagram: datagram(sn: 1))
        XCTAssertEqual(pcmOut.count, 258, "late retransmit must be ignored")
    }

    func testDecoderHandlesTSSplitAcrossPushes() {
        let key = Data(repeating: 0x77, count: 16)
        let decoder = LyraDistAudioMediaDecoder(mediaKey: key)
        var pcmOut: [Data] = []
        decoder.onPCM = { pcmOut.append($0) }

        let pcm = makePCM(pattern: 0x3456, blocks: 80)
        let stream = makePESRun(
            pesPayload: makeFF02(encrypted: DistAudioECB.encrypt(pcm, key: key)), packetLength: nil
        )
        // Split mid-TS-packet: first push gets 400 bytes (2 packets + 24).
        let first = stream.prefix(400)
        let rest = stream.dropFirst(400)
        decoder.feed(datagram: makePushDatagram(conv: 9, ts: 1, sn: 0, tsPackets: Data(first)))
        XCTAssertEqual(pcmOut.count, 0)
        decoder.feed(datagram: makePushDatagram(conv: 9, ts: 2, sn: 1, tsPackets: Data(rest)))
        XCTAssertEqual(pcmOut.count, 1)
        XCTAssertEqual(pcmOut.first, pcm)
    }

    func testDecoderParsesFF03FormatAnnouncement() {
        let key = Data(repeating: 0x5A, count: 16)
        let decoder = LyraDistAudioMediaDecoder(mediaKey: key)
        var pcmOut: [Data] = []
        decoder.onPCM = { pcmOut.append($0) }

        // Observed live ff03: sampleRate 0x3e80 (16000), packedFormat 0x0110
        // (1 channel / 16 bits), bitsPerSample 0x10; declared covers the
        // encrypted blob (PCM + PKCS7 padding).
        let pcm = makePCM(pattern: 0x7788, blocks: 20)
        let encrypted = DistAudioECB.encrypt(pcm, key: key)
        var payload = Data([0xFF, 0x03, 0x00, 0x00, 0x00, 0x0E, 0x01, 0x10])
        payload.append(contentsOf: [0x00, 0x00, 0x3E, 0x80])  // sampleRate BE
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x08])  // frames BE
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x10])  // bits BE
        let declared = UInt32(encrypted.count)
        payload.append(contentsOf: [
            UInt8((declared >> 24) & 0xFF), UInt8((declared >> 16) & 0xFF),
            UInt8((declared >> 8) & 0xFF), UInt8(declared & 0xFF),
        ])
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        payload.append(encrypted)

        decoder.feed(datagram: makePushDatagram(conv: 3, ts: 1, sn: 0, tsPackets: makePESRun(
            pesPayload: payload, packetLength: nil
        )))
        XCTAssertEqual(decoder.announcedSampleRate, 16_000)
        XCTAssertEqual(decoder.announcedChannels, 1)
        XCTAssertEqual(decoder.announcedBitsPerSample, 16)
        XCTAssertEqual(pcmOut.first, pcm)
    }

    func testDecoderIgnoresMarkerlessDatagrams() {
        let decoder = LyraDistAudioMediaDecoder(mediaKey: Data(repeating: 1, count: 16))
        var warnings: [String] = []
        var pcmOut: [Data] = []
        decoder.onWarn = { warnings.append($0) }
        decoder.onPCM = { pcmOut.append($0) }

        var datagram = makeKCPHeader(conv: 5, ts: 9, sn: 0)
        datagram.append(Data(repeating: 0xAB, count: 64))  // no deadbeef
        decoder.feed(datagram: datagram)
        XCTAssertTrue(pcmOut.isEmpty)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("kcp_no_marker"))
    }

    // MARK: - Builders

    private func makePCM(pattern: UInt16, blocks: Int) -> Data {
        var pcm = Data()
        let samples = blocks * 8  // 16-byte AES block = 8 s16 samples
        for i in 0..<samples {
            let sample = UInt16(truncatingIfNeeded: pattern &+ UInt16(truncatingIfNeeded: i &* 7919))
            pcm.append(UInt8(sample & 0xFF))
            pcm.append(UInt8((sample >> 8) & 0xFF))
        }
        return pcm
    }

    private func makeKCPHeader(conv: UInt32, ts: UInt32, sn: UInt32) -> Data {
        var header = Data()
        appendUInt32LE(&header, conv)
        header.append(LyraDistAudioMediaDecoder.kcpCommandPush)
        header.append(0)
        appendUInt16LE(&header, 256)
        appendUInt32LE(&header, ts)
        appendUInt32LE(&header, sn)
        appendUInt32LE(&header, 0)
        appendUInt32LE(&header, 0)
        return header
    }

    // 12-byte framing header + deadbeef marker + TS stream.
    private func makePushDatagram(conv: UInt32, ts: UInt32, sn: UInt32, tsPackets: Data) -> Data {
        var datagram = makeKCPHeader(conv: conv, ts: ts, sn: sn)
        datagram.append(contentsOf: [0x24, 0x00])
        appendUInt16LE(&datagram, UInt16(truncatingIfNeeded: tsPackets.count))
        datagram.append(contentsOf: [0x80, 0xA1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        datagram.append(LyraDistAudioMediaDecoder.kcpFrameMarker)
        datagram.append(tsPackets)
        return datagram
    }

    // Packetizes a private payload into a private_stream_1 PES carried by
    // 188-byte TS packets (PUSI on the first, continuation after).
    private func makePESRun(pesPayload: Data, packetLength: UInt16?) -> Data {
        // PES header: flags 0x84 0x80, header_data_length 7 (PTS-ish pad).
        var pes = Data([0x00, 0x00, 0x01, 0xBD])
        let afterLength = 3 + pesPayload.count  // flags(2) + hdrLen(1) + payload
        let declaredLength = packetLength ?? UInt16(truncatingIfNeeded: afterLength)
        pes.append(UInt8((declaredLength >> 8) & 0xFF))
        pes.append(UInt8(declaredLength & 0xFF))
        pes.append(contentsOf: [0x84, 0x80, 0x07, 0x21, 0x00, 0x01, 0x00, 0x01, 0xFF, 0xFF])
        pes.append(pesPayload)

        var stream = Data()
        var offset = 0
        var first = true
        while offset < pes.count {
            var packet = Data([0x47, first ? 0x51 : 0x50, 0x00, 0x10])
            first = false
            let chunk = pes.subdata(in: offset..<min(offset + 184, pes.count))
            offset += chunk.count
            packet.append(chunk)
            packet.append(Data(repeating: 0xFF, count: 188 - packet.count))
            stream.append(packet)
        }
        return stream
    }

    // ff02: 18-byte header, declared PCM length u32 BE at offset 8.
    private func makeFF02(encrypted: Data) -> Data {
        var payload = Data([0xFF, 0x02, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00])
        let declared = UInt32(encrypted.count)
        payload.append(contentsOf: [
            UInt8((declared >> 24) & 0xFF), UInt8((declared >> 16) & 0xFF),
            UInt8((declared >> 8) & 0xFF), UInt8(declared & 0xFF),
        ])
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        payload.append(encrypted)
        return payload
    }

    private func appendUInt16LE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}

// Minimal UDP datagram collector for the direct-feed contract test: one
// NWListener, per-sender NWConnections, all received datagrams in arrival
// order.
private final class UDPDatagramCollector {
    private(set) var boundPort: UInt16 = 0
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var received: [Data] = []
    private let queue = DispatchQueue(label: "UDPDatagramCollector")
    private let readySemaphore = DispatchSemaphore(value: 0)

    var count: Int {
        queue.sync { received.count }
    }

    init(port: UInt16) throws {
        let listener = try NWListener(
            using: .udp,
            on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        )
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                // Already on `queue` — set synchronously so the semaphore
                // never unblocks before boundPort is visible.
                self?.boundPort = self?.listener?.port?.rawValue ?? 0
                self?.readySemaphore.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async {
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receiveLoop(connection)
            }
        }
        listener.start(queue: queue)
        XCTAssertEqual(readySemaphore.wait(timeout: .now() + 5), .success)
        XCTAssertNotEqual(boundPort, 0)
    }

    func datagram(at index: Int) -> Data? {
        queue.sync { index < received.count ? received[index] : nil }
    }

    func waitForDatagrams(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if self.count >= count { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return self.count >= count
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            for connection in connections { connection.cancel() }
        }
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self else { return }
            self.queue.async {
                if let data { self.received.append(data) }
                self.receiveLoop(connection)
            }
        }
    }
}
