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
    private var mediaConnection: NWConnection?
    private var mediaDecoder: LyraDistAudioMediaDecoder?

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
        let decoder = LyraDistAudioMediaDecoder(mediaKey: mediaKey)
        decoder.onPCM = { [weak self] pcm in
            guard let self else { return }
            self.statsBytes += pcm.count
            if self.statsBytes - pcm.count == 0 {
                DiagnosticsLog.info(
                    "xiaomi.distaudio.downlink_pcm_first bytes=\(pcm.count) " +
                        "prefix=\(pcm.prefix(16).map { String(format: "%02x", $0) }.joined())"
                )
            }
            self.player?.write(pcm)
        }
        decoder.onSendACK = { [weak self] packet in
            self?.mediaConnection?.send(content: packet, completion: .contentProcessed { _ in })
        }
        decoder.onWarn = { message in
            DiagnosticsLog.warn(message)
        }
        decoder.onPushPayload = { [weak self] sn, payload in
            guard let self, self.mediaDumpRemaining > 0 else { return }
            self.mediaDumpRemaining -= 1
            DiagnosticsLog.info(
                "xiaomi.distaudio.downlink_media sn=\(sn) bytes=\(payload.count) " +
                    "head=\(payload.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
        }
        mediaDecoder = decoder
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
                mediaDecoder?.feed(datagram: data)
            }
            if error == nil, stage == .established {
                receiveMedia(connection)
            }
        }
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
                // M4 selection is "<encodeType> <modeIndex>" (sscanf "%d %d",
                // then AudioFormats::GetConfiguration). The capability bitmask
                // (16) is NOT a valid encodeType (phone logs "invalid type:16"
                // and leaves the audio format all-zero = silence). encodeType
                // 0 = LPCM; mode index 4 = 16kHz/1ch/16-bit (the distaudio
                // format; the official mirror used "0 1" = 48kHz/2ch).
                let m4 = [
                    "wfd_audio_codecs_v2: 0 4",
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
            // our server_port, then it sends PLAY. client_port may be a
            // range ("15550-15551" = RTP+RTCP); take the first port.
            if let transport = headers["transport"] {
                for component in transport.components(separatedBy: ";") {
                    let pair = component.trimmingCharacters(in: .whitespaces)
                    if pair.hasPrefix("client_port=") {
                        let value = pair.dropFirst("client_port=".count)
                        let firstPort = value.components(separatedBy: "-").first ?? ""
                        if let port = UInt16(firstPort) {
                            clientMediaPort = port
                        }
                    }
                }
            }
            DiagnosticsLog.info("xiaomi.distaudio.uplink_setup clientMediaPort=\(clientMediaPort) transport=\(headers["transport"] ?? "none")")
            // RTP ports must be even (the phone logs "Server picked an odd
            // numbered RTP port." otherwise); bind our media socket to it so
            // packets actually carry the declared source port.
            let serverMediaPort = (UInt16.random(in: 15000...30000)) & 0xFFFE
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
        guard uplink == nil else {
            DiagnosticsLog.info("xiaomi.distaudio.uplink_media_start_skipped reason=already_running")
            return
        }
        guard let peerHost, clientMediaPort > 0 else {
            DiagnosticsLog.warn(
                "xiaomi.distaudio.uplink_media_start_skipped reason=missing_target " +
                    "peerHost=\(peerHost ?? "nil") clientMediaPort=\(clientMediaPort)"
            )
            return
        }
        let uplink = LyraDistAudioUplink(
            host: peerHost, port: clientMediaPort, localPort: pendingServerPort, mediaKey: mediaKey
        )
        self.uplink = uplink
        uplink.start()
        DiagnosticsLog.info("xiaomi.distaudio.uplink_media_start host=\(peerHost) port=\(clientMediaPort)")
    }
}

// Mic capture → AES-ECB → UDP RTP push to the phone. The sink parses plain
// RTP on its first client_port (parseRTP reached directly, mRtpUseLyra=0;
// KCP/framed datagrams fail the RTP version check with err -1010). The RTP
// payload must carry the MPEG-TS container (PAT/PMT + private_stream_1 PES
// with the ff02 private-audio header + encrypted PCM) — raw cipher blobs
// parse as RTP but never reach the audio decoder.
final class LyraDistAudioUplink {
    private let host: String
    private let port: UInt16
    private let localPort: UInt16
    private let mediaKey: Data
    private let queue = DispatchQueue(label: "edgelink.lyra.distaudio.uplink")
    private var connection: NWConnection?
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    // 20ms s16le mono frames (640 bytes) accumulate here between taps.
    private var pcmCarry = Data()
    private var frameIndex: UInt32 = 0
    private var sequence: UInt16 = 0
    private var pts90k: UInt32 = 0
    private let ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var esContinuityCounter: UInt8 = 0
    private var psiContinuityCounter: UInt8 = 0
    private static let pcmFrameBytes = 640
    // The phone's renderer waits for an RTCP sender report to anchor its
    // MediaClock before it drains audio (without one the pipeline primes a
    // few buffers and stalls). Mirror the mirror path: one SR per second to
    // the RTCP port (client_port + 1), sent from server_port + 1.
    private var rtcpConnection: NWConnection?
    private var rtcpTimer: DispatchSourceTimer?
    private var rtcpSRSent = 0

    init(host: String, port: UInt16, localPort: UInt16, mediaKey: Data) {
        self.host = host
        self.port = port
        self.localPort = localPort
        self.mediaKey = mediaKey
    }

    func start() {
        let parameters = NWParameters.udp
        // Send from the declared server_port so packets match the SETUP
        // transport (without this NWConnection uses an ephemeral port).
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("0.0.0.0"), port: NWEndpoint.Port(rawValue: localPort)!
        )
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DiagnosticsLog.info("xiaomi.distaudio.uplink_media_ready host=\(self?.host ?? "") port=\(self?.port ?? 0)")
            case .failed(let error):
                DiagnosticsLog.warn("xiaomi.distaudio.uplink_media_failed \(String(describing: error))")
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A/B probe: /tmp/edgelink-distaudio-no-rtcp disables the RTCP
        // socket + SRs. Every round so far, the phone's RTP delivery
        // dies the instant its SECOND kWhatRTPConnect fires (whichever
        // leg — RTP or RTCP — is second), so test whether the RTCP
        // connect notification is what corrupts the RTP session.
        if Self.debugNoRTCP() {
            DiagnosticsLog.info("xiaomi.distaudio.uplink_rtcp_disabled_by_debug")
        } else {
            startRTCP()
        }
        startCapture()
    }

    static func debugNoRTCP() -> Bool {
        FileManager.default.fileExists(atPath: "/tmp/edgelink-distaudio-no-rtcp")
    }

    private func startRTCP() {
        let rtcpParameters = NWParameters.udp
        rtcpParameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("0.0.0.0"), port: NWEndpoint.Port(rawValue: localPort &+ 1)!
        )
        let rtcp = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port &+ 1)!, using: rtcpParameters
        )
        rtcpConnection = rtcp
        rtcp.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                DiagnosticsLog.info("xiaomi.distaudio.uplink_rtcp_ready port=\(self?.port ?? 0)")
            }
        }
        rtcp.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.sendRTCPSenderReport()
        }
        rtcpTimer = timer
        timer.resume()
    }

    private func sendRTCPSenderReport() {
        guard let rtcpConnection else { return }
        var packet = Data(capacity: 28)
        packet.append(0x80)
        packet.append(200)
        packet.append(contentsOf: [0x00, 0x06])
        packet.append(UInt8((ssrc >> 24) & 0xff))
        packet.append(UInt8((ssrc >> 16) & 0xff))
        packet.append(UInt8((ssrc >> 8) & 0xff))
        packet.append(UInt8(ssrc & 0xff))
        let ntpEpochOffset: TimeInterval = 2_208_988_800
        let timestamp = Date().timeIntervalSince1970 + ntpEpochOffset
        let seconds = UInt32(timestamp)
        let fraction = UInt32((timestamp - floor(timestamp)) * 4_294_967_296)
        for value in [seconds, fraction, pts90k] {
            packet.append(UInt8((value >> 24) & 0xff))
            packet.append(UInt8((value >> 16) & 0xff))
            packet.append(UInt8((value >> 8) & 0xff))
            packet.append(UInt8(value & 0xff))
        }
        let packets = UInt32(truncatingIfNeeded: sentPackets)
        let octets = UInt32(truncatingIfNeeded: sentBytes)
        for value in [packets, octets] {
            packet.append(UInt8((value >> 24) & 0xff))
            packet.append(UInt8((value >> 16) & 0xff))
            packet.append(UInt8((value >> 8) & 0xff))
            packet.append(UInt8(value & 0xff))
        }
        rtcpSRSent += 1
        let count = rtcpSRSent
        rtcpConnection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                DiagnosticsLog.error("xiaomi.distaudio.uplink_rtcp_sr_failed count=\(count)", error)
            } else if count <= 3 || count % 10 == 0 {
                DiagnosticsLog.info(
                    "xiaomi.distaudio.uplink_rtcp_sr count=\(count) rtpTime=\(self?.pts90k ?? 0) packets=\(packets)"
                )
            }
        })
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        queue.async { [weak self] in
            DiagnosticsLog.info(
                "xiaomi.distaudio.uplink_stop taps=\(self?.tapInvocations ?? 0) buffers=\(self?.captureBuffers ?? 0) " +
                    "sent=\(self?.sentPackets ?? 0) failures=\(self?.sendFailures ?? 0)"
            )
            self?.engine?.stop()
            self?.engine?.inputNode.removeTap(onBus: 0)
            self?.engine = nil
            self?.rtcpTimer?.cancel()
            self?.rtcpTimer = nil
            self?.rtcpConnection?.cancel()
            self?.rtcpConnection = nil
            self?.connection?.cancel()
        }
    }

    private var captureBuffers = 0
    private var sentPackets = 0
    private var sentBytes = 0
    private var sendFailures = 0
    private var tapInvocations = 0
    private var skippedBuffers = 0
    private var captureRestarts = 0
    private var configObserver: NSObjectProtocol?

    private func startCapture() {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        )!
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        DiagnosticsLog.info(
            "xiaomi.distaudio.uplink_capture_start inputRate=\(inputFormat.sampleRate) " +
                "inputChannels=\(inputFormat.channelCount) converter=\(converter != nil) restarts=\(captureRestarts)"
        )
        input.installTap(onBus: 0, bufferSize: 640, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer, targetFormat: targetFormat)
        }
        do {
            try engine.start()
            DiagnosticsLog.info("xiaomi.distaudio.uplink_capture_running isRunning=\(engine.isRunning)")
        } catch {
            DiagnosticsLog.error("xiaomi.distaudio.uplink_capture_failed", error)
        }
        // Route changes (another engine starting, device switches) stop the
        // engine silently and the tap never fires again — restart it.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
            ) { [weak self] note in
                // Only react to OUR capture engine being reconfigured.
                guard let self, note.object as AnyObject === self.engine else { return }
                self.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.captureRestarts < 5 else {
                DiagnosticsLog.warn("xiaomi.distaudio.uplink_capture_restart_gave_up restarts=\(self.captureRestarts)")
                return
            }
            self.captureRestarts += 1
            DiagnosticsLog.warn(
                "xiaomi.distaudio.uplink_capture_restart n=\(self.captureRestarts) " +
                    "isRunning=\(self.engine?.isRunning ?? false) taps=\(self.tapInvocations) buffers=\(self.captureBuffers)"
            )
            self.engine?.stop()
            self.engine?.inputNode.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            self.startCapture()
        }
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        tapInvocations += 1
        if tapInvocations % 500 == 0 {
            DiagnosticsLog.info(
                "xiaomi.distaudio.uplink_tap_progress taps=\(tapInvocations) buffers=\(captureBuffers) " +
                    "skipped=\(skippedBuffers) sent=\(sentPackets) engineRunning=\(engine?.isRunning ?? false)"
            )
        }
        guard let converter else { return }
        // Generous capacity: the converter may need several internal passes
        // (and resampler priming) before it emits frames for one input.
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * (16000.0 / buffer.format.sampleRate)
        ) + 1024
        guard frameCount > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
        else {
            skippedBuffers += 1
            if skippedBuffers <= 3 {
                DiagnosticsLog.warn(
                    "xiaomi.distaudio.uplink_skip_buffer reason=frame_count frames=\(buffer.frameLength) rate=\(buffer.format.sampleRate)"
                )
            }
            return
        }
        // Streaming pattern: feed this tap buffer once, then noDataNow.
        // NEVER endOfStream — that puts the reused converter into a
        // terminal state and every later buffer converts to zero frames
        // (observed live: 1 good packet, then 756 conversion_empty).
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if !supplied {
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error, out.frameLength > 0,
              let channelData = out.int16ChannelData?[0]
        else {
            skippedBuffers += 1
            if skippedBuffers <= 3 {
                DiagnosticsLog.warn(
                    "xiaomi.distaudio.uplink_skip_buffer reason=conversion_empty inFrames=\(buffer.frameLength) " +
                        "status=\(status.rawValue) error=\(String(describing: conversionError))"
                )
            }
            return
        }
        let byteCount = Int(out.frameLength) * 2
        let pcm = Data(bytes: channelData, count: byteCount)
        captureBuffers += 1
        if captureBuffers <= 3 {
            var nonzero = 0
            var maxAbs = 0
            for i in stride(from: 0, to: pcm.count - 1, by: 2) {
                let sample = Int(Int16(bitPattern: UInt16(pcm[i]) | (UInt16(pcm[i + 1]) << 8)))
                if sample != 0 { nonzero += 1 }
                maxAbs = max(maxAbs, abs(sample))
            }
            DiagnosticsLog.info(
                "xiaomi.distaudio.uplink_capture_buffer n=\(captureBuffers) bytes=\(byteCount) " +
                    "nonzero=\(nonzero) maxAbs=\(maxAbs)"
            )
        }
        pcmCarry.append(pcm)
        while pcmCarry.count >= Self.pcmFrameBytes {
            let frame = pcmCarry.prefix(Self.pcmFrameBytes)
            pcmCarry.removeFirst(Self.pcmFrameBytes)
            sendAudioFrame(Data(frame))
        }
    }

    // One RTP packet per 20ms audio frame: payload = [PAT+PMT every 6th
    // frame] + PES(0xbd) TS packets; the PES payload is the ff02 header +
    // AES-ECB PCM. The very first packet carries an ff03 format announce
    // PES. TS parameters (stream_type 0x83, ES pid 0x1100, PMT pid 0x100,
    // descriptor 83 02 46 2f) mirror the phone's own downlink TS stream
    // byte-for-byte — the sink's ATSParser ignored our old stream_type 6
    // stream entirely (pipeline stalled after ~10 RTP packets).
    private func sendAudioFrame(_ pcm: Data) {
        let cipher = DistAudioECB.encrypt(pcm, key: mediaKey)
        var tsPackets: [Data] = []
        if frameIndex == 0 {
            // ff03 announce (as observed on the phone's downlink): PES
            // payload = ff ff ff ff + 14-byte ff03 header.
            let announce = Data([
                0xff, 0xff, 0xff, 0xff, 0x03, 0x00, 0x00, 0x00, 0x0e, 0x01,
                0x10, 0x00, 0x00, 0x3e, 0x80, 0x00, 0x00, 0x08,
            ])
            tsPackets.append(contentsOf: packetizeES(makePESPacket(payload: announce, pts: pts90k)))
        }
        if frameIndex % 6 == 0 {
            tsPackets.append(Self.makePSIPacket(section: Self.patSection, continuity: &psiContinuityCounter, pid: 0))
            tsPackets.append(Self.makePSIPacket(section: Self.pmtSection, continuity: &psiContinuityCounter, pid: 0x100))
        }
        let pesPacket = makePESPacket(payload: makeFF02Frame(cipher: cipher), pts: pts90k)
        tsPackets.append(contentsOf: packetizeES(pesPacket))
        var payload = Data()
        for packet in tsPackets { payload.append(packet) }

        var packet = Data(capacity: 12 + payload.count)
        packet.append(0x80)
        packet.append(0x60 | 33)  // marker + PT 33 (TS payload, mirror-style)
        packet.append(UInt8(sequence >> 8))
        packet.append(UInt8(sequence & 0xff))
        packet.append(UInt8((pts90k >> 24) & 0xff))
        packet.append(UInt8((pts90k >> 16) & 0xff))
        packet.append(UInt8((pts90k >> 8) & 0xff))
        packet.append(UInt8(pts90k & 0xff))
        packet.append(UInt8((ssrc >> 24) & 0xff))
        packet.append(UInt8((ssrc >> 16) & 0xff))
        packet.append(UInt8((ssrc >> 8) & 0xff))
        packet.append(UInt8(ssrc & 0xff))
        packet.append(payload)
        sequence &+= 1

        connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.sendFailures += 1
                if self.sendFailures <= 3 {
                    DiagnosticsLog.error("xiaomi.distaudio.uplink_send_failed n=\(self.sendFailures)", error)
                }
                return
            }
            self.sentPackets += 1
            self.sentBytes += packet.count
            if self.sentPackets <= 3 {
                DiagnosticsLog.info(
                    "xiaomi.distaudio.uplink_send_packet n=\(self.sentPackets) bytes=\(packet.count) " +
                        "head=\(packet.prefix(28).map { String(format: "%02x", $0) }.joined())"
                )
            } else if self.sentPackets % 500 == 0 {
                DiagnosticsLog.info(
                    "xiaomi.distaudio.uplink_send_progress packets=\(self.sentPackets) " +
                        "bytes=\(self.sentBytes) failures=\(self.sendFailures)"
                )
            }
        })
        frameIndex &+= 1
        pts90k &+= 1800
    }

    private func makePESPacket(payload frame: Data, pts: UInt32) -> Data {
        let headerData = Self.encodePTS(pts)
        var pes = Data([0x00, 0x00, 0x01, 0xbd])
        let packetLength = UInt16(3 + headerData.count + frame.count)
        pes.append(UInt8(packetLength >> 8))
        pes.append(UInt8(packetLength & 0xff))
        pes.append(contentsOf: [0x84, 0x80, UInt8(headerData.count)])
        pes.append(headerData)
        pes.append(frame)
        return pes
    }

    // ff02 frame as observed on the downlink: magic, u32BE 16, two zero
    // bytes, cipher length u32 LE at 8, six zero bytes.
    private func makeFF02Frame(cipher: Data) -> Data {
        var frame = Data([0xff, 0x02, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00])
        frame.append(UInt8(cipher.count & 0xff))
        frame.append(UInt8((cipher.count >> 8) & 0xff))
        frame.append(UInt8((cipher.count >> 16) & 0xff))
        frame.append(UInt8((cipher.count >> 24) & 0xff))
        frame.append(contentsOf: [UInt8](repeating: 0, count: 6))
        frame.append(cipher)
        return frame
    }

    // 5-byte PTS field as observed (pts 0 → 21 00 01 00 01).
    private static func encodePTS(_ pts: UInt32) -> Data {
        Data([
            UInt8(0x21 | ((pts >> 29) & 0x0e)),
            UInt8((pts >> 22) & 0xff),
            UInt8(((pts >> 14) & 0xfe) | 0x01),
            UInt8((pts >> 7) & 0xff),
            UInt8(((pts << 1) & 0xfe) | 0x01),
        ])
    }

    private func packetizeES(_ pes: Data) -> [Data] {
        var packets: [Data] = []
        var offset = 0
        var first = true
        while offset < pes.count {
            let remaining = pes.count - offset
            var packet = Data(count: 188)
            packet[0] = 0x47
            packet[1] = (first ? 0x50 : 0x10) | UInt8((0x1100 >> 8) & 0x1f)
            packet[2] = UInt8(0x1100 & 0xff)
            if remaining >= 184 {
                packet[3] = 0x10 | (esContinuityCounter & 0x0f)
                packet.replaceSubrange(4..<188, with: pes[offset..<offset + 184])
                offset += 184
            } else {
                // Adaptation-field stuffing so the PES ends flush with the
                // 188-byte grid (observed on the downlink).
                let stuffing = 183 - remaining
                packet[3] = 0x30 | (esContinuityCounter & 0x0f)
                packet[4] = UInt8(stuffing)
                if stuffing > 0 {
                    packet[5] = 0x00
                    for i in 6..<(5 + stuffing) { packet[i] = 0xff }
                }
                packet.replaceSubrange(4 + 1 + stuffing..<188, with: pes[offset..<pes.count])
                offset = pes.count
            }
            esContinuityCounter &+= 1
            first = false
            packets.append(packet)
        }
        return packets
    }

    private static func makePSIPacket(section: Data, continuity: inout UInt8, pid: UInt16) -> Data {
        var packet = Data(count: 188)
        packet[0] = 0x47
        packet[1] = 0x40 | UInt8((pid >> 8) & 0x1f)
        packet[2] = UInt8(pid & 0xff)
        packet[3] = 0x10 | (continuity & 0x0f)
        packet[4] = 0x00  // pointer_field
        let bodyLength = 1 + section.count
        if bodyLength < 184 {
            for i in (bodyLength..<184) { packet[4 + 1 + i - bodyLength + 0] = 0xff }
        }
        packet.replaceSubrange(5..<5 + section.count, with: section)
        continuity &+= 1
        return packet
    }

    // PAT exactly as observed on the downlink (program 1 → PMT PID 0x100).
    private static let patSection = Data([
        0x00, 0xb0, 0x0d, 0x00, 0x00, 0xc3, 0x00, 0x00,
        0x00, 0x01, 0xe1, 0x00, 0x2d, 0xf6, 0x52, 0x95,
    ])

    // PMT copied byte-for-byte from the phone's own downlink TS stream
    // (program 1, PCR 0x1000, one stream_type 0x83 private stream at
    // 0x1100 with the 83 02 46 2f descriptor).
    private static let pmtSection: Data = {
        var section = Data([
            0x02, 0xb0, 0x16, 0x00, 0x01, 0xc3, 0x00, 0x00,
            0xf0, 0x00, 0xf0, 0x00,
            0x83, 0xf1, 0x00, 0xf0, 0x04, 0x83, 0x02, 0x46, 0x2f,
        ])
        let crc = mpeg2CRC32(section)
        section.append(UInt8((crc >> 24) & 0xff))
        section.append(UInt8((crc >> 16) & 0xff))
        section.append(UInt8((crc >> 8) & 0xff))
        section.append(UInt8(crc & 0xff))
        return section
    }()

    private static func mpeg2CRC32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04c1_1db7 : crc << 1
            }
        }
        return crc
    }
}

// Media-plane decoder for the distaudio downlink (mockable: feed raw UDP
// datagrams, collect PCM + ACK packets via callbacks). The phone sends KCP
// PUSH segments (conv 0x00001234, cmd 0x51); the length field offset is
// inconsistent across segments (the first push carries one extra byte), so
// framing keys off the 0xdeadbeef marker that terminates every push
// payload's 12-byte framing header instead of trusting the length. After
// the marker comes a run of 188-byte MPEG-TS packets carrying
// private_stream_1 (0xbd) PES; the PES payload is the Xiaomi private-audio
// format (same container as the mirror MPT audio path): ff03 announces the
// format (32-byte header), ff02 carries PCM (18-byte header). The PCM
// portion is AES-128-ECB encrypted with the distAudio RPC media key.
final class LyraDistAudioMediaDecoder {
    static let kcpHeaderLength = 24
    static let kcpCommandPush: UInt8 = 0x51
    static let kcpCommandACK: UInt8 = 0x52
    static let kcpFrameMarker = Data([0xde, 0xad, 0xbe, 0xef])

    var onPCM: ((Data) -> Void)?
    var onSendACK: ((Data) -> Void)?
    var onWarn: ((String) -> Void)?
    var onPushPayload: ((_ sn: UInt32, _ payload: Data) -> Void)?

    private let mediaKey: Data
    private var kcpConv: UInt32?
    private var kcpExpectedSN: UInt32 = 0
    private var kcpInitialized = false
    private var kcpPending: [UInt32: Data] = [:]
    private var tsCarry = Data()
    private var pesBuffer = Data()
    private var pesExpectedLength: Int?
    private(set) var pesCount = 0
    private(set) var pcmBytesDelivered = 0
    // Announced by the ff03 format PES.
    private(set) var announcedSampleRate: UInt32?
    private(set) var announcedChannels: Int?
    private(set) var announcedBitsPerSample: Int?

    init(mediaKey: Data) {
        self.mediaKey = mediaKey
    }

    static func makeACK(conv: UInt32, ts: UInt32, sn: UInt32, una: UInt32) -> Data {
        var packet = Data(capacity: kcpHeaderLength)
        distAudioAppendUInt32LE(&packet, conv)
        packet.append(kcpCommandACK)
        packet.append(0)
        distAudioAppendUInt16LE(&packet, 256)
        distAudioAppendUInt32LE(&packet, ts)
        distAudioAppendUInt32LE(&packet, sn)
        distAudioAppendUInt32LE(&packet, una)
        distAudioAppendUInt32LE(&packet, 0)
        return packet
    }

    func feed(datagram: Data) {
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
        if let conv = kcpConv {
            onSendACK?(Self.makeACK(conv: conv, ts: ts, sn: sn, una: kcpExpectedSN))
        }
        guard let markerRange = datagram.range(of: Self.kcpFrameMarker) else {
            onWarn?(
                "xiaomi.distaudio.downlink_kcp_no_marker sn=\(sn) bytes=\(datagram.count) " +
                    "head=\(datagram.prefix(40).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        ingestKCPPush(sn: sn, payload: Data(datagram[markerRange.upperBound...]))
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
        onWarn?(
            "xiaomi.distaudio.downlink_kcp_resync sn=\(sn) expected=\(kcpExpectedSN) gap=\(delta)"
        )
        kcpPending.removeAll()
        kcpExpectedSN = sn &+ 1
        deliverMediaPayload(payload, sn: sn)
    }

    private func deliverMediaPayload(_ payload: Data, sn: UInt32) {
        onPushPayload?(sn, payload)
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
        // The final TS packet of a PES can sit split into tsCarry even
        // when the PES itself is already complete — flush it here or it
        // waits for the next push (which may start a new PES and flush
        // it late, or never come at all for the last frame of a call).
        if let expected = pesExpectedLength, pesBuffer.count >= expected {
            flushPES()
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
        guard pesPayload.count >= 18, pesPayload[0] == 0xFF else {
            warnUnexpectedPES(pesPayload)
            return
        }
        switch pesPayload[1] {
        case 0x03:
            handleFF03(pesPayload)
        case 0x02:
            handleFF02(pesPayload)
        default:
            warnUnexpectedPES(pesPayload)
        }
    }

    private func warnUnexpectedPES(_ pesPayload: Data) {
        guard pesCount <= 5 else { return }
        onWarn?(
            "xiaomi.distaudio.downlink_pes_unexpected bytes=\(pesPayload.count) " +
                "head=\(pesPayload.prefix(24).map { String(format: "%02x", $0) }.joined())"
        )
    }

    // ff03 announces the stream format: 32-byte header, packedFormat u16 BE
    // at 6 (channels hi / bits lo), sampleRate u32 BE at 8, declaredFrames
    // u32 BE at 12, bitsPerSample u32 BE at 16, declared payload bytes u32
    // BE at 20; encrypted PCM follows the header.
    private func handleFF03(_ pesPayload: Data) {
        guard pesPayload.count >= 32 else {
            warnUnexpectedPES(pesPayload)
            return
        }
        let packedFormat = (Int(pesPayload[6]) << 8) | Int(pesPayload[7])
        let sampleRate = (UInt32(pesPayload[8]) << 24) | (UInt32(pesPayload[9]) << 16) |
            (UInt32(pesPayload[10]) << 8) | UInt32(pesPayload[11])
        let bits = (UInt32(pesPayload[16]) << 24) | (UInt32(pesPayload[17]) << 16) |
            (UInt32(pesPayload[18]) << 8) | UInt32(pesPayload[19])
        announcedChannels = max(1, (packedFormat >> 8) & 0xff)
        announcedBitsPerSample = bits > 0 ? Int(bits) : (packedFormat & 0xff)
        announcedSampleRate = sampleRate > 0 ? sampleRate : nil
        var declared = (Int(pesPayload[20]) << 24) | (Int(pesPayload[21]) << 16) |
            (Int(pesPayload[22]) << 8) | Int(pesPayload[23])
        if declared <= 0 || declared > pesPayload.count - 32 {
            declared = pesPayload.count - 32
        }
        deliverEncryptedPCM(pesPayload.subdata(in: 32..<32 + declared))
    }

    // ff02 carries PCM: 18-byte header, declared PCM length u32 BE at 8.
    private func handleFF02(_ pesPayload: Data) {
        var declared = (Int(pesPayload[8]) << 24) | (Int(pesPayload[9]) << 16) |
            (Int(pesPayload[10]) << 8) | Int(pesPayload[11])
        if declared <= 0 || declared > pesPayload.count - 18 {
            declared = pesPayload.count - 18
        }
        deliverEncryptedPCM(pesPayload.subdata(in: 18..<18 + declared))
    }

    private func deliverEncryptedPCM(_ encrypted: Data) {
        guard encrypted.count >= 16, encrypted.count % 16 == 0 else {
            if pesCount <= 5 {
                onWarn?(
                    "xiaomi.distaudio.downlink_pcm_short declared=\(encrypted.count) pes=\(pesCount)"
                )
            }
            return
        }
        let pcm = DistAudioECB.decrypt(encrypted, key: mediaKey)
        guard isPlausiblePCM(pcm) else {
            if pesCount <= 5 {
                onWarn?(
                    "xiaomi.distaudio.downlink_pcm_implausible pes=\(pesCount) bytes=\(pcm.count) " +
                        "prefix=\(pcm.prefix(16).map { String(format: "%02x", $0) }.joined()) " +
                        "cipherHead=\(encrypted.prefix(16).map { String(format: "%02x", $0) }.joined())"
                )
            }
            return
        }
        pcmBytesDelivered += pcm.count
        onPCM?(pcm)
    }

    private func isPlausiblePCM(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        var nonzero = 0
        for byte in data.prefix(64) where byte != 0 { nonzero += 1 }
        return nonzero > 4
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
