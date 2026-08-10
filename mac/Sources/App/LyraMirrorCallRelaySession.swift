import AVFoundation
import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// Mac (pad) side of the Mirror.apk MirrorCallService call-relay audio
// protocol — the fully-native DistAudio call uplink. Research basis:
// docs/distaudio-uplink-no-hook-notes.md + captures/xiaomi-mirror-device
// (i2/C0885B CallRelayAudioManager, com.xiaomi.mirror.relay.G) +
// libCastService-jni TSPacketizer::packetize @0x19c69c disasm.
//
// The phone's MirrorCallService is the ONLY writer of IMirrorOption 0x100707
// (Business_IsPhoneRelay): when we answer its event-23 KeyData and signal a
// call (event 24 + event 31), it startSinks against our advertised endpoint
// with mIsPhoneRelay=1, and the phone's own runtime delivers our uplink
// audio into the call (the official terminal hop).
//
// Wire contract (all verified against jadx + live logs 2026-08-09):
//   - event 23 MIRROR_CALL_KEY: KeyData JSON {"keyBytes": [int array of the
//     X509 SPKI P-256 pubkey — Gson byte[] format], "p2pIp": ip, "port": n};
//     both sides ECDH secp256r1 → 32-byte secret → AES key secret[0..16),
//     IV secret[16..32).
//   - event 24 MIRROR_CALL_START / event 31 MIRROR_CALL_SINK_START (vUint32
//     = source port) from us → phone sinks our audio source.
//   - event 25 MIRROR_CALL_STOP on call end.
//   - Media: miplaycast RTSP (same dialect as LyraDistAudioWFDServer),
//     LPCM mode 3 (8 kHz mono — AudioFormats::mTable entry 3) as ff02-framed
//     PCM in the 0x83 private TS stream, per-PES IV in PES_private_data,
//     payload prefix min(256, len) & ~15 bytes AES-128-CBC (AESPART,
//     Encrypt_Type 4).
final class LyraMirrorCallRelaySession {
    // The cast trust session assigns this when it owns a relay session; the
    // relayCall URI handler drives call state through it (same pattern as
    // LyraRelayCallDialer.activeDialer).
    private(set) static var activeSession: LyraMirrorCallRelaySession?

    // X.509 SPKI DER prefix for secp256r1 (26 bytes) + 65-byte X9.63 point.
    static let p256SPKIPrefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
        0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
        0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ])

    private let send: (UInt8, Data) -> Void
    private let queue = DispatchQueue(label: "edgelink.lyra.mirrorcall")
    private let localKey = P256.KeyAgreement.PrivateKey()
    private var sharedSecret: Data?
    private var phoneKeyData: (ip: String, port: Int)?
    private(set) var audioSource: LyraMirrorCallAudioSource?
    private var callActive = false
    private var sinkStartSent = false

    init(send: @escaping (UInt8, Data) -> Void) {
        self.send = send
    }

    // Channel-ready entry: bring up the audio source listener and send our
    // KeyData proactively, like the official pad (both sides send event 23
    // on channel setup; the phone does NOT re-send when its MirrorCallService
    // kept stale session state across a Mac reconnect — live 2026-08-10).
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.startAudioSourceLocked()
            self.replyKeyDataLocked()
            Self.activeSession = self
            DiagnosticsLog.info(
                "xiaomi.mirrorcall.keydata_tx sourcePort=\(self.audioSource?.port ?? 0)"
            )
        }
    }

    func teardown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.audioSource?.stop()
            self.audioSource = nil
            self.sharedSecret = nil
            self.callActive = false
            self.sinkStartSent = false
            if Self.activeSession === self {
                Self.activeSession = nil
            }
        }
    }

    // Feed from the cast channel (type-18 frames).
    func handleSimpleEvent(_ event: LyraCastSimpleEvent) {
        queue.async { [weak self] in
            self?.handleSimpleEventOnQueue(event)
        }
    }

    private func handleSimpleEventOnQueue(_ event: LyraCastSimpleEvent) {
        switch event.event {
        case 23:  // MIRROR_CALL_KEY: phone's ECDH KeyData
            guard let json = event.stringValue,
                  let keyData = Self.parseKeyData(json),
                  let x963 = Self.spkiDecode(keyData.keyBytes),
                  let peerPub = try? P256.KeyAgreement.PublicKey(x963Representation: x963),
                  let secret = try? localKey.sharedSecretFromKeyAgreement(with: peerPub)
            else {
                DiagnosticsLog.warn("xiaomi.mirrorcall.keydata_bad \(event.stringValue?.prefix(80) ?? "nil")")
                return
            }
            sharedSecret = secret.withUnsafeBytes { Data($0) }
            phoneKeyData = (keyData.p2pIp, keyData.port)
            Self.activeSession = self
            startAudioSourceLocked()
            if let secret = sharedSecret {
                audioSource?.arm(
                    mediaKey: Data(secret.prefix(16)),
                    mediaIV: Data(secret.dropFirst(16).prefix(16))
                )
            }
            replyKeyDataLocked()
            DiagnosticsLog.info(
                "xiaomi.mirrorcall.key_exchanged phone=\(keyData.p2pIp):\(keyData.port) " +
                    "sourcePort=\(audioSource?.port ?? 0)"
            )
            // The call may have gone active before the phone's KeyData
            // arrived; start the sink now that the keys are in.
            if callActive {
                sendCallStartIfReadyLocked()
            }
        case 25:  // MIRROR_CALL_STOP from the phone
            DiagnosticsLog.info("xiaomi.mirrorcall.phone_stop")
            audioSource?.stopMedia()
        default:
            break
        }
    }

    private func sendCallStartIfReadyLocked() {
        guard !sinkStartSent else { return }
        guard sharedSecret != nil, let port = audioSource?.port, port != 0 else {
            DiagnosticsLog.warn("xiaomi.mirrorcall.call_active_without_keys")
            return
        }
        sinkStartSent = true
        // 24 = mirrorCallStart (the phone starts its source +, for
        // peers without port negotiation, its sink); 31 = explicit
        // sink start at our source port (G.W).
        sendSimpleEventLocked(event: 24)
        sendSimpleEventLocked(event: 31, uint32Value: UInt32(port))
        DiagnosticsLog.info("xiaomi.mirrorcall.call_active sourcePort=\(port)")
    }

    // Call state from the relayCall URI flow (callState 4 = ACTIVE).
    func setCallActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard active != self.callActive else { return }
            self.callActive = active
            if active {
                // Key exchange may still be in flight (the Mac answers the
                // phone's event 23 asynchronously); the event-23 handler
                // re-runs sendCallStartIfReadyLocked when the keys land.
                self.sendCallStartIfReadyLocked()
            } else {
                self.sinkStartSent = false
                self.sendSimpleEventLocked(event: 25)
                self.audioSource?.stopMedia()
                DiagnosticsLog.info("xiaomi.mirrorcall.call_inactive")
            }
        }
    }

    private func startAudioSourceLocked() {
        guard audioSource == nil else { return }
        let source = LyraMirrorCallAudioSource()
        do {
            try source.start()
            audioSource = source
        } catch {
            DiagnosticsLog.error("xiaomi.mirrorcall.source_listen_failed", error)
        }
    }

    private func replyKeyDataLocked() {
        guard let port = audioSource?.port, port != 0 else { return }
        let spki = Self.p256SPKIPrefix + localKey.publicKey.x963Representation
        // Gson byte[] wire format (Mirror.apk relay/KeyData.java): a JSON
        // array of ints — base64 crashes the phone's Gson parser (live FC
        // 2026-08-10: "Expected BEGIN_ARRAY but was STRING at $.keyBytes").
        sendSimpleEventLocked(event: 23, stringValue: Self.keyDataJSON(spki: spki, port: port))
    }

    static func keyDataJSON(spki: Data, port: UInt16) -> String {
        // Gson field order (KeyData.java): keyBytes, p2pIp, port.
        let bytes = spki.map { String($0) }.joined(separator: ",")
        return "{\"keyBytes\":[\(bytes)]," +
            "\"p2pIp\":\"\(Self.primaryIPv4Address() ?? "")\",\"port\":\(port)}"
    }

    private func sendSimpleEventLocked(event: UInt32, stringValue: String? = nil, uint32Value: UInt32? = nil) {
        var message = LyraCastSimpleEvent()
        message.event = event
        message.stringValue = stringValue
        message.uint32Value = uint32Value
        send(LyraCastMessageType.simpleEvent, message.encode())
    }

    static func parseKeyData(_ json: String) -> (keyBytes: Data, p2pIp: String, port: Int)? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keyArray = object["keyBytes"] as? [NSNumber],
              let p2pIp = object["p2pIp"] as? String
        else { return nil }
        return (Data(keyArray.map { $0.uint8Value }), p2pIp, (object["port"] as? NSNumber)?.intValue ?? 0)
    }

    static func spkiDecode(_ der: Data) -> Data? {
        guard der.count == p256SPKIPrefix.count + 65, der.starts(with: p256SPKIPrefix) else {
            return nil
        }
        return der.suffix(65)
    }

    // Same en0 lookup as the distaudio RPC session's uplink advertise.
    private static func primaryIPv4Address() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let interface = current {
            let flags = Int32(interface.pointee.ifa_flags)
            let name = String(cString: interface.pointee.ifa_name)
            if name == "en0", flags & IFF_UP != 0, interface.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    interface.pointee.ifa_addr,
                    socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
                )
                address = String(cString: host)
                break
            }
            current = interface.pointee.ifa_next
        }
        return address
    }
}

// MiPlayCast audio source for the PHONERELAY sink: RTSP server (the
// LyraDistAudioWFDServer dialect) + ff02 PCM MPEG-TS media plane with
// AESPART CBC encryption. Mic capture at 8 kHz mono; tests inject PCM via
// write(pcm:) directly.
final class LyraMirrorCallAudioSource {
    // nil until the phone's event-23 KeyData completes the ECDH exchange
    // (arm()); media frames are dropped while unarmed.
    private var mediaKey: Data?
    private var mediaIV: Data?
    private(set) var armed = false
    private let queue = DispatchQueue(label: "edgelink.lyra.mirrorcall.source")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = LyraDistAudioWFD.MessageParser()
    private var ourCSeq = 0
    private var ourAuthMsg = LyraDistAudioWFD.randomAuthMsg()
    private var clientMediaPort: UInt16 = 0
    private var peerHost: String?
    private var peerPort: UInt16 = 0
    private var stage = Stage.awaitM1Response
    private var pendingServerPort: UInt16 = 0
    private var mediaConnection: NWConnection?
    private var rtcpConnection: NWConnection?
    private var rtcpTimer: DispatchSourceTimer?
    private var engine: AVAudioEngine?
    private var inputConverter: AVAudioConverter?
    private var pcmCarry = Data()
    private static let pcmFrameBytes = 320
    private var sequence: UInt16 = 0
    private var pts90k: UInt32 = 0
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var tsContinuity: UInt8 = 0
    private var psiContinuity: UInt8 = 0
    private var auIndex: UInt64 = 0
    private var mediaRunning = false

    private enum Stage {
        case awaitM1Response
        case awaitM3Response
        case awaitSetupRequest
        case streaming
    }

    init() {}

    func arm(mediaKey: Data, mediaIV: Data) {
        queue.async { [weak self] in
            self?.mediaKey = mediaKey
            self?.mediaIV = mediaIV
            self?.armed = true
        }
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
        while (listener.port?.rawValue ?? 0) == 0, waited < 100 {
            Thread.sleep(forTimeInterval: 0.01)
            waited += 1
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.connection?.cancel()
            self?.connection = nil
            self?.stopMediaLocked()
        }
    }

    func stopMedia() {
        queue.async { [weak self] in
            self?.stopMediaLocked()
        }
    }

    private func stopMediaLocked() {
        mediaRunning = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        inputConverter = nil
        rtcpTimer?.cancel()
        rtcpTimer = nil
        rtcpConnection?.cancel()
        rtcpConnection = nil
        mediaConnection?.cancel()
        mediaConnection = nil
    }

    // 8 kHz mono s16le PCM — from the mic tap in production, from tests
    // directly. One media frame per 20 ms (160 samples, 320 bytes).
    func write(pcm: Data) {
        queue.async { [weak self] in
            guard let self, self.mediaRunning else { return }
            self.pcmCarry.append(pcm)
            while self.pcmCarry.count >= Self.pcmFrameBytes {
                let chunk = self.pcmCarry.prefix(Self.pcmFrameBytes)
                self.pcmCarry.removeFirst(Self.pcmFrameBytes)
                self.sendAudioFrame(Data(chunk))
            }
        }
    }

    // MARK: - RTSP server (miplaycast dialect, LPCM 8k selection)

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        parser = LyraDistAudioWFD.MessageParser()
        stage = .awaitM1Response
        peerHost = connection.endpoint.debugDescription.components(separatedBy: ":").first
        peerPort = UInt16(connection.endpoint.debugDescription.components(separatedBy: ":").last ?? "") ?? 0
        DiagnosticsLog.info("xiaomi.mirrorcall.sink_conn from=\(connection.endpoint.debugDescription)")
        connection.start(queue: queue)
        receive(connection)
        ourCSeq += 1
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
            label: "options_m1"
        )
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for message in self.parser.append(data) {
                    self.handleMessage(message.firstLine, message.headers, message.body)
                }
            }
            if complete || error != nil { return }
            self.receive(connection)
        }
    }

    private func send(_ data: Data, label: String) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.error("xiaomi.mirrorcall.tx_failed \(label)", error)
            }
        })
    }

    private func handleMessage(_ firstLine: String, _ headers: [String: String], _ body: Data) {
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        if firstLine.hasPrefix("RTSP/") {
            let cseq = headers["cseq"].flatMap(Int.init) ?? -1
            guard firstLine.contains("200") else {
                DiagnosticsLog.warn("xiaomi.mirrorcall.rtsp_error \(firstLine)")
                return
            }
            switch stage {
            case .awaitM1Response:
                stage = .awaitM3Response
                ourCSeq += 1
                let query = [
                    "wfd_content_SP_protection",
                    "wfd_audio_codecs",
                    "wfd_client_rtp_ports",
                    "",
                ].joined(separator: "\r\n")
                send(
                    LyraDistAudioWFD.serializeRequest(
                        method: "GET_PARAMETER", target: "rtsp://localhost/wfd1.0", cseq: ourCSeq,
                        headers: [], body: query
                    ),
                    label: "getparam_m3"
                )
            case .awaitM3Response:
                stage = .awaitSetupRequest
                ourCSeq += 1
                // LPCM mode 3 = 8 kHz mono (AudioFormats::mTable in
                // libCastService-jni: entry 3 = {16, 0x1f40, 1}); the sink
                // forces Encrypt_Type 4 (AESPART) locally.
                let m4 = [
                    "wfd_audio_codecs_v2: 0 3",
                    "wfd_type_encryp: 4 1 1 1 1",
                    "",
                ].joined(separator: "\r\n")
                send(
                    LyraDistAudioWFD.serializeRequest(
                        method: "SET_PARAMETER", target: "rtsp://localhost/wfd1.0", cseq: ourCSeq,
                        headers: [], body: m4
                    ),
                    label: "setparam_m4"
                )
                ourCSeq += 1
                send(
                    LyraDistAudioWFD.serializeRequest(
                        method: "SET_PARAMETER", target: "rtsp://localhost/wfd1.0", cseq: ourCSeq,
                        headers: [], body: "wfd_trigger_method: SETUP\r\n"
                    ),
                    label: "trigger_setup"
                )
            default:
                DiagnosticsLog.info("xiaomi.mirrorcall.response cseq=\(cseq) stage=\(stage)")
            }
            return
        }
        let method = firstLine.split(separator: " ").first.map(String.init) ?? ""
        let cseq = headers["cseq"].flatMap(Int.init) ?? 0
        switch method {
        case "OPTIONS":
            let authMsg = headers["authmsg"] ?? ""
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
                label: "options_response"
            )
        case "GET_PARAMETER", "SET_PARAMETER":
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), label: "param_response")
        case "SETUP":
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
            let serverMediaPort = UInt16.random(in: 15000...30000) & 0xFFFE
            let sessionId = UInt32.random(in: 100000...999999999)
            pendingServerPort = serverMediaPort
            send(
                LyraDistAudioWFD.serializeResponse(
                    cseq: cseq,
                    headers: [
                        "Session: \(sessionId);timeout=60",
                        "Transport: RTP/AVP/MPT;unicast;client_port=\(clientMediaPort);server_port=\(serverMediaPort)",
                    ],
                    body: ""
                ),
                label: "setup_response"
            )
        case "PLAY":
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), label: "play_response")
            stage = .streaming
            startMediaLocked()
        case "TEARDOWN":
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), label: "teardown_response")
            stopMediaLocked()
        default:
            send(LyraDistAudioWFD.serializeResponse(cseq: cseq, headers: [], body: ""), label: "generic_response")
        }
    }

    private func localListenIP() -> String {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(8236).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(peerHost ?? "127.0.0.1"))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return "" }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &local, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }) == 0 else { return "" }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addrCopy = local.sin_addr
        guard inet_ntop(AF_INET, &addrCopy, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buf)
    }

    // MARK: - Media plane

    private func startMediaLocked() {
        guard !mediaRunning, let peerHost, clientMediaPort > 0 else { return }
        mediaRunning = true
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("0.0.0.0"), port: NWEndpoint.Port(rawValue: pendingServerPort)!
        )
        let media = NWConnection(
            host: NWEndpoint.Host(peerHost), port: NWEndpoint.Port(rawValue: clientMediaPort)!,
            using: parameters
        )
        mediaConnection = media
        media.start(queue: queue)
        startRTCPLocked()
        startCaptureLocked()
        DiagnosticsLog.info(
            "xiaomi.mirrorcall.media_start host=\(peerHost) port=\(clientMediaPort)"
        )
    }

    // Same MediaClock anchor as the distaudio uplink: one RTCP SR per second
    // from server_port+1 to client_port+1.
    private func startRTCPLocked() {
        let rtcpParameters = NWParameters.udp
        rtcpParameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("0.0.0.0"), port: NWEndpoint.Port(rawValue: pendingServerPort &+ 1)!
        )
        let rtcp = NWConnection(
            host: NWEndpoint.Host(peerHost ?? "127.0.0.1"),
            port: NWEndpoint.Port(rawValue: clientMediaPort &+ 1)!,
            using: rtcpParameters
        )
        rtcpConnection = rtcp
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
        for value in [seconds, fraction, pts90k, 0, 0] as [UInt32] {
            packet.append(UInt8((value >> 24) & 0xff))
            packet.append(UInt8((value >> 16) & 0xff))
            packet.append(UInt8((value >> 8) & 0xff))
            packet.append(UInt8(value & 0xff))
        }
        rtcpConnection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func startCaptureLocked() {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true
        )!
        inputConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 640, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.inputConverter else { return }
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * (8000.0 / buffer.format.sampleRate)
            ) + 64
            guard frameCount > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
            else { return }
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
            else { return }
            self.write(pcm: Data(bytes: channelData, count: Int(out.frameLength) * 2))
        }
        do {
            try engine.start()
            DiagnosticsLog.info("xiaomi.mirrorcall.capture_running")
        } catch {
            DiagnosticsLog.error("xiaomi.mirrorcall.capture_failed", error)
        }
    }

    // One 20 ms PCM frame → ff02 wrap (the SDK's private-audio framing, as
    // on the distaudio stream) → AESPART encrypt → PES (private_data IV) →
    // TS grid → one RTP packet.
    private func sendAudioFrame(_ pcm: Data) {
        var au = Self.makeFF02Frame(pcm: pcm)
        // AESPART: first min(256, len) & ~15 bytes CBC-encrypted.
        guard let mediaKey, let mediaIV, armed else { return }
        let encryptedLength = min(256, au.count) & ~15
        if encryptedLength >= 16 {
            let encrypted = MiplayPESCrypto.encrypt(Data(au.prefix(encryptedLength)), iv: mediaIV, key: mediaKey)
            au.replaceSubrange(0..<encryptedLength, with: encrypted)
        }
        let pes = makePES(payload: au, pts: pts90k, iv: mediaIV)
        var rtpPayload = Data()
        if auIndex % 8 == 0 {
            rtpPayload.append(Self.makePSIPacket(section: Self.patSection, continuity: &psiContinuity, pid: 0))
            rtpPayload.append(Self.makePSIPacket(section: Self.pmtSection, continuity: &psiContinuity, pid: 0x100))
        }
        for packet in packetizeTS(pes) {
            rtpPayload.append(packet)
        }
        var packet = Data(capacity: 12 + rtpPayload.count)
        packet.append(0x80)
        packet.append(0x60 | 33)
        packet.append(UInt8(sequence >> 8))
        packet.append(UInt8(sequence & 0xff))
        for value in [pts90k, ssrc] {
            packet.append(UInt8((value >> 24) & 0xff))
            packet.append(UInt8((value >> 16) & 0xff))
            packet.append(UInt8((value >> 8) & 0xff))
            packet.append(UInt8(value & 0xff))
        }
        packet.append(rtpPayload)
        sequence &+= 1
        auIndex &+= 1
        pts90k &+= 1800  // 20 ms on the 90 kHz clock
        if auIndex <= 3 || auIndex % 50 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirrorcall.au_send n=\(auIndex) pcmBytes=\(pcm.count) rtpBytes=\(packet.count)"
            )
        }
        mediaConnection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                DiagnosticsLog.error("xiaomi.mirrorcall.rtp_send_failed", error)
                _ = self
            }
        })
    }

    // PES with PTS + PES_private_data carrying the CBC IV (the layout
    // MiplayPESCrypto.extractPrivateDataIV reads back sink-side).
    private func makePES(payload: Data, pts: UInt32, iv: Data) -> Data {
        var pes = Data([0x00, 0x00, 0x01, 0xBD])
        let headerDataLength = 5 + 1 + 16
        let packetLength = UInt16(truncatingIfNeeded: 3 + headerDataLength + payload.count)
        pes.append(UInt8(packetLength >> 8))
        pes.append(UInt8(packetLength & 0xff))
        pes.append(contentsOf: [0x84, 0x81, UInt8(headerDataLength)])
        pes.append(Self.encodePTS(pts))
        pes.append(0x80)  // private_data extension flag
        pes.append(iv)
        pes.append(payload)
        return pes
    }

    private static func encodePTS(_ pts: UInt32) -> Data {
        Data([
            UInt8(0x21 | ((pts >> 29) & 0x0e)),
            UInt8((pts >> 22) & 0xff),
            UInt8(((pts >> 14) & 0xfe) | 0x01),
            UInt8((pts >> 7) & 0xff),
            UInt8(((pts << 1) & 0xfe) | 0x01),
        ])
    }

    // ff02 private-audio frame as observed on the phone's own streams:
    // magic, u32BE 16, two zero bytes, payload length u32 LE at 8, six zero
    // bytes, then the PCM.
    static func makeFF02Frame(pcm: Data) -> Data {
        var frame = Data([0xff, 0x02, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00])
        frame.append(UInt8(pcm.count & 0xff))
        frame.append(UInt8((pcm.count >> 8) & 0xff))
        frame.append(UInt8((pcm.count >> 16) & 0xff))
        frame.append(UInt8((pcm.count >> 24) & 0xff))
        frame.append(contentsOf: [UInt8](repeating: 0, count: 6))
        frame.append(pcm)
        return frame
    }

    private func packetizeTS(_ pes: Data) -> [Data] {
        var packets: [Data] = []
        var offset = 0
        var first = true
        while offset < pes.count {
            let remaining = pes.count - offset
            var packet = Data(count: 188)
            packet[0] = 0x47
            packet[1] = (first ? 0x50 : 0x10) | UInt8((Self.esPID >> 8) & 0x1f)
            packet[2] = UInt8(Self.esPID & 0xff)
            if remaining >= 184 {
                packet[3] = 0x10 | (tsContinuity & 0x0f)
                packet.replaceSubrange(4..<188, with: pes[offset..<offset + 184])
                offset += 184
            } else {
                let stuffing = 183 - remaining
                packet[3] = 0x30 | (tsContinuity & 0x0f)
                packet[4] = UInt8(stuffing)
                if stuffing > 0 {
                    packet[5] = 0x00
                    for i in 6..<(5 + stuffing) { packet[i] = 0xff }
                }
                packet.replaceSubrange(4 + 1 + stuffing..<188, with: pes[offset..<pes.count])
                offset = pes.count
            }
            tsContinuity &+= 1
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
        packet[4] = 0x00
        packet.replaceSubrange(5..<5 + section.count, with: section)
        for i in (5 + section.count)..<188 { packet[i] = 0xff }
        continuity &+= 1
        return packet
    }

    private static let esPID: UInt16 = 0x1100

    private static let patSection = Data([
        0x00, 0xb0, 0x0d, 0x00, 0x00, 0xc3, 0x00, 0x00,
        0x00, 0x01, 0xe1, 0x00, 0x2d, 0xf6, 0x52, 0x95,
    ])

    // PMT copied from the distaudio stream shape (the SDK's ATSParser keys
    // on the 83 02 46 2f "F/" descriptor): stream_type 0x83 private stream
    // at 0x1100, PCR 0x1000.
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
