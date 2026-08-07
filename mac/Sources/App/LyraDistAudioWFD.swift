import AVFoundation
import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// MiPlayCast/WFD audio transport for the DistAudio device role. The phone's
// audiomonitor runs MiPlayCast RTSP (same miplaycast_os3 dialect as the
// mirror WFD flow) with audio/raw 16kHz mono PCM16, AES-128-ECB-PKCS5 per
// blob, keys exchanged base64 in the distAudio RPC params.
//
// LyraDistAudioWFDClient = downlink (phone's call audio → Mac playback).
// LyraDistAudioWFDServer = uplink (Mac mic → phone's call).
enum LyraDistAudioWFD {
    static func authMsgAck(for authMsg: String) -> String {
        let key = SymmetricKey(data: MiplayPESCrypto.videoKey)
        let code = HMAC<SHA256>.authenticationCode(for: Data(authMsg.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    // The distaudio session's genAuthKey(1) key is session-dependent:
    //   composite = serverIP + serverPort + clientIP + clientPort
    //   (decimal ASCII; server = the RTSP listener of the session),
    //   each digit char + 0x31, then MD5-hex; the MD5 hex string is
    //   the HMAC key. Verified against phone logs on 2026-08-06:
    //   uplink sink key ****4fc2 = MD5(t("10.0.0.1546092610.0.0.12654110"))
    //   (Mac server) and downlink source key ****92a1 =
    //   MD5(t("10.0.0.126823610.0.0.15465051")) (phone server), and
    //   HMAC-SHA256(key = that MD5 hex, msg = authMsg) reproduces the
    //   phone's own authMsgAck byte-for-byte.
    static func miplaySessionKey(serverIP: String, serverPort: UInt16, clientIP: String, clientPort: UInt16) -> Data {
        let composite = "\(serverIP)\(serverPort)\(clientIP)\(clientPort)"
        let transformed = composite.unicodeScalars.map { scalar -> Character in
            if (0x30...0x39).contains(scalar.value) {
                return Character(UnicodeScalar(scalar.value + 0x31)!)
            }
            return Character(scalar)
        }
        let digest = Insecure.MD5.hash(data: Data(String(transformed).utf8))
        return Data(digest.map { String(format: "%02x", $0) }.joined().utf8)
    }

    // The phone's checkAuthentication expects ack = HMAC-SHA256(key =
    // genAuthKey result, msg = its authMsg), per OAuth::hmac's swapped
    // arg roles in libCastService-jni.so.
    static func sessionAuthMsgAck(for authMsg: String, key: Data) -> String {
        let symmetricKey = SymmetricKey(data: key)
        let code = HMAC<SHA256>.authenticationCode(for: Data(authMsg.utf8), using: symmetricKey)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func randomAuthMsg() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // Debug hook: /tmp/edgelink-distaudio-delay containing an integer
    // number of seconds holds the downlink M1 answer that long, keeping
    // the phone's RTSP session alive for process-memory inspection.
    static func debugDelayM1Seconds() -> Int {
        guard let text = try? String(contentsOfFile: "/tmp/edgelink-distaudio-delay", encoding: .utf8),
              let secs = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), secs > 0
        else { return 0 }
        return secs
    }

    static func rtspDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }

    static func serializeRequest(method: String, target: String, cseq: Int, headers: [String], body: String) -> Data {
        var lines = "\(method) \(target) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        lines += "User-Agent: stagefright/1.1 (Linux;Android 4.1)\r\n"
        lines += "Date: \(rtspDate())\r\n"
        for header in headers {
            lines += header + "\r\n"
        }
        if !body.isEmpty {
            lines += "Content-Type: text/parameters\r\n"
            lines += "Content-Length: \(body.utf8.count)\r\n"
        }
        lines += "\r\n" + body
        return Data(lines.utf8)
    }

    static func serializeResponse(cseq: Int, headers: [String], body: String) -> Data {
        var lines = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n"
        lines += "Date: \(rtspDate())\r\n"
        lines += "User-Agent: stagefright/1.1 (Linux;Android 4.1)\r\n"
        for header in headers {
            lines += header + "\r\n"
        }
        if !body.isEmpty {
            lines += "Content-Type: text/parameters\r\n"
            lines += "Content-Length: \(body.utf8.count)\r\n"
        }
        lines += "\r\n" + body
        return Data(lines.utf8)
    }

    // Incremental RTSP message parser over a TCP byte stream.
    struct MessageParser {
        private var buffer = Data()

        mutating func append(_ data: Data) -> [(firstLine: String, headers: [String: String], body: Data)] {
            buffer.append(data)
            var messages: [(String, [String: String], Data)] = []
            while let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    buffer.removeAll()
                    break
                }
                var lines = headerText.components(separatedBy: "\r\n")
                let firstLine = lines.removeFirst()
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[String(key)] = value
                }
                let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
                let messageEnd = headerEnd.upperBound + contentLength
                guard buffer.count >= messageEnd else { break }
                let body = buffer.subdata(in: headerEnd.upperBound..<messageEnd)
                buffer.removeSubrange(0..<messageEnd)
                messages.append((firstLine, headers, body))
            }
            return messages
        }
    }
}

// Local LE byte helpers (the EdgeLinkKit/MiplayKcpTransport equivalents
// are file-private).
private func distAudioReadUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 3 < data.count else { return nil }
    return UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
}

private func distAudioAppendUInt16LE(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
}

private func distAudioAppendUInt32LE(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}

// AES-128-ECB with PKCS5/PKCS7 padding (AesEcbPkcd5Util on the phone side).
enum DistAudioECB {
    static func encrypt(_ plaintext: Data, key: Data) -> Data {
        guard let aes = AES128(key: key), !plaintext.isEmpty else { return plaintext }
        var padded = plaintext
        let pad = 16 - (plaintext.count % 16)
        padded.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        var output = Data(count: padded.count)
        padded.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                guard let inBase = inBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let outBase = outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }
                for block in 0..<(padded.count / 16) {
                    let offset = block * 16
                    let transformed = aes.encryptBlock(Array(UnsafeBufferPointer(start: inBase + offset, count: 16)))
                    for i in 0..<16 { outBase[offset + i] = transformed[i] }
                }
            }
        }
        return output
    }

    static func decrypt(_ ciphertext: Data, key: Data) -> Data {
        guard let aes = AES128(key: key), ciphertext.count >= 16, ciphertext.count % 16 == 0 else {
            return ciphertext
        }
        var output = Data(count: ciphertext.count)
        ciphertext.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                guard let inBase = inBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let outBase = outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }
                for block in 0..<(ciphertext.count / 16) {
                    let offset = block * 16
                    let transformed = aes.decryptBlock(Array(UnsafeBufferPointer(start: inBase + offset, count: 16)))
                    for i in 0..<16 { outBase[offset + i] = transformed[i] }
                }
            }
        }
        guard let pad = output.last, pad >= 1, pad <= 16, output.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            return output
        }
        return output.dropLast(Int(pad))
    }
}

// Downlink: phone's MiCastServer (call audio) → WFD client → Mac playback.
final class LyraDistAudioWFDClient {
    private enum Stage: String {
        case connected
        case awaitSetupResponse
        case awaitPlayResponse
        case established
        case closed
    }

    private let host: String
    private let port: UInt16
    private let mediaKey: Data
    private let queue = DispatchQueue(label: "edgelink.lyra.distaudio.wfdclient")
    private var connection: NWConnection?
    private var parser = LyraDistAudioWFD.MessageParser()
    private var stage: Stage = .connected
    private var ourCSeq = 0
    private var ourAuthMsg = LyraDistAudioWFD.randomAuthMsg()
    private var session: String?
    private var serverMediaPort: UInt16 = 0
    private var clientMediaPort: UInt16 = 0
    private var mediaListener: NWListener?
    private var mediaDumpRemaining = 8
    private var player: LyraDistAudioPlayer?
    private var statsBytes = 0
    private var localIP: String?
    private var localPort: UInt16 = 0
    // Media arrives as KCP PUSH segments (conv 0x00001234, cmd 0x51). The
    // length field offset is inconsistent across segments (the first push
    // carries one extra byte), so frame by the 0xdeadbeef marker that
    // terminates every push payload's 12-byte framing header instead of
    // trusting the length. The phone retransmits and stalls unless we ACK
    // every push, so run a minimal in-order receiver answering with ACKs.
    private static let kcpHeaderLength = 24
    private static let kcpCommandPush: UInt8 = 0x51
    private static let kcpCommandACK: UInt8 = 0x52
    private static let kcpFrameMarker = Data([0xde, 0xad, 0xbe, 0xef])
    private var kcpConv: UInt32?
    private var kcpExpectedSN: UInt32 = 0
    private var kcpInitialized = false
    private var kcpPending: [UInt32: Data] = [:]
    private var mediaConnection: NWConnection?
    // Carries PES fragments across TS packets / KCP segments.
    private var tsCarry = Data()
    private var pesBuffer = Data()
    private var pesExpectedLength: Int?
    private var pesCount = 0

    init(host: String, port: UInt16, mediaKeyBase64: String) {
        self.host = host
        self.port = port
        self.mediaKey = Data(base64Encoded: mediaKeyBase64) ?? Data()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let connection = NWConnection(
                host: NWEndpoint.Host(self.host),
                port: NWEndpoint.Port(rawValue: self.port)!,
                using: .tcp
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.localEndpoint {
                        self?.localIP = "\(host)"
                        self?.localPort = port.rawValue
                    }
                    DiagnosticsLog.info("xiaomi.distaudio.downlink_ready \(self?.host ?? ""):\(self?.port ?? 0) local=\(self?.localIP ?? "?"):\(self?.localPort ?? 0)")
                case .failed(let error):
                    DiagnosticsLog.warn("xiaomi.distaudio.downlink_end \(String(describing: error))")
                case .cancelled:
                    DiagnosticsLog.warn("xiaomi.distaudio.downlink_end cancelled")
                default:
                    DiagnosticsLog.info("xiaomi.distaudio.downlink_state \(String(describing: state))")
                }
            }
            connection.start(queue: queue)
            receive()
            // The phone tears its MiCastServer down fast when the other leg
            // fails — surface silent connect stalls.
            queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.stage != .established, self.stage != .closed else { return }
                DiagnosticsLog.warn("xiaomi.distaudio.downlink_stalled stage=\(self.stage.rawValue)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stage = .closed
            self.connection?.cancel()
            self.mediaListener?.cancel()
            self.player?.stop(reason: "client_stop")
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for message in parser.append(data) {
                    handleMessage(firstLine: message.firstLine, headers: message.headers, body: message.body)
                }
            }
            if complete || error != nil || stage == .closed {
                return
            }
            receive()
        }
    }

    private func send(_ data: Data, label: String) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.error("xiaomi.distaudio.downlink_tx_failed \(label)", error)
            }
        })
    }

    private func handleMessage(firstLine: String, headers: [String: String], body: Data) {
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        if firstLine.hasPrefix("RTSP/") {
            handleResponse(firstLine: firstLine, headers: headers, body: bodyText)
            return
        }
        let method = firstLine.split(separator: " ").first.map(String.init) ?? ""
        let cseq = headers["cseq"].flatMap(Int.init) ?? 0
        DiagnosticsLog.info(
            "xiaomi.distaudio.downlink_rx method=\(method) cseq=\(cseq) bodyBytes=\(body.count) " +
                "firstLine=\(firstLine) headers=\(headers.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: "|"))"
        )
        switch method {
        case "OPTIONS":
            let authMsg = headers["authmsg"] ?? ""
            // DistAudio miplaycast (os3_release1.6 3.1.x) offers
            // authkeytype=1/authalgorithmtypes=7. Answer keyType 1 with
            // the deterministic MD5-composite key ack (keyType 2's slot
            // is never populated for distaudio → empty → 401).
            //
            // /tmp/edgelink-distaudio-delay=<secs>: hold the M1 answer
            // so the phone keeps the RTSP session alive while we scan
            // its process memory for the auth-key composite fields.
            let delaySecs = LyraDistAudioWFD.debugDelayM1Seconds()
            if delaySecs > 0 {
                DiagnosticsLog.info("xiaomi.distaudio.downlink_m1_delay \(delaySecs)s")
                queue.asyncAfter(deadline: .now() + .seconds(delaySecs)) { [weak self] in
                    self?.sendM1Answer(cseq: cseq, authMsg: authMsg)
                }
            } else {
                sendM1Answer(cseq: cseq, authMsg: authMsg)
            }
            send(
                LyraDistAudioWFD.serializeRequest(
                    method: "OPTIONS", target: "*", cseq: ourCSeq,
                    headers: [
                        "Require: org.wfa.wfd1.0",
                        "lib_version: miplaycast_os3_release1.6 3.1.5120912",
                        "authMsg:\(ourAuthMsg)",
                        "authKeyType: 1",
                        "authAlgorithmTypes: 7",
                        "fastRTSPVersion: 0",
                    ],
                    body: ""
                ),
                label: "options_m2"
            )
        case "GET_PARAMETER":
            let isCapabilityQuery = bodyText.contains("wfd_audio") || bodyText.contains("wfd_video") || bodyText.contains("wfd_client_rtp_ports")
            DiagnosticsLog.info("xiaomi.distaudio.downlink_getparam body=\(bodyText.replacingOccurrences(of: "\r\n", with: "|"))")
            send(
                LyraDistAudioWFD.serializeResponse(
                    cseq: cseq,
                    headers: [],
                    body: isCapabilityQuery ? capabilityBody() : ""
                ),
                label: "getparam_response"
            )
        case "SET_PARAMETER":
            DiagnosticsLog.info("xiaomi.distaudio.downlink_setparam body=\(bodyText.prefix(300))")
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), label: "setparam_response")
            if bodyText.contains("wfd_trigger_method: SETUP") {
                ourCSeq += 1
                send(
                    LyraDistAudioWFD.serializeRequest(
                        method: "SETUP", target: "rtsp://localhost/wfd1.0", cseq: ourCSeq,
                        headers: [
                            "Transport: RTP/AVP/MPT;unicast;client_port=\(clientMediaPort);userid=\(UInt32.random(in: 10000...60000))",
                        ],
                        body: ""
                    ),
                    label: "setup"
                )
                stage = .awaitSetupResponse
            } else if bodyText.contains("wfd_trigger_method: TEARDOWN") {
                DiagnosticsLog.info("xiaomi.distaudio.downlink_teardown")
                stop()
            }
        default:
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), label: "generic_response")
        }
    }

    private func handleResponse(firstLine: String, headers: [String: String], body: String) {
        let cseq = headers["cseq"].flatMap(Int.init) ?? -1
        DiagnosticsLog.info("xiaomi.distaudio.downlink_response cseq=\(cseq) stage=\(stage.rawValue) body=\(body.prefix(200)) firstLine=\(firstLine) headers=\(headers.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: "|"))")
        guard firstLine.contains("200") else {
            DiagnosticsLog.warn("xiaomi.distaudio.downlink_rtsp_error \(firstLine)")
            return
        }
        switch stage {
        case .awaitSetupResponse:
            if let rawSession = headers["session"] {
                session = rawSession.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces)
            }
            if let transport = headers["transport"] {
                for component in transport.components(separatedBy: ";") {
                    let pair = component.trimmingCharacters(in: .whitespaces)
                    if pair.hasPrefix("server_port="),
                       let port = UInt16(pair.dropFirst("server_port=".count)) {
                        serverMediaPort = port
                    }
                }
            }
            var playHeaders: [String] = []
            if let session {
                playHeaders.append("Session: \(session)")
            }
            ourCSeq += 1
            send(
                LyraDistAudioWFD.serializeRequest(
                    method: "PLAY", target: "rtsp://localhost/wfd1.0", cseq: ourCSeq,
                    headers: playHeaders, body: ""
                ),
                label: "play"
            )
            stage = .awaitPlayResponse
        case .awaitPlayResponse:
            stage = .established
            DiagnosticsLog.info(
                "xiaomi.distaudio.downlink_established session=\(session ?? "none") serverPort=\(serverMediaPort) clientPort=\(clientMediaPort)"
            )
            startMediaReceiver()
        default:
            break
        }
    }

    private func sendM1Answer(cseq: Int, authMsg: String) {
        // Downlink session: the phone is the RTSP server (host:port),
        // we are the client. Composite = server + client.
        let key = LyraDistAudioWFD.miplaySessionKey(
            serverIP: host, serverPort: port, clientIP: localIP ?? "", clientPort: localPort
        )
        ourCSeq += 1
        send(
            LyraDistAudioWFD.serializeResponse(
                cseq: cseq,
                headers: [
                    "Public: org.wfa.wfd1.0, GET_PARAMETER, SET_PARAMETER",
                    "authKeyType: 1",
                    "authAlgorithmVal: 4",
                    "authMsgAck:\(LyraDistAudioWFD.sessionAuthMsgAck(for: authMsg, key: key))",
                    "fastRTSPVersion: 0",
                ],
                body: ""
            ),
            label: "options_response"
        )
    }

    private func capabilityBody() -> String {
        // The source's onReceiveM3Response walks every field of its M3
        // query and aborts with err -1007 on the first missing/unparsable
        // one ("Sink doesn't report its choice of wfd_video_formats.").
        // Answer all of them; formats mirror the phone sink's own
        // hardcoded templates in libCastService-jni.so. Video is never
        // actually used — distaudio only sets up audio — but the
        // negotiation still has to succeed.
        [
            "wfd_content_SP_protection: 4 1 256 3 1 1 1 1",
            // "none" takes the parser's short path and lands the source
            // in its "Sink doesn't support video at all." branch, which
            // continues (unlike a non-empty formats list with no common
            // format → err -1010). The phone sink ships its own
            // "wfd_video_formats: none" template for exactly this.
            "wfd_video_formats: none",
            "wfd_video_enctype: 0",
            "wfd_video_gamuttype: 0",
            "wfd_video_bitrate: 5000000",
            "wfd_dynamic_video_enable: 0",
            "wfd_current_video_info: none",
            "wfd_audio_codecs_v2: 16 0 0 0",
            "wfd_client_rtp_ports: RTP/AVP/MPT;unicast \(clientMediaPort) 0 mode=play",
            "wfd_tcp_enable: 0",
            "wfd_tcp_multi_session_enable: 0",
            "wfd_support_secure_win: 0",
            "wfd_mirror_control_enable: 0",
            "wfd_standby_resume_capability: supported",
            "wfd_image_enable_v2: 0",
            "wfd_buffer_capabity: 1F",
            "",
        ].joined(separator: "\r\n")
    }

    private func startMediaReceiver() {
        let player = LyraDistAudioPlayer(sampleRate: 16000)
        self.player = player
        player.start()
        do {
            let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: clientMediaPort)!)
            mediaListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self!.queue)
                self?.mediaConnection = connection
                self?.receiveMedia(connection)
            }
            listener.start(queue: queue)
        } catch {
            DiagnosticsLog.error("xiaomi.distaudio.downlink_media_listen_failed", error)
        }
    }

    private func receiveMedia(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                handleMediaDatagram(data)
            }
            if error == nil, stage == .established {
                receiveMedia(connection)
            }
        }
    }

    private func handleMediaDatagram(_ datagram: Data) {
        // One KCP PUSH segment per datagram in practice. conv@0, cmd@4,
        // ts@8, sn@12 are stable across all observed segments.
        guard datagram.count > Self.kcpHeaderLength,
              let ts = distAudioReadUInt32LE(datagram, at: 8),
              let sn = distAudioReadUInt32LE(datagram, at: 12)
        else { return }
        let command = datagram[4]
        if kcpConv == nil {
            kcpConv = distAudioReadUInt32LE(datagram, at: 0)
        }
        guard command == Self.kcpCommandPush else { return }
        sendKCPACK(ts: ts, sn: sn)
        guard let markerRange = datagram.range(of: Self.kcpFrameMarker) else {
            if mediaDumpRemaining > 0 {
                DiagnosticsLog.warn(
                    "xiaomi.distaudio.downlink_kcp_no_marker sn=\(sn) bytes=\(datagram.count) " +
                        "head=\(datagram.prefix(40).map { String(format: "%02x", $0) }.joined())"
                )
            }
            return
        }
        ingestKCPPush(sn: sn, payload: Data(datagram[markerRange.upperBound...]))
    }

    private func sendKCPACK(ts: UInt32, sn: UInt32) {
        guard let conv = kcpConv, let connection = mediaConnection else { return }
        var packet = Data(capacity: Self.kcpHeaderLength)
        distAudioAppendUInt32LE(&packet, conv)
        packet.append(Self.kcpCommandACK)
        packet.append(0)
        distAudioAppendUInt16LE(&packet, 256)
        distAudioAppendUInt32LE(&packet, ts)
        distAudioAppendUInt32LE(&packet, sn)
        distAudioAppendUInt32LE(&packet, kcpExpectedSN)
        distAudioAppendUInt32LE(&packet, 0)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func ingestKCPPush(sn: UInt32, payload: Data) {
        if !kcpInitialized {
            kcpInitialized = true
            kcpExpectedSN = sn
        }
        if sn == kcpExpectedSN {
            deliverMediaPayload(payload, sn: sn)
            kcpExpectedSN &+= 1
            var next = kcpPending.removeValue(forKey: kcpExpectedSN)
            while let buffered = next {
                deliverMediaPayload(buffered, sn: kcpExpectedSN)
                kcpExpectedSN &+= 1
                next = kcpPending.removeValue(forKey: kcpExpectedSN)
            }
            return
        }
        let delta = Int64(Int32(bitPattern: sn &- kcpExpectedSN))
        if delta > 0, delta <= 256 {
            kcpPending[sn] = payload
            return
        }
        // Large gap: resync on the newest segment rather than stall.
        DiagnosticsLog.warn(
            "xiaomi.distaudio.downlink_kcp_resync sn=\(sn) expected=\(kcpExpectedSN) gap=\(delta)"
        )
        kcpPending.removeAll()
        kcpExpectedSN = sn &+ 1
        deliverMediaPayload(payload, sn: sn)
    }

    // Each KCP push payload after the deadbeef marker is a run of
    // 188-byte MPEG-TS packets carrying the private_stream_1 (0xbd) PES.
    // The PES payload is the Xiaomi ff02 private-audio format (same as the
    // mirror MPT audio path): 18-byte header + PCM16. The PCM portion is
    // AES-128-ECB encrypted with the distAudio RPC media key.
    private func deliverMediaPayload(_ payload: Data, sn: UInt32) {
        if mediaDumpRemaining > 0 {
            mediaDumpRemaining -= 1
            DiagnosticsLog.info(
                "xiaomi.distaudio.downlink_media sn=\(sn) bytes=\(payload.count) " +
                    "head=\(payload.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
        }
        var stream = tsCarry + payload
        tsCarry = Data()
        var cursor = 0
        while stream.count - cursor >= 188 {
            guard stream[cursor] == 0x47 else {
                // Lost sync: rescan for the next sync byte.
                if let next = stream[(cursor + 1)..<stream.count].firstIndex(of: 0x47) {
                    cursor = next
                    continue
                }
                break
            }
            let packet = stream.subdata(in: cursor..<cursor + 188)
            cursor += 188
            ingestTSPacket(packet)
        }
        if cursor < stream.count {
            tsCarry = Data(stream[cursor...])
        }
    }
    private func ingestTSPacket(_ packet: Data) {
        guard packet.count == 188 else { return }
        let afc = (packet[3] >> 4) & 0x03
        var payloadStart = 4
        if afc == 0x02 {
            return  // adaptation field only
        }
        if afc == 0x03 {
            let afLength = Int(packet[4])
            payloadStart = 5 + afLength
        }
        guard payloadStart < 188 else { return }
        let chunk = packet.subdata(in: payloadStart..<188)
        if chunk.count >= 4, chunk[0] == 0x00, chunk[1] == 0x00, chunk[2] == 0x01, chunk[3] == 0xBD {
            // New PES: flush the previous one.
            flushPES()
            pesBuffer = chunk
            pesExpectedLength = chunk.count >= 6 ? 6 + (Int(chunk[4]) << 8 | Int(chunk[5])) : nil
            return
        }
        if !pesBuffer.isEmpty {
            pesBuffer.append(chunk)
            if let expected = pesExpectedLength, pesBuffer.count >= expected {
                flushPES()
            }
        }
    }

    private func flushPES() {
        defer {
            pesBuffer = Data()
            pesExpectedLength = nil
        }
        guard pesBuffer.count > 9,
              pesBuffer[0] == 0x00, pesBuffer[1] == 0x00, pesBuffer[2] == 0x01, pesBuffer[3] == 0xBD
        else { return }
        let headerDataLength = Int(pesBuffer[8])
        let payloadStart = 9 + headerDataLength
        guard payloadStart < pesBuffer.count else { return }
        let pesPayload = pesBuffer.subdata(in: payloadStart..<pesBuffer.count)
        pesCount += 1
        guard pesPayload.count >= 18, pesPayload[0] == 0xFF, pesPayload[1] == 0x02 else {
            if pesCount <= 5 {
                DiagnosticsLog.warn(
                    "xiaomi.distaudio.downlink_pes_unexpected bytes=\(pesPayload.count) " +
                        "head=\(pesPayload.prefix(24).map { String(format: "%02x", $0) }.joined())"
                )
            }
            return
        }
        // ff02 header = 18 bytes; declared PCM length at offset 8 (u32 BE).
        var declared = (Int(pesPayload[8]) << 24) | (Int(pesPayload[9]) << 16) |
            (Int(pesPayload[10]) << 8) | Int(pesPayload[11])
        if declared <= 0 || declared > pesPayload.count - 18 {
            declared = pesPayload.count - 18
        }
        let encrypted = pesPayload.subdata(in: 18..<18 + declared)
        guard encrypted.count >= 16, encrypted.count % 16 == 0 else {
            if pesCount <= 5 {
                DiagnosticsLog.warn(
                    "xiaomi.distaudio.downlink_pcm_short declared=\(declared) payload=\(pesPayload.count)"
                )
            }
            return
        }
        let pcm = DistAudioECB.decrypt(encrypted, key: mediaKey)
        if isPlausiblePCM(pcm) {
            statsBytes += pcm.count
            if statsBytes - pcm.count == 0 {
                DiagnosticsLog.info(
                    "xiaomi.distaudio.downlink_pcm_first bytes=\(pcm.count) " +
                        "prefix=\(pcm.prefix(16).map { String(format: "%02x", $0) }.joined())"
                )
            }
            player?.write(pcm)
        } else if pesCount <= 5 {
            DiagnosticsLog.warn(
                "xiaomi.distaudio.downlink_pcm_implausible pes=\(pesCount) bytes=\(pcm.count) " +
                    "prefix=\(pcm.prefix(16).map { String(format: "%02x", $0) }.joined()) " +
                    "cipherHead=\(encrypted.prefix(16).map { String(format: "%02x", $0) }.joined())"
            )
        }
    }

    private func isPlausiblePCM(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        var nonzero = 0
        for byte in data.prefix(64) where byte != 0 { nonzero += 1 }
        return nonzero > 4
    }

    func prepareClientMediaPort() -> UInt16 {
        if clientMediaPort == 0 {
            clientMediaPort = UInt16.random(in: 30000...60000)
        }
        return clientMediaPort
    }
}

// Uplink: Mac mic → our MiCastServer equivalent → phone's MiCastClient.
final class LyraDistAudioWFDServer {
    private let mediaKey: Data
    private let queue = DispatchQueue(label: "edgelink.lyra.distaudio.wfdserver")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var parsers: [ObjectIdentifier: LyraDistAudioWFD.MessageParser] = [:]
    private var ourCSeq = 0
    private var ourAuthMsg = LyraDistAudioWFD.randomAuthMsg()
    private var clientMediaPort: UInt16 = 0
    private var peerHost: String?
    private var peerPort: UInt16 = 0
    private var uplink: LyraDistAudioUplink?

    init(mediaKeyBase64: String) {
        self.mediaKey = Data(base64Encoded: mediaKeyBase64) ?? Data()
    }

    var port: UInt16? { listener?.port?.rawValue }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        var waited = 0
        while listener.port == nil, waited < 100 {
            Thread.sleep(forTimeInterval: 0.01)
            waited += 1
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            for connection in self.connections { connection.cancel() }
            self.connections.removeAll()
            self.uplink?.stop()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        peerHost = connection.endpoint.debugDescription.components(separatedBy: ":").first
        peerPort = UInt16(connection.endpoint.debugDescription.components(separatedBy: ":").last ?? "") ?? 0
        DiagnosticsLog.info("xiaomi.distaudio.uplink_conn from=\(connection.endpoint.debugDescription) listenPort=\(port.map(String.init) ?? "?")")
        connection.start(queue: queue)
        receive(connection)
        // The phone's MiCastServer speaks first in the downlink direction
        // (M1 OPTIONS); mirror that as the uplink server.
        ourCSeq += 1
        send(
            LyraDistAudioWFD.serializeRequest(
                method: "OPTIONS", target: "*", cseq: ourCSeq,
                headers: [
                    "Require: org.wfa.wfd1.0",
                    "lib_version: miplaycast_os3_release1.6 3.1.5120912",
                    "authMsg:\(ourAuthMsg)",
                    // The phone sink's setAuthMsgAck parses these two
                    // headers into its keyType/algorithm members; without
                    // them its algorithm stays 0 and every authMsgAck we
                    // send fails validation (authAlgorithmType:0x0).
                    "authKeyType: 1",
                    "authAlgorithmTypes: 7",
                    "fastRTSPVersion: 0",
                ],
                body: ""
            ),
            on: connection, label: "options_m1"
        )
    }

    private func receive(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if parsers[key] == nil {
                    parsers[key] = LyraDistAudioWFD.MessageParser()
                }
                for message in parsers[key]!.append(data) {
                    handleMessage(message.firstLine, message.headers, message.body, connection)
                }
            }
            if complete || error != nil {
                DiagnosticsLog.info("xiaomi.distaudio.uplink_conn_end err=\(String(describing: error))")
                return
            }
            receive(connection)
        }
    }

    private func send(_ data: Data, on connection: NWConnection, label: String) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.error("xiaomi.distaudio.uplink_tx_failed \(label)", error)
            }
        })
    }

    private func handleMessage(
        _ firstLine: String, _ headers: [String: String], _ body: Data, _ connection: NWConnection
    ) {
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        if firstLine.hasPrefix("RTSP/") {
            let cseq = headers["cseq"].flatMap(Int.init) ?? -1
            DiagnosticsLog.info("xiaomi.distaudio.uplink_response cseq=\(cseq) stage=\(uplinkStage.rawValue) body=\(bodyText.prefix(200)) firstLine=\(firstLine) headers=\(headers.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: "|"))")
            guard firstLine.contains("200") else { return }
            switch uplinkStage {
            case .awaitM1Response:
                // M2 response from the phone: drive M3 GET_PARAMETER.
                uplinkStage = .awaitM3Response
                ourCSeq += 1
                let query = [
                    "wfd_content_SP_protection",
                    "wfd_audio_codecs_v2",
                    "wfd_client_rtp_ports",
                    "wfd_buffer_capabity",
                    "",
                ].joined(separator: "\r\n")
                send(
                    LyraDistAudioWFD.serializeRequest(
                        method: "GET_PARAMETER", target: "rtsp://localhost/wfd1.0", cseq: ourCSeq,
                        headers: [], body: query
                    ),
                    on: connection, label: "getparam_m3"
                )
            case .awaitM3Response:
                // Capability response: pick the offered audio codec, send M4
                // + trigger SETUP. The sink's SETUP carries its client_port.
                if let offered = parseAudioCodecOffer(bodyText) {
                    selectedAudioCodec = offered
                }
                uplinkStage = .awaitSetupRequest
                ourCSeq += 1
                let m4 = [
                    "wfd_audio_codecs_v2: \(selectedAudioCodec) 1",
                    "wfd_type_encryp: 4 1 1 1 1",
                    "wfd_buffer_capabity: 1F",
                    "",
                ].joined(separator: "\r\n")
                send(
                    LyraDistAudioWFD.serializeRequest(
                        method: "SET_PARAMETER", target: "rtsp://localhost/wfd1.0", cseq: ourCSeq,
                        headers: [], body: m4
                    ),
                    on: connection, label: "setparam_m4"
                )
                ourCSeq += 1
                send(
                    LyraDistAudioWFD.serializeRequest(
                        method: "SET_PARAMETER", target: "rtsp://localhost/wfd1.0", cseq: ourCSeq,
                        headers: [], body: "wfd_trigger_method: SETUP\r\n"
                    ),
                    on: connection, label: "trigger_setup"
                )
            case .awaitPlayRequest:
                break
            default:
                break
            }
            return
        }
        let method = firstLine.split(separator: " ").first.map(String.init) ?? ""
        let cseq = headers["cseq"].flatMap(Int.init) ?? 0
        DiagnosticsLog.info(
            "xiaomi.distaudio.uplink_rx method=\(method) cseq=\(cseq) bodyBytes=\(body.count) " +
                "firstLine=\(firstLine) headers=\(headers.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: "|"))"
        )
        switch method {
        case "OPTIONS":
            let authMsg = headers["authmsg"] ?? ""
            // Uplink session: we are the RTSP server (listen address),
            // the phone is the client. Composite = server + client,
            // verified against the phone's own ack (21:05 round).
            let key = LyraDistAudioWFD.miplaySessionKey(
                serverIP: localListenIP(), serverPort: port ?? 0,
                clientIP: peerHost ?? "", clientPort: peerPort
            )
            send(
                LyraDistAudioWFD.serializeResponse(
                    cseq: cseq,
                    headers: [
                        "Public: org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER",
                        "authKeyType: 1",
                        "authAlgorithmVal: 4",
                        "authMsgAck:\(LyraDistAudioWFD.sessionAuthMsgAck(for: authMsg, key: key))",
                        "fastRTSPVersion: 0",
                    ],
                    body: ""
                ),
                on: connection, label: "options_response"
            )
        case "GET_PARAMETER":
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), on: connection, label: "getparam_response")
        case "SET_PARAMETER":
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), on: connection, label: "setparam_response")
        case "SETUP":
            // The phone (sink) sends SETUP with its client_port; answer with
            // our server_port, then it sends PLAY.
            if let transport = headers["transport"] {
                for component in transport.components(separatedBy: ";") {
                    let pair = component.trimmingCharacters(in: .whitespaces)
                    if pair.hasPrefix("client_port="),
                       let port = UInt16(pair.dropFirst("client_port=".count)) {
                        clientMediaPort = port
                    }
                }
            }
            let serverMediaPort = UInt16.random(in: 30000...60000)
            let sessionId = UInt32.random(in: 100000...999999999)
            send(
                LyraDistAudioWFD.serializeResponse(
                    cseq: cseq,
                    headers: [
                        "Session: \(sessionId);timeout=60",
                        "Transport: RTP/AVP/MPT;unicast;client_port=\(clientMediaPort);server_port=\(serverMediaPort)",
                    ],
                    body: ""
                ),
                on: connection, label: "setup_response"
            )
            prepareMediaPush(serverPort: serverMediaPort)
        case "PLAY":
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), on: connection, label: "play_response")
            startMediaPush()
        case "TEARDOWN":
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), on: connection, label: "teardown_response")
            uplink?.stop()
        default:
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), on: connection, label: "generic_response")
        }
    }

    // The composite needs our WiFi IP (the one the phone reaches us at).
    // Resolve it from a throwaway UDP socket aimed at the peer; fall
    // back to the listener's any-address if that fails.
    private func localListenIP() -> String {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(8236).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(peerHost ?? "10.0.0.126"))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return "" }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let name = withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard name == 0 else { return "" }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addrCopy = local.sin_addr
        guard inet_ntop(AF_INET, &addrCopy, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buf)
    }

    private enum UplinkStage: String {
        case awaitM1Response
        case awaitM3Response
        case awaitSetupRequest
        case awaitPlayRequest
    }

    private var uplinkStage = UplinkStage.awaitM1Response
    private var selectedAudioCodec = 0

    private func parseAudioCodecOffer(_ body: String) -> Int? {
        guard let range = body.range(of: "wfd_audio_codecs_v2") else { return nil }
        let tail = body[range.upperBound...]
        let tokens = tail.split(whereSeparator: { $0 == " " || $0 == "\r" || $0 == "\n" || $0 == ":" })
        for token in tokens {
            if let codec = Int(token) {
                return codec
            }
        }
        return nil
    }

    private func parseClientMediaPort(_ body: String) -> UInt16? {
        guard let range = body.range(of: "wfd_client_rtp_ports") else { return nil }
        let tail = body[range.upperBound...]
        let numbers = tail.split(whereSeparator: { $0 == " " || $0 == "\r" || $0 == "\n" || $0 == ";" })
        for token in numbers {
            if let port = UInt16(token), port > 1024 {
                return port
            }
        }
        return nil
    }

    private var pendingServerPort: UInt16 = 0

    private func prepareMediaPush(serverPort: UInt16) {
        pendingServerPort = serverPort
    }

    private func startMediaPush() {
        guard uplink == nil, let peerHost, clientMediaPort > 0 else { return }
        let uplink = LyraDistAudioUplink(
            host: peerHost, port: clientMediaPort, localPort: pendingServerPort, mediaKey: mediaKey
        )
        self.uplink = uplink
        uplink.start()
        DiagnosticsLog.info("xiaomi.distaudio.uplink_media_start host=\(peerHost) port=\(clientMediaPort)")
    }
}

// Mic capture → AES-ECB → UDP RTP push to the phone.
final class LyraDistAudioUplink {
    private let host: String
    private let port: UInt16
    private let localPort: UInt16
    private let mediaKey: Data
    private let queue = DispatchQueue(label: "edgelink.lyra.distaudio.uplink")
    private var connection: NWConnection?
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private let ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)

    init(host: String, port: UInt16, localPort: UInt16, mediaKey: Data) {
        self.host = host
        self.port = port
        self.localPort = localPort
        self.mediaKey = mediaKey
    }

    func start() {
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp
        )
        self.connection = connection
        connection.start(queue: queue)
        startCapture()
    }

    func stop() {
        queue.async { [weak self] in
            self?.engine?.stop()
            self?.engine?.inputNode.removeTap(onBus: 0)
            self?.engine = nil
            self?.connection?.cancel()
        }
    }

    private func startCapture() {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        )!
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 640, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer, targetFormat: targetFormat)
        }
        do {
            try engine.start()
        } catch {
            DiagnosticsLog.error("xiaomi.distaudio.uplink_capture_failed", error)
        }
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter else { return }
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * (16000.0 / buffer.format.sampleRate)
        )
        guard frameCount > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
        else { return }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0,
              let channelData = out.int16ChannelData?[0]
        else { return }
        let byteCount = Int(out.frameLength) * 2
        let pcm = Data(bytes: channelData, count: byteCount)
        let encrypted = DistAudioECB.encrypt(pcm, key: mediaKey)
        let packet = buildRTP(payload: encrypted)
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func buildRTP(payload: Data) -> Data {
        var packet = Data(count: 12)
        packet[0] = 0x80
        packet[1] = 0x60
        withUnsafeBytes(of: sequence.bigEndian) { packet.replaceSubrange(2..<4, with: $0) }
        withUnsafeBytes(of: timestamp.bigEndian) { packet.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: ssrc.bigEndian) { packet.replaceSubrange(8..<12, with: $0) }
        sequence &+= 1
        timestamp &+= UInt32(payload.count / 2)
        packet.append(payload)
        return packet
    }
}

// 16kHz mono s16le PCM playback for the downlink.
final class LyraDistAudioPlayer {
    private let sampleRate: Double
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "edgelink.lyra.distaudio.player")

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func start() {
        queue.async { [weak self] in
            guard let self, engine == nil else { return }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
            )!
            self.engine = engine
            self.player = player
            self.format = format
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
                player.play()
                DiagnosticsLog.info("xiaomi.distaudio.player_start rate=\(sampleRate)")
            } catch {
                DiagnosticsLog.error("xiaomi.distaudio.player_start_failed", error)
            }
        }
    }

    func write(_ pcm: Data) {
        queue.async { [weak self] in
            guard let self, let player, let format, player.engine != nil else { return }
            let frameCount = AVAudioFrameCount(pcm.count / 2)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            else { return }
            buffer.frameLength = frameCount
            pcm.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(buffer.int16ChannelData![0], base, pcm.count)
                }
            }
            player.scheduleBuffer(buffer, completionHandler: nil)
            if !player.isPlaying {
                player.play()
            }
        }
    }

    func stop(reason: String) {
        queue.async { [weak self] in
            self?.player?.stop()
            self?.engine?.stop()
            self?.player = nil
            self?.engine = nil
            DiagnosticsLog.info("xiaomi.distaudio.player_stop reason=\(reason)")
        }
    }
}
