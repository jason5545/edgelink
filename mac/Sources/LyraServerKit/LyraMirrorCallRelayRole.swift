import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// The phone's MirrorCallService (Mirror.apk com.xiaomi.mirror.relay.G +
// i2.C0885B "CallRelayAudioManager") stand-in: the ONLY writer of
// IMirrorOption 0x100707 (Business_IsPhoneRelay, public option 6) anywhere in
// the examined system. Research (2026-08-10, captures/xiaomi-mirror-device +
// libCastService-jni disasm):
//
//   - Phone sends SimpleEventMessage event 23 (MIRROR_CALL_KEY) on the cast
//     DeviceChannel with KeyData JSON {"keyBytes": [X509 SPKI P-256 pubkey
//     as a Gson byte[] int array], "p2pIp": ..., "port": 7102+}.
//   - Pad replies event 23 with its own KeyData; both sides ECDH secp256r1
//     → 32-byte secret → AES key = secret[0..16), IV = secret[16..32).
//   - Pad sends event 24 (MIRROR_CALL_START) on call start; the phone then
//     startSink()s against the pad's KeyData ip:port, or event 31
//     (MIRROR_CALL_SINK_START, vUint32 = port) drives G.W(port) directly.
//   - The sink (MirrorControlAudioSink, option 6=1 → mIsPhoneRelay=1) is a
//     miplaycast WFD client pulling an AAC/ADTS MPEG-TS stream whose PES
//     carry per-PES IVs in PES_private_data and whose payload prefix
//     (min(256, len) & ~15 bytes, AES-128-CBC, Encrypt_Type 4 "AESPART") is
//     encrypted with the ECDH key (TSPacketizer::packetize @0x19c69c).
//
// This role plays that phone side against the Mac's production code:
// KeyData exchange, sink-start events, RTSP client, and media validation.
public final class LyraMirrorCallRelayRole {
    public struct KeyData: Equatable, Sendable {
        public var keyBytes: Data
        public var p2pIp: String
        public var port: Int

        public init(keyBytes: Data, p2pIp: String, port: Int) {
            self.keyBytes = keyBytes
            self.p2pIp = p2pIp
            self.port = port
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case keyExchanged
        case sinkStarting
        case established
        case failed(String)
    }

    public var onEvent: (String) -> Void = { _ in }

    // Assertion surface
    public private(set) var state: State = .idle
    public private(set) var macKeyData: KeyData?
    public private(set) var sharedSecret: Data?
    public private(set) var callStartCount = 0
    public private(set) var sinkStartPort: UInt32?
    public private(set) var callStopCount = 0
    public private(set) var m4Body: String?
    public private(set) var m4SelectsAAC = false
    public private(set) var m4SelectsLPCM8k = false
    public private(set) var setupCompleted = false
    public private(set) var aacFrames = 0
    public private(set) var decryptedAACBytes = 0
    public private(set) var pesIVsSeen = 0
    public private(set) var lastError: String?

    // The phone's own audio-source endpoint info (its KeyData).
    public var phoneP2PIp = "127.0.0.1"
    public let phoneSourcePort = 7102

    private let phoneKey = P256.KeyAgreement.PrivateKey()
    private weak var cast: LyraCastRole?
    private let queue = DispatchQueue(label: "LyraMirrorCallRelayRole")

    // RTSP sink client state
    private var connection: NWConnection?
    private var rtspBuffer = Data()
    private var ourCSeq = 0
    private var ourAuthMsg = LyraMirrorCallRelayRole.randomAuthMsg()
    private var session: String?
    private var clientMediaPort: UInt16 = 0
    private var serverMediaPort: UInt16 = 0
    private var mediaListener: NWListener?
    private var mediaConnection: NWConnection?
    private var peerHost = ""
    private var peerRTSPPort: UInt16 = 0
    private var localTCPPort: UInt16 = 0

    // Media validation state
    private var pesBuffer = Data()
    private var pesExpectedLength: Int?
    private var pmtPID: UInt16?
    private var esPID: UInt16?

    public init() {}

    // X.509 SPKI DER prefix for secp256r1 public keys (fixed 26 bytes) +
    // 65-byte X9.63 uncompressed point.
    public static let p256SPKIPrefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
        0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
        0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ])

    public static func spkiEncode(x963: Data) -> Data {
        p256SPKIPrefix + x963
    }

    public static func spkiDecode(_ der: Data) -> Data? {
        guard der.count == p256SPKIPrefix.count + 65, der.starts(with: p256SPKIPrefix) else {
            return nil
        }
        return der.suffix(65)
    }

    // MARK: - Attachment to the cast channel

    public func attach(cast: LyraCastRole) {
        self.cast = cast
        cast.onCastFrame = { [weak self] type, payload in
            self?.handleCastFrame(type: type, payload: payload)
        }
    }

    // MARK: - Events (SimpleEventMessage, wire type 18)

    // G.M()/sendKeyBytes: event 23 with our KeyData JSON.
    public func sendMirrorCallKey() {
        let keyData = KeyData(
            keyBytes: Self.spkiEncode(x963: phoneKey.publicKey.x963Representation),
            p2pIp: phoneP2PIp,
            port: phoneSourcePort
        )
        sendSimpleEvent(event: 23, stringValue: Self.keyDataJSON(keyData))
        onEvent("mirrorcall key sent port=\(phoneSourcePort)")
    }

    private func handleCastFrame(type: UInt8, payload: Data) {
        guard type == LyraCastMessageType.simpleEvent,
              let event = try? LyraCastSimpleEvent.decode(payload)
        else { return }
        queue.async { [weak self] in
            self?.handleSimpleEvent(event)
        }
    }

    private func handleSimpleEvent(_ event: LyraCastSimpleEvent) {
        switch event.event {
        case 23:  // MIRROR_CALL_KEY from the Mac
            guard let stringValue = event.stringValue,
                  let keyData = Self.parseKeyData(stringValue)
            else {
                lastError = "bad Mac KeyData: \(event.stringValue ?? "nil")"
                onEvent("mirrorcall \(lastError!)")
                return
            }
            macKeyData = keyData
            guard let x963 = Self.spkiDecode(keyData.keyBytes),
                  let peerPub = try? P256.KeyAgreement.PublicKey(x963Representation: x963),
                  let secret = try? phoneKey.sharedSecretFromKeyAgreement(with: peerPub)
            else {
                lastError = "Mac KeyData ECDH failed (keyBytes=\(keyData.keyBytes.count))"
                onEvent("mirrorcall \(lastError!)")
                return
            }
            sharedSecret = secret.withUnsafeBytes { Data($0) }
            state = .keyExchanged
            onEvent("mirrorcall key exchanged mac=\(keyData.p2pIp):\(keyData.port)")
        case 24:  // MIRROR_CALL_START: pad starts its source; we sink.
            callStartCount += 1
            onEvent("mirrorcall call start")
            startSink()
        case 31:  // MIRROR_CALL_SINK_START: explicit port
            sinkStartPort = event.uint32Value
            onEvent("mirrorcall sink start port=\(event.uint32Value ?? 0)")
            startSink()
        case 25:  // MIRROR_CALL_STOP
            callStopCount += 1
            stopSink()
            onEvent("mirrorcall call stop")
        default:
            break
        }
    }

    private func sendSimpleEvent(event: UInt32, stringValue: String? = nil, uint32Value: UInt32? = nil) {
        var message = LyraCastSimpleEvent()
        message.event = event
        message.stringValue = stringValue
        message.uint32Value = uint32Value
        cast?.sendCastFrame(type: LyraCastMessageType.simpleEvent, payload: message.encode())
    }

    public static func keyDataJSON(_ keyData: KeyData) -> String {
        // Gson byte[] wire format (relay/KeyData.java): keyBytes is a JSON
        // int array. Gson field order: keyBytes, p2pIp, port.
        let bytes = keyData.keyBytes.map { String($0) }.joined(separator: ",")
        return "{\"keyBytes\":[\(bytes)]," +
            "\"p2pIp\":\"\(keyData.p2pIp)\",\"port\":\(keyData.port)}"
    }

    public static func parseKeyData(_ json: String) -> KeyData? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keyArray = object["keyBytes"] as? [NSNumber],
              let p2pIp = object["p2pIp"] as? String
        else { return nil }
        let port = (object["port"] as? NSNumber)?.intValue ?? 0
        return KeyData(keyBytes: Data(keyArray.map { $0.uint8Value }), p2pIp: p2pIp, port: port)
    }

    public var aesKey: Data? { sharedSecret.map { Data($0.prefix(16)) } }
    public var aesIV: Data? { sharedSecret.map { Data($0.dropFirst(16).prefix(16)) } }

    // MARK: - Sink (RTSP client pulling the Mac's audio source)

    public func startSink() {
        guard let macKeyData, sharedSecret != nil else {
            lastError = "startSink before key exchange"
            onEvent("mirrorcall \(lastError!)")
            return
        }
        let port = UInt16(exactly: sinkStartPort.map(Int.init) ?? macKeyData.port) ?? 0
        guard port != 0 else {
            lastError = "startSink with port 0"
            onEvent("mirrorcall \(lastError!)")
            return
        }
        guard state != .sinkStarting, state != .established else { return }
        connectSink(host: macKeyData.p2pIp, port: port)
    }

    // Direct sink dial without the KeyData gate: lets loopback tests point
    // the mock phone's sink at a bare production RTSP server (e.g. the
    // current LyraDistAudioWFDServer) to validate the dialect alone.
    public func startSinkForTesting(host: String, port: UInt16) {
        queue.async { [weak self] in
            self?.connectSink(host: host, port: port)
        }
    }

    private func connectSink(host: String, port: UInt16) {
        state = .sinkStarting
        peerHost = host
        peerRTSPPort = port
        if clientMediaPort == 0 {
            clientMediaPort = UInt16.random(in: 30000...59000) & 0xFFFE
        }
        startMediaListener()
        let connection = NWConnection(
            host: NWEndpoint.Host(peerHost),
            port: NWEndpoint.Port(rawValue: peerRTSPPort)!,
            using: .tcp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case .hostPort(_, let port) = connection.currentPath?.localEndpoint {
                    self?.localTCPPort = port.rawValue
                }
                self?.onEvent("mirrorcall rtsp connected")
            case .failed(let error):
                self?.lastError = "rtsp connect failed: \(error)"
                self?.state = .failed("rtsp")
                self?.onEvent("mirrorcall rtsp failed \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRTSP()
    }

    public func stopSink() {
        connection?.cancel()
        connection = nil
        mediaListener?.cancel()
        mediaListener = nil
        mediaConnection = nil
        if state == .established || state == .sinkStarting {
            state = .keyExchanged
        }
    }

    private func receiveRTSP() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                rtspBuffer.append(data)
                drainRTSP()
            }
            if complete || error != nil { return }
            receiveRTSP()
        }
    }

    private func drainRTSP() {
        while let headerEnd = rtspBuffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
            let headerData = rtspBuffer.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                rtspBuffer.removeAll()
                return
            }
            var lines = headerText.components(separatedBy: "\r\n")
            let firstLine = lines.removeFirst()
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon].lowercased())] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            let messageEnd = headerEnd.upperBound + contentLength
            guard rtspBuffer.count >= messageEnd else { return }
            let body = rtspBuffer.subdata(in: headerEnd.upperBound..<messageEnd)
            rtspBuffer.removeSubrange(0..<messageEnd)
            handleRTSP(firstLine: firstLine, headers: headers, body: body)
        }
    }

    private func sendRTSP(_ text: String) {
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.lastError = "rtsp send failed: \(error)"
            }
        })
    }

    private func handleRTSP(firstLine: String, headers: [String: String], body: Data) {
        let cseq = headers["cseq"].flatMap(Int.init) ?? 0
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        onEvent("mirrorcall rtsp_rx \(firstLine) cseq=\(cseq) body=\(bodyText.prefix(80))")
        if firstLine.hasPrefix("RTSP/") {
            guard firstLine.contains("200") else {
                lastError = "rtsp error: \(firstLine)"
                onEvent("mirrorcall \(lastError!)")
                return
            }
            if session != nil, firstLine.contains("200"), bodyText.isEmpty, headers["session"] == nil {
                // PLAY response (our PLAY carries the Session header; the 200
                // echoes CSeq only) → media may start.
                if state == .sinkStarting {
                    state = .established
                    onEvent("mirrorcall established")
                }
                return
            }
            if let rawSession = headers["session"] {
                session = rawSession.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces)
                setupCompleted = true
                if let transport = headers["transport"] {
                    for component in transport.components(separatedBy: ";") {
                        let pair = component.trimmingCharacters(in: .whitespaces)
                        if pair.hasPrefix("server_port="),
                           let port = UInt16(pair.dropFirst("server_port=".count)) {
                            serverMediaPort = port
                        }
                    }
                }
                ourCSeq += 1
                var playHeaders = ""
                if let session {
                    playHeaders = "Session: \(session)\r\n"
                }
                sendRTSP(
                    "PLAY rtsp://localhost/wfd1.0 RTSP/1.0\r\nCSeq: \(ourCSeq)\r\n" +
                        "User-Agent: stagefright/1.1 (Linux;Android 4.1)\r\n" + playHeaders + "\r\n"
                )
            }
            return
        }
        let method = firstLine.split(separator: " ").first.map(String.init) ?? ""
        switch method {
        case "OPTIONS":
            // M1 from the Mac source: answer with the session-composite ack,
            // then send our own OPTIONS (M2) like the phone sink does.
            let authMsg = headers["authmsg"] ?? ""
            let key = Self.miplaySessionKey(
                serverIP: peerHost, serverPort: peerRTSPPort,
                clientIP: "127.0.0.1", clientPort: localTCPPort
            )
            sendRTSP(
                "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n" +
                    "Public: org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER\r\n" +
                    "authKeyType: 1\r\nauthAlgorithmVal: 4\r\n" +
                    "authMsgAck:\(Self.sessionAuthMsgAck(for: authMsg, key: key))\r\n" +
                    "fastRTSPVersion: 0\r\n\r\n"
            )
            ourCSeq += 1
            sendRTSP(
                "OPTIONS * RTSP/1.0\r\nCSeq: \(ourCSeq)\r\n" +
                    "User-Agent: stagefright/1.1 (Linux;Android 4.1)\r\n" +
                    "Require: org.wfa.wfd1.0\r\n" +
                    "lib_version: miplaycast_os3_release1.6 3.1.5120912\r\n" +
                    "authMsg:\(ourAuthMsg)\r\nauthKeyType: 1\r\nauthAlgorithmTypes: 7\r\n" +
                    "fastRTSPVersion: 0\r\n\r\n"
            )
        case "GET_PARAMETER":
            sendRTSP(
                "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Type: text/parameters\r\n" +
                    "Content-Length: \(capabilityBody().utf8.count)\r\n\r\n" + capabilityBody()
            )
        case "SET_PARAMETER":
            if bodyText.contains("wfd_audio") {
                m4Body = bodyText
                m4SelectsAAC = bodyText.contains("AAC")
                m4SelectsLPCM8k = bodyText.contains("wfd_audio_codecs_v2: 0 3")
                onEvent("mirrorcall m4 \(bodyText.replacingOccurrences(of: "\r\n", with: "|"))")
            }
            sendRTSP("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n\r\n")
            if bodyText.contains("wfd_trigger_method: SETUP") {
                ourCSeq += 1
                sendRTSP(
                    "SETUP rtsp://localhost/wfd1.0 RTSP/1.0\r\nCSeq: \(ourCSeq)\r\n" +
                        "User-Agent: stagefright/1.1 (Linux;Android 4.1)\r\n" +
                        "Transport: RTP/AVP/MPT;unicast;client_port=\(clientMediaPort);userid=\(UInt32.random(in: 10000...60000))\r\n\r\n"
                )
            }
        default:
            sendRTSP("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n\r\n")
        }
    }

    // The PHONERELAY sink's M3 answer: LPCM v2 bitmask 8 (bit3 = mode 3 =
    // 8 kHz mono per AudioFormats::mTable) + the AAC offer line the official
    // source templates carry (libmirror-jni .rodata 0x2d5c07).
    private func capabilityBody() -> String {
        [
            "wfd_content_SP_protection: 4 1 256 3 1 1 1 1",
            "wfd_video_formats: none",
            "wfd_audio_codecs_v2: 8 0 0 0",
            "wfd_audio_codecs: AAC 00000001 00",
            "wfd_client_rtp_ports: RTP/AVP/MPT;unicast \(clientMediaPort) 0 mode=play",
            "wfd_tcp_enable: 0",
            "wfd_standby_resume_capability: supported",
            "",
        ].joined(separator: "\r\n")
    }

    // MARK: - Media plane (RTP/TS/PES AAC validation)

    private func startMediaListener() {
        guard mediaListener == nil else { return }
        do {
            let listener = try NWListener(
                using: .udp, on: NWEndpoint.Port(rawValue: clientMediaPort)!
            )
            mediaListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                // A late datagram can arrive after teardown released the
                // role (the listener's cancel is async).
                guard let self else {
                    connection.cancel()
                    return
                }
                connection.start(queue: self.queue)
                self.mediaConnection = connection
                self.receiveMedia(connection)
            }
            listener.start(queue: queue)
        } catch {
            lastError = "media listen failed: \(error)"
        }
    }

    private func receiveMedia(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                ingestRTP(data)
            }
            if error == nil {
                receiveMedia(connection)
            }
        }
    }

    private func ingestRTP(_ datagram: Data) {
        guard datagram.count > 12, (datagram[0] >> 6) == 2 else { return }
        let csrcCount = Int(datagram[0] & 0x0F)
        var offset = 12 + csrcCount * 4
        if datagram.count <= offset { return }
        if (datagram[0] & 0x10) != 0 {  // extension header
            guard datagram.count > offset + 4 else { return }
            let extLen = (Int(datagram[offset + 2]) << 8) | Int(datagram[offset + 3])
            offset += 4 + extLen * 4
        }
        guard datagram.count > offset else { return }
        var stream = datagram.subdata(in: offset..<datagram.count)
        while stream.count >= 188 {
            ingestTS(stream.subdata(in: 0..<188))
            stream = stream.subdata(in: 188..<stream.count)
        }
    }

    private func ingestTS(_ packet: Data) {
        guard packet.count == 188, packet[0] == 0x47 else { return }
        let pusi = (packet[1] & 0x40) != 0
        let pid = (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])
        let afc = (packet[3] >> 4) & 0x03
        var payloadStart = 4
        if afc == 0x02 { return }
        if afc == 0x03 {
            payloadStart = 5 + Int(packet[4])
        }
        guard payloadStart < 188 else { return }
        let payload = packet.subdata(in: payloadStart..<188)
        if pid == 0 {  // PAT → PMT pid
            guard payload.count > 12 else { return }
            let section = payload.subdata(in: Int(payload[0]) + 1..<payload.count)
            guard section.count > 12 else { return }
            pmtPID = ((UInt16(section[10]) & 0x1F) << 8) | UInt16(section[11])
            return
        }
        if let pmtPID, pid == pmtPID {  // PMT → first audio ES pid
            guard payload.count > 16 else { return }
            let section = payload.subdata(in: Int(payload[0]) + 1..<payload.count)
            guard section.count > 12 else { return }
            let programInfoLength = (Int(section[10]) & 0x0F) << 8 | Int(section[11])
            var cursor = 12 + programInfoLength
            while cursor + 5 <= section.count - 4 {
                let streamType = section[cursor]
                let esPID = ((UInt16(section[cursor + 1]) & 0x1F) << 8) | UInt16(section[cursor + 2])
                let esInfoLength = (Int(section[cursor + 3]) & 0x0F) << 8 | Int(section[cursor + 4])
                if streamType == 0x0F || streamType == 0x1B || streamType == 0x83 {
                    self.esPID = esPID
                }
                cursor += 5 + esInfoLength
            }
            return
        }
        if let esPID, pid != esPID { return }
        if pusi, payload.count >= 4,
           payload[0] == 0x00, payload[1] == 0x00, payload[2] == 0x01
        {
            flushPES()
            pesBuffer = payload
            pesExpectedLength = payload.count >= 6
                ? 6 + (Int(payload[4]) << 8 | Int(payload[5])) : nil
            if let expected = pesExpectedLength, pesBuffer.count >= expected {
                flushPES()
            }
            return
        }
        if !pesBuffer.isEmpty {
            pesBuffer.append(payload)
            if let expected = pesExpectedLength, pesBuffer.count >= expected {
                flushPES()
            }
        }
    }

    private func flushPES() {
        let pes = pesBuffer
        pesBuffer = Data()
        pesExpectedLength = nil
        guard pes.count > 9 else { return }
        guard let key = aesKey, let iv = MiplayPESCrypto.extractPrivateDataIV(fromPES: pes)
        else { return }
        pesIVsSeen += 1
        let headerLength = 9 + Int(pes[8])
        guard pes.count > headerLength else { return }
        var payload = Data(pes[headerLength...])
        // AESPART: first min(256, len) & ~15 bytes are CBC-encrypted.
        let encryptedLength = min(256, payload.count) & ~15
        if encryptedLength >= 16 {
            let decrypted = MiplayPESCrypto.decrypt(Data(payload.prefix(encryptedLength)), iv: iv, key: key)
            payload.replaceSubrange(0..<encryptedLength, with: decrypted)
        }
        guard payload.count >= 18, payload[0] == 0xFF, payload[1] == 0x02 else {
            lastError = "PES payload not ff02 PCM after decrypt: " +
                payload.prefix(8).map { String(format: "%02x", $0) }.joined()
            onEvent("mirrorcall \(lastError!)")
            return
        }
        aacFrames += 1
        decryptedAACBytes += payload.count
        if aacFrames <= 3 || aacFrames % 50 == 0 {
            onEvent("mirrorcall pcm frame=\(aacFrames) bytes=\(payload.count)")
        }
    }

    // MARK: - miplaycast session auth (mirror of the App-side
    // LyraDistAudioWFD scheme, duplicated: LyraServerKit cannot import App)

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

    static func sessionAuthMsgAck(for authMsg: String, key: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(authMsg.utf8), using: SymmetricKey(data: key))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func randomAuthMsg() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
