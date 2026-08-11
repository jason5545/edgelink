import CryptoKit
import EdgeLinkKit
import Foundation
import Network

// Official PC-client WFD control channel: after the cast channel delivers
// ScreenActionMessage{OPEN_MIRROR_SCREEN}, the phone starts an RTSP server on
// TCP 7236 (+displayId). We dial it and replay the exact dialog the official
// Mac client speaks (reconstructed from om1 logcat, memory key
// edgelink-wfd-rtsp-dialog-reconstructed-2026-08-01). On SETUP success the
// phone dials UDP video to the client_port we advertise.
final class XiaomiMirrorWFDClient {
    enum Stage: String {
        case idle
        case connecting
        case negotiating
        case awaitSetupResponse
        case awaitPlayResponse
        case established
        case closed
    }

    var onSessionEstablished: ((UInt16) -> Void)?
    var onTeardown: (() -> Void)?
    var onClosed: ((String) -> Void)?

    // Official sink behavior (verified across five live captures on
    // 2026-07-31, memory key edgelink-wfd-idr-request-play-plus-20s): exactly
    // 20.0s after PLAY the client sends a one-shot SET_PARAMETER with body
    // "wfd_idr_request". The phone's low-latency HEVC encoder only emits
    // VPS/SPS/PPS with an IDR, so a sink that joined mid-GOP (e.g. the phone
    // kept a stale encoder running after we quit without TEARDOWN) never
    // decodes a frame without this.
    var idrRequestDelay: TimeInterval = 20

    // Official sink behavior: the client also initiates GET_PARAMETER
    // keepalives (the phone's SETUP reply advertises Session;timeout=60 and
    // tears the whole WFD source down — media stops, RTSP listener dies —
    // when the sink stays silent past it; live 2026-08-11: session froze
    // ~100s after PLAY+20s IDR, the last sink-initiated message). 25s keeps
    // two full intervals of margin under the 60s timeout.
    var keepaliveInterval: TimeInterval = 25

    private let queue = DispatchQueue(label: "EdgeLink.XiaomiMirrorWFDClient")
    private var connection: NWConnection?
    private var stage: Stage = .idle
    private var buffer = Data()
    private var ourCSeq = 0
    private var session: String?
    private var serverRTPPort: UInt16?
    private var clientRTPPort: UInt16 = 15_550
    private var userID: UInt32 = 0
    private var ourAuthMsg = ""
    private var firstRenderSent = false
    private var idrRequestWork: DispatchWorkItem?
    private var keepaliveTimer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var lastProgress = Date()
    private var startArgs: (host: String, rtspPort: UInt16, clientRTPPort: UInt16)?
    private var connectRetryCount = 0
    private static let maxConnectRetries = 40
    // ECONNREFUSED means the phone's RTSP listener is gone, not merely not
    // yet up (the post-OPEN listener appears within ~1s). Burn-through of
    // the full retry budget against a dead server (live, 2026-08-03: 38
    // refused retries after the phone tore its server down) only delays the
    // failure UI, so persistent refusals fail fast.
    private var consecutiveRefusals = 0
    private static let maxConsecutiveRefusals = 8

    private static let userAgent = "stagefright/1.1 (Linux;Android 4.1)"
    private static let libVersion = "miplaycast_os3_release1.7 3.2.6011403"
    private static let presentationURL = "rtsp://localhost/wfd1.0"

    deinit {
        watchdog?.cancel()
        idrRequestWork?.cancel()
        connection?.cancel()
    }

    func start(host: String, rtspPort: UInt16 = 7236, clientRTPPort: UInt16 = 15_550) {
        queue.async {
            guard self.stage == .idle || self.stage == .closed else {
                return
            }
            self.startArgs = (host, rtspPort, clientRTPPort)
            self.connectRetryCount = 0
            self.consecutiveRefusals = 0
            self.beginConnection(host: host, rtspPort: rtspPort, clientRTPPort: clientRTPPort)
        }
    }

    private func beginConnection(host: String, rtspPort: UInt16, clientRTPPort: UInt16) {
        self.clientRTPPort = clientRTPPort
        self.userID = .random(in: 1...UInt32.max)
        self.ourAuthMsg = Self.randomAuthMsg()
        self.ourCSeq = 0
        self.session = nil
        self.serverRTPPort = nil
        self.firstRenderSent = false
        self.idrRequestWork?.cancel()
        self.idrRequestWork = nil
        self.keepaliveTimer?.cancel()
        self.keepaliveTimer = nil
        self.buffer.removeAll()
        guard let port = NWEndpoint.Port(rawValue: rtspPort) else {
            self.fail("invalid_rtsp_port")
            return
        }
        self.stage = .connecting
        self.lastProgress = Date()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                self?.handleConnectionState(state, host: host, port: rtspPort)
            }
        }
        connection.start(queue: self.queue)
        self.startWatchdog()
        DiagnosticsLog.info(
            "xiaomi.wfd.client_start host=\(host) rtspPort=\(rtspPort) clientRTPPort=\(clientRTPPort) attempt=\(self.connectRetryCount + 1)"
        )
    }

    func sendFirstRender() {
        queue.async {
            guard self.stage == .established, !self.firstRenderSent else {
                return
            }
            self.firstRenderSent = true
            self.sendRequest(method: "FIRST_RENDER", target: Self.presentationURL, extraHeaders: self.sessionHeaders())
            DiagnosticsLog.info("xiaomi.wfd.first_render_sent")
        }
    }

    func stop(reason: String) {
        queue.async {
            self.close(reason: reason)
        }
    }

    private func handleConnectionState(_ state: NWConnection.State, host: String, port: UInt16) {
        switch state {
        case .ready:
            stage = .negotiating
            lastProgress = Date()
            consecutiveRefusals = 0
            receive()
            DiagnosticsLog.info("xiaomi.wfd.connected host=\(host) port=\(port)")
        case .waiting(let error):
            if stage == .connecting {
                fail(
                    "connect_waiting \(error.localizedDescription)",
                    retryDelay: 0.25,
                    refused: Self.isConnectionRefused(error)
                )
            }
        case .failed(let error):
            fail("connect_failed \(error.localizedDescription)", refused: Self.isConnectionRefused(error))
        case .cancelled:
            if stage != .closed, stage != .idle {
                close(reason: "connection_cancelled")
            }
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainBuffer()
                }
                if let error {
                    self.fail("receive_error \(error.localizedDescription)")
                    return
                }
                if isComplete {
                    if self.stage != .closed {
                        self.close(reason: "peer_closed")
                    }
                    return
                }
                if self.stage != .closed {
                    self.receive()
                }
            }
        }
    }

    private func drainBuffer() {
        while true {
            guard let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
                return
            }
            let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                fail("bad_header_encoding")
                return
            }
            var lines = headerText.components(separatedBy: "\r\n")
            let firstLine = lines.first ?? ""
            lines.removeFirst()
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            let messageEnd = headerEnd.upperBound + contentLength
            guard buffer.count >= messageEnd else {
                return
            }
            let body = buffer.subdata(in: headerEnd.upperBound..<messageEnd)
            buffer.removeSubrange(0..<messageEnd)
            handleMessage(firstLine: firstLine, headers: headers, body: body)
            if stage == .closed {
                return
            }
        }
    }

    private func handleMessage(firstLine: String, headers: [String: String], body: Data) {
        lastProgress = Date()
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        if firstLine.hasPrefix("RTSP/") {
            handleResponse(firstLine: firstLine, headers: headers, body: bodyText)
            return
        }
        let method = firstLine.split(separator: " ").first.map(String.init) ?? ""
        let cseq = headers["cseq"].flatMap(Int.init) ?? 0
        DiagnosticsLog.info(
            "xiaomi.wfd.rx_request method=\(method) cseq=\(cseq) bytes=\(body.count)"
        )
        switch method {
        case "OPTIONS":
            let authMsg = headers["authmsg"] ?? ""
            var responseHeaders = [
                "CSeq: \(cseq)",
                "Date: \(Self.rtspDate())",
                "User-Agent: \(Self.userAgent)",
                "Public: org.wfa.wfd1.0, GET_PARAMETER, SET_PARAMETER",
                "authKeyType: 2",
                "authAlgorithmVal: 4",
                "authMsgAck:\(Self.authMsgAck(for: authMsg))",
                "fastRTSPVersion: 0"
            ]
            sendRaw(Self.serialize(status: "200 OK", headers: responseHeaders, body: ""))
            responseHeaders.removeAll()
            ourCSeq += 1
            sendRequest(
                method: "OPTIONS",
                target: "*",
                extraHeaders: [
                    "Require: org.wfa.wfd1.0",
                    "lib_version: \(Self.libVersion)",
                    "authMsg:\(ourAuthMsg)"
                ]
            )
        case "GET_PARAMETER":
            let isCapabilityQuery = bodyText.contains("wfd_video_formats")
            let responseBody = isCapabilityQuery ? capabilityBody() : ""
            sendResponse200(cseq: cseq, body: responseBody)
        case "SET_PARAMETER":
            sendResponse200(cseq: cseq, body: "")
            if bodyText.contains("wfd_trigger_method: SETUP") {
                ourCSeq += 1
                sendRequest(
                    method: "SETUP",
                    target: Self.presentationURL,
                    extraHeaders: [
                        "Transport: RTP/AVP/MPT;unicast;client_port=\(clientRTPPort);userid=\(userID)"
                    ]
                )
                stage = .awaitSetupResponse
            } else if bodyText.contains("wfd_trigger_method: TEARDOWN") {
                DiagnosticsLog.info("xiaomi.wfd.teardown_requested")
                onTeardown?()
                close(reason: "peer_teardown")
            }
        default:
            sendResponse200(cseq: cseq, body: "")
        }
    }

    private func handleResponse(firstLine: String, headers: [String: String], body: String) {
        let cseq = headers["cseq"].flatMap(Int.init) ?? -1
        DiagnosticsLog.info(
            "xiaomi.wfd.rx_response cseq=\(cseq) stage=\(stage.rawValue) bytes=\(body.utf8.count)"
        )
        guard firstLine.contains("200") else {
            fail("rtsp_error \(firstLine)")
            return
        }
        switch stage {
        case .awaitSetupResponse:
            if let rawSession = headers["session"] {
                session = rawSession.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces)
            }
            if let transport = headers["transport"],
               let serverPort = Self.parseServerPort(transport) {
                serverRTPPort = serverPort
            }
            ourCSeq += 1
            sendRequest(method: "PLAY", target: Self.presentationURL, extraHeaders: sessionHeaders())
            stage = .awaitPlayResponse
        case .awaitPlayResponse:
            stage = .established
            let port = serverRTPPort ?? 0
            DiagnosticsLog.info(
                "xiaomi.wfd.established session=\(session ?? "none") serverRTPPort=\(port)"
            )
            scheduleIDRRequest()
            startKeepaliveTimer()
            onSessionEstablished?(port)
        default:
            break
        }
    }

    private func capabilityBody() -> String {
        [
            "wfd_audio_codecs_v2: 2 0 0 0",
            "wfd_video_formats: 40 0 2 10 1ffff 1fffffff 0fff 0 0 0 0 none none",
            "wfd_video_enctype: 1 1",
            "wfd_video_gamuttype: 0 0",
            "wfd_slice_codec: none",
            "wfd_video_bitrate: 8000000",
            "wfd_current_video_info: -1 -1 -1 -1",
            "wfd_client_rtp_ports: RTP/AVP/MPT;unicast \(clientRTPPort) 0 mode=play",
            "miplay_support_image: none",
            "wfd_standby_resume_capability: supported",
            "wfd_content_SP_protection: 4 1 256 3 1 1 1 1",
            "wfd_mirror_control_enable:enable",
            "wfd_support_secure_win:enable",
            "device_info: -1 -1 -1 -1 -1 -1 -1",
            "wfd_buffer_capabity: 1F",
            ""
        ].joined(separator: "\r\n")
    }

    private func sessionHeaders() -> [String] {
        guard let session else { return [] }
        return ["Session: \(session)"]
    }

    private func sendResponse200(cseq: Int, body: String) {
        var headers = [
            "CSeq: \(cseq)",
            "Date: \(Self.rtspDate())",
            "User-Agent: \(Self.userAgent)"
        ]
        if body.isEmpty {
            headers.append("Content-Type: text/parameters")
            headers.append("Content-Length: 0")
        }
        sendRaw(Self.serialize(status: "200 OK", headers: headers, body: body))
    }

    // One-shot IDR request at PLAY + idrRequestDelay (official: exactly 20s,
    // target rtsp://localhost/wfd1.0/streamid=0, body "wfd_idr_request").
    private func scheduleIDRRequest() {
        idrRequestWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stage == .established else { return }
            self.ourCSeq += 1
            self.sendRequest(
                method: "SET_PARAMETER",
                target: "rtsp://localhost/wfd1.0/streamid=0",
                extraHeaders: self.sessionHeaders(),
                body: "wfd_idr_request\r\n"
            )
            DiagnosticsLog.info("xiaomi.wfd.idr_request_sent")
        }
        idrRequestWork = work
        queue.asyncAfter(deadline: .now() + idrRequestDelay, execute: work)
    }

    // Sink-initiated GET_PARAMETER keepalive. Empty body is what the
    // cloudflare bridge already sends to MirrorControl on its local RTSP
    // (sessions there stay alive indefinitely); here it resets the phone's
    // RTSP session timeout on the direct WFD route.
    private func startKeepaliveTimer() {
        keepaliveTimer?.cancel()
        guard keepaliveInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + keepaliveInterval,
            repeating: keepaliveInterval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.stage == .established else { return }
            self.ourCSeq += 1
            self.sendRequest(
                method: "GET_PARAMETER",
                target: Self.presentationURL,
                extraHeaders: self.sessionHeaders()
            )
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func sendRequest(method: String, target: String, extraHeaders: [String], body: String = "") {
        var headers = [
            "CSeq: \(ourCSeq)",
            "Date: \(Self.rtspDate())",
            "User-Agent: \(Self.userAgent)"
        ]
        headers.append(contentsOf: extraHeaders)
        if !body.isEmpty {
            headers.append("Content-Type: text/parameters")
            headers.append("Content-Length: \(body.utf8.count)")
        }
        let text = ([method, target, "RTSP/1.0"].joined(separator: " ") + "\r\n" +
            headers.joined(separator: "\r\n") + "\r\n\r\n" + body)
        sendRaw(text)
        DiagnosticsLog.info("xiaomi.wfd.tx_request method=\(method) cseq=\(ourCSeq)")
    }

    private func sendRaw(_ text: String) {
        lastProgress = Date()
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.queue.async {
                    self?.fail("send_failed \(error.localizedDescription)")
                }
            }
        })
    }

    private static func serialize(status: String, headers: [String], body: String) -> String {
        var all = headers
        if !body.isEmpty {
            all.append("Content-Type: text/parameters")
            all.append("Content-Length: \(body.utf8.count)")
        }
        return "RTSP/1.0 \(status)\r\n" + all.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private static func authMsgAck(for authMsg: String) -> String {
        let key = SymmetricKey(data: MiplayPESCrypto.videoKey)
        let code = HMAC<SHA256>.authenticationCode(for: Data(authMsg.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomAuthMsg() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func parseServerPort(_ transport: String) -> UInt16? {
        for component in transport.components(separatedBy: ";") {
            let pair = component.trimmingCharacters(in: .whitespaces)
            if pair.hasPrefix("server_port="),
               let port = UInt16(pair.dropFirst("server_port=".count)) {
                return port
            }
        }
        return nil
    }

    private static func rtspDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.stage != .closed, self.stage != .idle else { return }
            if self.stage != .established {
                let budget: TimeInterval = self.stage == .connecting ? 6 : 15
                if Date().timeIntervalSince(self.lastProgress) > budget {
                    self.fail("stage_timeout \(self.stage.rawValue)")
                }
            }
        }
        watchdog = timer
        timer.resume()
    }

    private static func isConnectionRefused(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .ECONNREFUSED
        }
        return false
    }

    private func fail(_ reason: String, retryDelay: TimeInterval = 1, refused: Bool = false) {
        // The phone opens its RTSP listener only after OPEN_MIRROR_SCREEN is
        // processed (and possibly after an on-phone permission tap), so early
        // connect attempts race the listener. A duplicate OPEN makes the
        // phone tear down and rebuild its RTSP server, which can also reset
        // an in-flight dialog ("Connection reset by peer"). Retry through
        // both windows — anything before .established is safe to redo.
        consecutiveRefusals = refused ? consecutiveRefusals + 1 : 0
        if stage != .established, stage != .closed,
           let args = startArgs,
           connectRetryCount + 1 < Self.maxConnectRetries,
           consecutiveRefusals < Self.maxConsecutiveRefusals {
            connectRetryCount += 1
            DiagnosticsLog.info(
                "xiaomi.wfd.connect_retry attempt=\(connectRetryCount) reason=\(reason)"
            )
            watchdog?.cancel()
            watchdog = nil
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
            stage = .idle
            queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                guard let self, self.stage == .idle else { return }
                self.beginConnection(
                    host: args.host,
                    rtspPort: args.rtspPort,
                    clientRTPPort: args.clientRTPPort
                )
            }
            return
        }
        DiagnosticsLog.warn("xiaomi.wfd.failed reason=\(reason) stage=\(stage.rawValue)")
        close(reason: reason)
    }

    private func close(reason: String) {
        guard stage != .closed else { return }
        stage = .closed
        watchdog?.cancel()
        watchdog = nil
        idrRequestWork?.cancel()
        idrRequestWork = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        connection?.cancel()
        connection = nil
        DiagnosticsLog.info("xiaomi.wfd.closed reason=\(reason)")
        onClosed?(reason)
    }
}
