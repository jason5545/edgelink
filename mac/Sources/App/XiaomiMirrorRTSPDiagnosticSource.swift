import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Network
import VideoToolbox

private enum XiaomiMirrorRTSPTransportMode: String {
    case udp
    case mpt
}

final class XiaomiMirrorRTSPDiagnosticSource {
    private let queue = DispatchQueue(label: "EdgeLink.XiaomiMirrorRTSPDiagnosticSource")
    private let queueKey = DispatchSpecificKey<Void>()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var states: [UUID: RTSPConnectionState] = [:]
    private var stopWorkItem: DispatchWorkItem?
    private var port: UInt16 = 7102
    private var advertisedHost: String?

    private let sourceRTPPort: UInt16 = 19_002
    private let transportModeDefaultsKey = "xiaomiMirrorRTSPTransportMode"

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    func start(port: UInt16 = 7102, advertisedHost: String?, lifetime: TimeInterval) throws {
        try performOnQueue {
            try self.startOnQueue(port: port, advertisedHost: advertisedHost, lifetime: lifetime)
        }
    }

    func stop(reason: String) {
        performOnQueue {
            self.stopOnQueue(reason: reason)
        }
    }

    private func startOnQueue(port: UInt16, advertisedHost: String?, lifetime: TimeInterval) throws {
        let trimmedHost = advertisedHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = trimmedHost?.isEmpty == false ? trimmedHost : nil
        if listener != nil {
            self.advertisedHost = host
            scheduleAutoStop(lifetime: lifetime)
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.listener_already_running port=\(self.port) " +
                    "advertisedHost=\(host ?? "none") lifetime=\(Int(lifetime)) " +
                    "transportMode=\(transportMode.rawValue)"
            )
            return
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw XiaomiMirrorRTSPDiagnosticSourceError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: endpointPort)
        self.port = port
        self.advertisedHost = host
        self.listener = listener
        configure(listener)
        scheduleAutoStop(lifetime: lifetime)
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.listener_start port=\(port) advertisedHost=\(host ?? "none") " +
                "lifetime=\(Int(lifetime)) transportMode=\(transportMode.rawValue)"
        )
        listener.start(queue: queue)
    }

    private func stopOnQueue(reason: String) {
        let hadListener = listener != nil || !connections.isEmpty
        stopWorkItem?.cancel()
        stopWorkItem = nil
        listener?.cancel()
        listener = nil
        for state in states.values {
            state.mediaSender?.stop(reason: "rtsp_listener_\(reason)")
        }
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        states.removeAll()
        if hadListener {
            DiagnosticsLog.info("xiaomi.mirror.rtsp.listener_stop port=\(port) reason=\(reason)")
        }
    }

    private func configure(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            DiagnosticsLog.info("xiaomi.mirror.rtsp.listener_ready port=\(port)")
        case .failed(let error):
            DiagnosticsLog.error("xiaomi.mirror.rtsp.listener_failed port=\(port)", error)
            stopOnQueue(reason: "listener_failed")
        case .cancelled:
            DiagnosticsLog.info("xiaomi.mirror.rtsp.listener_cancelled port=\(port)")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        states[id] = RTSPConnectionState()
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.connection id=\(id.uuidString) endpoint=\(Self.endpointDescription(connection.endpoint))"
        )
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(id: id, connection: connection, state: state)
        }
        connection.start(queue: queue)
        receive(id: id, connection: connection)
    }

    private func handleConnectionState(id: UUID, connection: NWConnection, state: NWConnection.State) {
        switch state {
        case .ready:
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.connection_ready id=\(id.uuidString) " +
                    "endpoint=\(Self.endpointDescription(connection.endpoint))"
            )
            sendOptionsIfNeeded(id: id, connection: connection)
        case .failed(let error):
            DiagnosticsLog.error("xiaomi.mirror.rtsp.connection_failed id=\(id.uuidString)", error)
            cleanupConnection(id: id)
        case .cancelled:
            DiagnosticsLog.info("xiaomi.mirror.rtsp.connection_cancelled id=\(id.uuidString)")
            cleanupConnection(id: id)
        default:
            break
        }
    }

    private func receive(id: UUID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let error {
                DiagnosticsLog.error("xiaomi.mirror.rtsp.receive_failed id=\(id.uuidString)", error)
                self.cleanupConnection(id: id)
                return
            }
            if let data, !data.isEmpty {
                self.handleInboundData(data, id: id, connection: connection)
            }
            if isComplete {
                DiagnosticsLog.info("xiaomi.mirror.rtsp.connection_complete id=\(id.uuidString)")
                self.cleanupConnection(id: id)
                return
            }
            self.receive(id: id, connection: connection)
        }
    }

    private func handleInboundData(_ data: Data, id: UUID, connection: NWConnection) {
        guard var state = states[id] else {
            return
        }
        state.buffer.append(data)
        let messages = Self.popRTSPMessages(from: &state.buffer)
        states[id] = state
        for messageData in messages {
            guard let message = Self.parseRTSPMessage(messageData) else {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.rtsp.parse_failed id=\(id.uuidString) bytes=\(messageData.count) " +
                        "fp=\(DiagnosticsLog.fingerprint(messageData))"
                )
                continue
            }
            handle(message: message, rawData: messageData, id: id, connection: connection)
        }
    }

    private func handle(message: RTSPMessage, rawData: Data, id: UUID, connection: NWConnection) {
        var state = states[id] ?? RTSPConnectionState()
        let bodyPreview = Self.preview(message.body)
        if !state.loggedFirstInbound {
            state.loggedFirstInbound = true
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.first_message id=\(id.uuidString) firstLine=\(Self.preview(message.firstLine)) " +
                    "cseq=\(message.cseq.map(String.init) ?? "none") bytes=\(rawData.count) " +
                    "bodyFp=\(DiagnosticsLog.fingerprint(Data(message.body.utf8))) body=\(bodyPreview)"
            )
        }
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.message_in id=\(id.uuidString) firstLine=\(Self.preview(message.firstLine)) " +
                "cseq=\(message.cseq.map(String.init) ?? "none") bytes=\(rawData.count) body=\(bodyPreview)"
        )
        states[id] = state

        if message.isResponse {
            handleResponse(message, id: id, connection: connection)
        } else {
            handleRequest(message, id: id, connection: connection)
        }
    }

    private func handleResponse(_ message: RTSPMessage, id: UUID, connection: NWConnection) {
        guard let cseq = message.cseq else {
            DiagnosticsLog.warn("xiaomi.mirror.rtsp.response_missing_cseq id=\(id.uuidString) firstLine=\(message.firstLine)")
            return
        }
        var state = states[id] ?? RTSPConnectionState()
        let request = state.pendingRequests.removeValue(forKey: cseq)
        if let session = message.headers["session"]?.split(separator: ";").first {
            state.session = String(session)
        }
        states[id] = state

        switch request {
        case "OPTIONS":
            sendGetParameterIfNeeded(id: id, connection: connection)
        case "GET_PARAMETER":
            recordSinkCapabilities(message.body, id: id)
            sendSetParameterIfNeeded(id: id, connection: connection)
        case "SET_PARAMETER":
            DiagnosticsLog.info("xiaomi.mirror.rtsp.m4_ack id=\(id.uuidString) cseq=\(cseq)")
        default:
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.response_unmatched id=\(id.uuidString) cseq=\(cseq) " +
                    "pending=\(request ?? "none") firstLine=\(Self.preview(message.firstLine))"
            )
        }
    }

    private func handleRequest(_ message: RTSPMessage, id: UUID, connection: NWConnection) {
        guard let method = message.method else {
            DiagnosticsLog.warn("xiaomi.mirror.rtsp.request_missing_method id=\(id.uuidString) firstLine=\(message.firstLine)")
            return
        }
        switch method {
        case "OPTIONS":
            sendResponse(
                id: id,
                connection: connection,
                cseq: message.cseq,
                extraHeaders: [
                    "Public: org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER"
                ]
            )
            sendGetParameterIfNeeded(id: id, connection: connection)
        case "GET_PARAMETER":
            let currentState = states[id] ?? RTSPConnectionState()
            let body = sourceParameterResponseBody(requestBody: message.body, state: currentState)
            let extraHeaders = ["Content-Type: text/parameters"]
            let loggedHeaders = ([currentState.session.map { "Session: \($0)" }].compactMap { $0 } + extraHeaders)
                .joined(separator: "|")
            sendResponse(
                id: id,
                connection: connection,
                cseq: message.cseq,
                session: currentState.session,
                body: body,
                extraHeaders: extraHeaders
            )
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.source_parameter_response id=\(id.uuidString) " +
                    "session=\(currentState.session ?? "none") headers=\(Self.preview(loggedHeaders)) " +
                    "body=\(Self.preview(body, limit: 900))"
            )
        case "SET_PARAMETER":
            if message.body.contains("wfd_trigger_method") {
                DiagnosticsLog.info(
                    "xiaomi.mirror.rtsp.peer_trigger id=\(id.uuidString) body=\(Self.preview(message.body))"
                )
            }
            sendResponse(id: id, connection: connection, cseq: message.cseq)
        case "SETUP":
            handleSetupRequest(message, id: id, connection: connection)
        case "PLAY":
            sendResponse(
                id: id,
                connection: connection,
                cseq: message.cseq,
                session: session(for: id),
                extraHeaders: ["Range: npt=0-"]
            )
            DiagnosticsLog.info("xiaomi.mirror.rtsp.play_received id=\(id.uuidString) session=\(session(for: id))")
            startMediaIfPossible(id: id)
        case "PAUSE", "TEARDOWN":
            sendResponse(id: id, connection: connection, cseq: message.cseq, session: session(for: id))
            stopMediaIfNeeded(id: id, reason: method.lowercased())
            if method == "TEARDOWN" {
                cleanupConnection(id: id)
            }
        default:
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.request_unsupported id=\(id.uuidString) method=\(method) " +
                    "firstLine=\(Self.preview(message.firstLine))"
            )
            sendResponse(id: id, connection: connection, cseq: message.cseq, status: "405 Method Not Allowed")
        }
    }

    private func handleSetupRequest(_ message: RTSPMessage, id: UUID, connection: NWConnection) {
        var state = states[id] ?? RTSPConnectionState()
        if state.session == nil {
            state.session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        states[id] = state

        let requestTransport = message.headers["transport"]
        let setupTransport = parseSetupTransport(
            requestTransport,
            fallbackEndpoint: connection.endpoint,
            fallbackClientRTPPorts: state.sinkClientRTPPorts
        )
        state.setupTransport = setupTransport
        states[id] = state
        let mode = transportMode
        let responseTransport = setupResponseTransport(for: requestTransport, parsed: setupTransport, mode: mode)
        sendResponse(
            id: id,
            connection: connection,
            cseq: message.cseq,
            session: session(for: id),
            extraHeaders: ["Transport: \(responseTransport.value)"]
        )
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.setup_received id=\(id.uuidString) session=\(session(for: id)) " +
                "transportMode=\(mode.rawValue) requestTransport=\(Self.preview(requestTransport ?? "none")) " +
                "responseTransport=\(responseTransport.value) " +
                "preservedTokens=\(Self.preview(responseTransport.preservedTokens.joined(separator: ","))) " +
                "omittedTokens=\(Self.preview(responseTransport.omittedTokens.joined(separator: ","))) " +
                "destination=\(setupTransport.destinationHost ?? "none") clientRTPPort=\(setupTransport.clientRTPPort.map(String.init) ?? "none") " +
                "clientRTCPPort=\(setupTransport.clientRTCPPort.map(String.init) ?? "none") tcpInterleaved=\(setupTransport.isTCPInterleaved)"
        )
    }

    private func sendOptionsIfNeeded(id: UUID, connection: NWConnection) {
        var state = states[id] ?? RTSPConnectionState()
        guard !state.sentOptions else {
            return
        }
        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.sentOptions = true
        state.pendingRequests[cseq] = "OPTIONS"
        states[id] = state
        let message = makeRequest(
            method: "OPTIONS",
            target: "*",
            cseq: cseq,
            extraHeaders: [
                "Require: org.wfa.wfd1.0",
                "User-Agent: EdgeLink-XiaomiMirror/1.0",
                "fastRTSPVersion: 0"
            ]
        )
        send(message, id: id, connection: connection)
    }

    private func sendGetParameterIfNeeded(id: UUID, connection: NWConnection) {
        var state = states[id] ?? RTSPConnectionState()
        guard !state.sentGetParameter else {
            return
        }
        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.sentGetParameter = true
        state.pendingRequests[cseq] = "GET_PARAMETER"
        states[id] = state
        let body = [
            "wfd_audio_codecs",
            "wfd_video_formats",
            "wfd_video_enctype",
            "wfd_video_gamuttype",
            "wfd_current_video_info",
            "wfd_client_rtp_ports",
            "wfd_content_protection",
            "wfd_content_SP_protection",
            "wfd_mirror_control_enable",
            "wfd_support_secure_win",
            "wfd_standby_resume_capability",
            "wfd_tcp_enable",
            "wfd_tcp_multi_session_enable",
            "wfd_mpt_enable",
            "wfd_image_enable_v2",
            "wfd_slice_codec",
            "wfd_delay_test_enable",
            "wfd_connector_type"
        ].joined(separator: "\r\n") + "\r\n"
        let message = makeRequest(
            method: "GET_PARAMETER",
            target: "rtsp://localhost/wfd1.0",
            cseq: cseq,
            body: body,
            extraHeaders: ["Content-Type: text/parameters"]
        )
        send(message, id: id, connection: connection)
    }

    private func sendSetParameterIfNeeded(id: UUID, connection: NWConnection) {
        var state = states[id] ?? RTSPConnectionState()
        guard !state.sentSetParameter else {
            return
        }
        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.sentSetParameter = true
        state.pendingRequests[cseq] = "SET_PARAMETER"
        states[id] = state
        let body = sourceSetParameterBody(state: state)
        let mode = transportMode
        let clientRTPPorts = sourceClientRTPPorts(from: state, mode: mode)
        let mptEnable = sourceMPTEnable(from: state, mode: mode)
        let message = makeRequest(
            method: "SET_PARAMETER",
            target: "rtsp://localhost/wfd1.0",
            cseq: cseq,
            body: body,
            extraHeaders: ["Content-Type: text/parameters"]
        )
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.m4_body id=\(id.uuidString) transportMode=\(mode.rawValue) " +
                "clientRTPPorts=\(Self.preview(clientRTPPorts)) mptEnable=\(mptEnable) " +
                "body=\(Self.preview(body, limit: 900))"
        )
        send(message, id: id, connection: connection)
    }

    private func recordSinkCapabilities(_ body: String, id: UUID) {
        var state = states[id] ?? RTSPConnectionState()
        state.sinkCapabilitiesFingerprint = DiagnosticsLog.fingerprint(Data(body.utf8))
        state.sinkVideoFormats = Self.parameterValue(named: "wfd_video_formats", in: body)
        state.sinkVideoEnctype = Self.parameterValue(named: "wfd_video_enctype", in: body)
        state.sinkVideoGamutType = Self.parameterValue(named: "wfd_video_gamuttype", in: body)
        state.sinkAudioCodecs = Self.parameterValue(named: "wfd_audio_codecs", in: body)
        state.sinkClientRTPPorts = Self.parameterValue(named: "wfd_client_rtp_ports", in: body)
        states[id] = state
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.sink_capabilities id=\(id.uuidString) " +
                "bodyFp=\(state.sinkCapabilitiesFingerprint ?? "none") " +
                "videoFormats=\(Self.preview(state.sinkVideoFormats ?? "none")) " +
                "clientRTPPorts=\(Self.preview(state.sinkClientRTPPorts ?? "none")) " +
                "body=\(Self.preview(body, limit: 900))"
        )
    }

    private func sourceSetParameterBody(state: RTSPConnectionState) -> String {
        let presentationURL = sourcePresentationURL()
        let videoFormats = Self.defaultH264VideoFormats
        let videoEnctype = "1 1"
        let videoGamutType = "1 1"
        let audioCodecs = sourceAudioCodecs
        let mode = transportMode
        let clientRTPPorts = sourceClientRTPPorts(from: state, mode: mode)
        let mptEnable = sourceMPTEnable(from: state, mode: mode)
        return [
            "wfd_presentation_URL: \(presentationURL) none",
            "wfd_video_formats: \(videoFormats)",
            "wfd_video_bitrate: 5000000",
            "wfd_video_enctype: \(videoEnctype)",
            "wfd_video_gamuttype: \(videoGamutType)",
            "wfd_audio_codecs: \(audioCodecs)",
            "wfd_client_rtp_ports: \(clientRTPPorts)",
            "wfd_content_protection: none",
            "wfd_content_SP_protection: 0 0 0 0 0 0 0 0",
            "wfd_mirror_control_enable: enable",
            "wfd_support_secure_win: enable",
            "wfd_standby_resume_capability: supported",
            "wfd_tcp_enable: 0",
            "wfd_tcp_multi_session_enable: 0",
            "wfd_mpt_enable: \(mptEnable)",
            "wfd_connector_type: 07",
            "wfd_platform_type: 2",
            "wfd_trigger_method: SETUP"
        ].joined(separator: "\r\n") + "\r\n"
    }

    private func sourceParameterResponseBody(requestBody: String, state: RTSPConnectionState) -> String {
        let requestedNames = Self.requestedParameterNames(in: requestBody)
        let mode = transportMode
        let parameters: [(String, String)] = [
            ("wfd_audio_codecs", sourceAudioCodecs),
            ("wfd_video_formats", Self.defaultH264VideoFormats),
            ("wfd_video_enctype", "1 1"),
            ("wfd_video_gamuttype", "1 1"),
            ("wfd_current_video_info", Self.sourceCurrentVideoInfo),
            ("wfd_client_rtp_ports", sourceClientRTPPorts(from: state, mode: mode)),
            ("wfd_content_protection", "none"),
            ("wfd_content_SP_protection", "0 0 0 0 0 0 0 0"),
            ("wfd_mirror_control_enable", "enable"),
            ("wfd_support_secure_win", "enable"),
            ("wfd_standby_resume_capability", "supported"),
            ("wfd_tcp_enable", "0"),
            ("wfd_tcp_multi_session_enable", "0"),
            ("wfd_mpt_enable", sourceMPTEnable(from: state, mode: mode)),
            ("wfd_image_enable_v2", "none"),
            ("wfd_slice_codec", "none"),
            ("wfd_delay_test_enable", "enable"),
            ("wfd_connector_type", "07"),
            ("wfd_presentation_URL", "\(sourcePresentationURL()) none")
        ]
        return parameters.compactMap { name, value -> String? in
            if requestedNames.isEmpty || requestedNames.contains(name.lowercased()) {
                return "\(name): \(value)"
            }
            return nil
        }.joined(separator: "\r\n") + "\r\n"
    }

    private func sourceClientRTPPorts(from state: RTSPConnectionState, mode: XiaomiMirrorRTSPTransportMode) -> String {
        guard let raw = state.sinkClientRTPPorts?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "RTP/AVP/UDP;unicast 0 0 mode=play"
        }
        if mode == .udp {
            let port = Self.sinkClientRTPPort(from: raw).map(String.init) ?? "0"
            return "RTP/AVP/UDP;unicast \(port) 0 mode=play"
        }
        let components = raw.split(separator: ";", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if Self.parseBareRTPPortPair(in: components) != nil || fieldValue("client_port", in: components) != nil {
            return raw
        }
        return raw
    }

    private func sourceMPTEnable(from state: RTSPConnectionState, mode: XiaomiMirrorRTSPTransportMode) -> String {
        if mode == .udp {
            return "0"
        }
        let clientRTPPorts = sourceClientRTPPorts(from: state, mode: mode)
        return clientRTPPorts.localizedCaseInsensitiveContains("RTP/AVP/MPT") ? "1" : "0"
    }

    private var sourceAudioCodecs: String {
        // Xiaomi's native parser assumes the AAC token exists and crashes if this is "none".
        "AAC 00000001 00"
    }

    private func sourcePresentationURL() -> String {
        let host = advertisedHost ?? "localhost"
        if host.contains(":") {
            return "rtsp://[\(host)]:\(port)/wfd1.0/streamid=0"
        }
        return "rtsp://\(host):\(port)/wfd1.0/streamid=0"
    }

    private var transportMode: XiaomiMirrorRTSPTransportMode {
        XiaomiMirrorRTSPTransportMode(rawValue: UserDefaults.standard.string(forKey: transportModeDefaultsKey) ?? "") ?? .udp
    }

    private func setupResponseTransport(
        for requestTransport: String?,
        parsed: RTSPTransportSelection,
        mode: XiaomiMirrorRTSPTransportMode
    ) -> RTSPTransportResponse {
        let raw = requestTransport?.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = raw?.split(separator: ";", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? []
        let transport = parsed.transportProtocol.isEmpty ? "RTP/AVP/UDP" : parsed.transportProtocol
        let isMPT = mode == .mpt && transport.localizedCaseInsensitiveContains("MPT")
        var response = [transport]
        var preserved: [String] = []
        var omitted: [String] = []

        if isMPT {
            let clientPort = parsed.clientRTPPort.map(String.init)
                ?? parsed.clientPortRaw.flatMap { Self.parsePortPair($0).0.map(String.init) }
                ?? "0"
            response.append("unicast")
            response.append("client_port=\(clientPort)")
            response.append("server_port=\(sourceRTPPort)")
            preserved.append("client_port")
            if let userid = fieldValue("userid", in: components), !userid.isEmpty {
                response.append("userid=\(userid)")
                preserved.append("userid=\(userid)")
            } else {
                omitted.append("userid_missing")
            }
            omitted.append("source")
            return RTSPTransportResponse(
                value: response.joined(separator: ";"),
                preservedTokens: preserved,
                omittedTokens: omitted
            )
        }

        response = ["RTP/AVP/UDP", "unicast"]
        if let clientPort = parsed.clientRTPPort {
            response.append("client_port=\(clientPort)")
            preserved.append("client_port=\(clientPort)")
        } else if let clientPort = parsed.clientPortRaw ?? fieldValue("client_port", in: components) {
            response.append("client_port=\(clientPort)")
            preserved.append("client_port=\(clientPort)")
        } else {
            response.append("client_port=0")
            omitted.append("client_port_missing")
        }
        for component in components.dropFirst() {
            let lower = component.lowercased()
            if lower.hasPrefix("source=") || lower.hasPrefix("destination=") || lower.hasPrefix("interleaved=") ||
                lower.hasPrefix("server_port=") || lower.hasPrefix("userid=") ||
                lower == "unicast" || Self.isBareUnicastPortComponent(component) || lower.hasPrefix("client_port=") {
                omitted.append(component)
            }
        }
        response.append("server_port=\(sourceRTPPort)-\(sourceRTPPort + 1)")
        return RTSPTransportResponse(
            value: response.joined(separator: ";"),
            preservedTokens: preserved,
            omittedTokens: omitted
        )
    }

    private func parseSetupTransport(
        _ requestTransport: String?,
        fallbackEndpoint: NWEndpoint,
        fallbackClientRTPPorts: String?
    ) -> RTSPTransportSelection {
        let raw = requestTransport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let components = raw.split(separator: ";", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let transport = components.first ?? "RTP/AVP/UDP"
        let clientPortRaw = fieldValue("client_port", in: components)
        let bareClientPorts = Self.parseBareRTPPortPair(in: components)
            ?? Self.parseBareRTPPortPair(in: fallbackClientRTPPorts)
        let clientPorts = Self.parsePortPair(clientPortRaw)
        let clientRTPPort = clientPorts.0 ?? bareClientPorts?.0
        let clientRTCPPort = clientPorts.1 ?? bareClientPorts?.1
        let destination = fieldValue("destination", in: components)
            ?? Self.endpointHost(fallbackEndpoint)
        let interleaved = fieldValue("interleaved", in: components)
        return RTSPTransportSelection(
            raw: raw,
            transportProtocol: transport,
            destinationHost: destination,
            clientPortRaw: clientPortRaw,
            clientRTPPort: clientRTPPort,
            clientRTCPPort: clientRTCPPort,
            interleavedRaw: interleaved,
            isTCPInterleaved: transport.localizedCaseInsensitiveContains("TCP") || interleaved != nil
        )
    }

    private func fieldValue(_ name: String, in components: [String]) -> String? {
        let prefix = "\(name)="
        return components.first { $0.lowercased().hasPrefix(prefix) }?.dropFirst(prefix.count).description
    }

    private func sourceHostForTransport() -> String? {
        guard let host = advertisedHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              !host.contains(":") else {
            return nil
        }
        return host
    }

    private func startMediaIfPossible(id: UUID) {
        guard var state = states[id] else {
            return
        }
        guard state.mediaSender == nil else {
            DiagnosticsLog.info("xiaomi.mirror.rtsp.media_already_running id=\(id.uuidString)")
            return
        }
        guard let transport = state.setupTransport else {
            DiagnosticsLog.warn("xiaomi.mirror.rtsp.media_start_skipped id=\(id.uuidString) reason=missing_setup_transport")
            return
        }
        guard !transport.isTCPInterleaved else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.media_start_skipped id=\(id.uuidString) reason=tcp_interleaved_unsupported " +
                    "transport=\(Self.preview(transport.raw))"
            )
            return
        }
        guard let host = transport.destinationHost, let clientRTPPort = transport.clientRTPPort else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.media_start_skipped id=\(id.uuidString) reason=missing_udp_destination " +
                    "destination=\(transport.destinationHost ?? "none") clientRTPPort=\(transport.clientRTPPort.map(String.init) ?? "none") " +
                    "transport=\(Self.preview(transport.raw))"
            )
            return
        }
        do {
            let sender = try XiaomiMirrorRTPMediaSender(
                destinationHost: host,
                destinationRTPPort: clientRTPPort,
                localRTPPort: sourceRTPPort,
                sessionID: id
            )
            state.mediaSender = sender
            states[id] = state
            sender.start()
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.media_started id=\(id.uuidString) destination=\(host):\(clientRTPPort) " +
                    "localRTPPort=\(sourceRTPPort) payload=rtp_pt33_mpegts_h264_annexb"
            )
        } catch {
            DiagnosticsLog.error(
                "xiaomi.mirror.rtsp.media_start_failed id=\(id.uuidString) destination=\(host):\(clientRTPPort)",
                error
            )
        }
    }

    private func stopMediaIfNeeded(id: UUID, reason: String) {
        guard var state = states[id], let sender = state.mediaSender else {
            return
        }
        sender.stop(reason: reason)
        state.mediaSender = nil
        states[id] = state
    }

    private func sendResponse(
        id: UUID,
        connection: NWConnection,
        cseq: Int?,
        status: String = "200 OK",
        session: String? = nil,
        body: String? = nil,
        extraHeaders: [String] = []
    ) {
        let message = makeResponse(
            status: status,
            cseq: cseq,
            session: session,
            body: body,
            extraHeaders: extraHeaders
        )
        send(message, id: id, connection: connection)
    }

    private func makeRequest(
        method: String,
        target: String,
        cseq: Int,
        body: String? = nil,
        extraHeaders: [String] = []
    ) -> String {
        var headers = [
            "\(method) \(target) RTSP/1.0",
            "CSeq: \(cseq)"
        ]
        headers.append(contentsOf: extraHeaders)
        let bodyBytes = Data((body ?? "").utf8).count
        headers.append("Content-Length: \(bodyBytes)")
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + (body ?? "")
    }

    private func makeResponse(
        status: String,
        cseq: Int?,
        session: String?,
        body: String?,
        extraHeaders: [String]
    ) -> String {
        var headers = ["RTSP/1.0 \(status)"]
        if let cseq {
            headers.append("CSeq: \(cseq)")
        }
        if let session {
            headers.append("Session: \(session)")
        }
        headers.append(contentsOf: extraHeaders)
        let bodyBytes = Data((body ?? "").utf8).count
        headers.append("Content-Length: \(bodyBytes)")
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + (body ?? "")
    }

    private func send(_ message: String, id: UUID, connection: NWConnection) {
        let data = Data(message.utf8)
        let firstLine = message.components(separatedBy: "\r\n").first ?? "unknown"
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.message_out id=\(id.uuidString) firstLine=\(Self.preview(firstLine)) " +
                "bytes=\(data.count) fp=\(DiagnosticsLog.fingerprint(data))"
        )
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.error("xiaomi.mirror.rtsp.send_failed id=\(id.uuidString)", error)
            }
        })
    }

    private func session(for id: UUID) -> String {
        if let session = states[id]?.session {
            return session
        }
        let session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var state = states[id] ?? RTSPConnectionState()
        state.session = session
        states[id] = state
        return session
    }

    private func cleanupConnection(id: UUID) {
        stopMediaIfNeeded(id: id, reason: "connection_cleanup")
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        states.removeValue(forKey: id)
    }

    private func scheduleAutoStop(lifetime: TimeInterval) {
        stopWorkItem?.cancel()
        guard lifetime > 0 else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopOnQueueIfIdle(reason: "lifetime_expired")
        }
        stopWorkItem = workItem
        queue.asyncAfter(deadline: .now() + lifetime, execute: workItem)
    }

    private func stopOnQueueIfIdle(reason: String) {
        let activeMedia = states.values.filter { $0.mediaSender != nil }.count
        guard connections.isEmpty && activeMedia == 0 else {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.listener_stop_deferred reason=\(reason) " +
                    "connections=\(connections.count) activeMedia=\(activeMedia)"
            )
            scheduleAutoStop(lifetime: 30)
            return
        }
        stopOnQueue(reason: reason)
    }

    private func performOnQueue(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private func performOnQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    private static func popRTSPMessages(from buffer: inout Data) -> [Data] {
        var messages: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let headerRange = buffer.range(of: separator) {
            let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
            let headerText = String(data: headerData, encoding: .isoLatin1) ?? ""
            let contentLength = contentLength(from: headerText)
            let messageEnd = headerRange.upperBound + contentLength
            guard buffer.count >= messageEnd else {
                break
            }
            messages.append(buffer.subdata(in: 0..<messageEnd))
            buffer.removeSubrange(0..<messageEnd)
        }
        return messages
    }

    private static func parseRTSPMessage(_ data: Data) -> RTSPMessage? {
        guard let text = String(data: data, encoding: .isoLatin1),
              let separator = text.range(of: "\r\n\r\n") else {
            return nil
        }
        let headerText = String(text[..<separator.lowerBound])
        let body = String(text[separator.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !firstLine.isEmpty else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return RTSPMessage(firstLine: firstLine, headers: headers, body: body)
    }

    private static func contentLength(from headerText: String) -> Int {
        for line in headerText.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == "content-length" else {
                continue
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value) ?? 0
        }
        return 0
    }

    private static func parameterValue(named name: String, in body: String) -> String? {
        let normalizedName = name.lowercased()
        for line in body.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == normalizedName else {
                continue
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private static func requestedParameterNames(in body: String) -> Set<String> {
        Set(
            body.components(separatedBy: .newlines).compactMap { line -> String? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    return nil
                }
                return (value.components(separatedBy: ":").first ?? value).lowercased()
            }
        )
    }

    private static func preview(_ value: String, limit: Int = 320) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: " ")
        guard collapsed.count > limit else {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "...truncated"
    }

    private static func endpointDescription(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port.rawValue)"
        default:
            return "\(endpoint)"
        }
    }

    private static func endpointHost(_ endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            let value = "\(host)".trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        default:
            return nil
        }
    }

    private static func parsePortPair(_ raw: String?) -> (UInt16?, UInt16?) {
        guard let raw else {
            return (nil, nil)
        }
        let pieces = raw
            .replacingOccurrences(of: " ", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = pieces.first.flatMap(UInt16.init) else {
            return (nil, nil)
        }
        let second = pieces.dropFirst().first.flatMap(UInt16.init)
        return (first, second)
    }

    private static func parseBareRTPPortPair(in raw: String?) -> (UInt16, UInt16?)? {
        guard let raw else {
            return nil
        }
        let components = raw.split(separator: ";", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return parseBareRTPPortPair(in: components)
    }

    private static func parseBareRTPPortPair(in components: [String]) -> (UInt16, UInt16?)? {
        for component in components {
            let tokens = component.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2,
                  tokens.first?.lowercased() == "unicast",
                  let rtpPort = UInt16(tokens[1]),
                  rtpPort > 0 else {
                continue
            }
            let rtcpPort = tokens.dropFirst(2).first.flatMap(UInt16.init).flatMap { $0 > 0 ? $0 : nil }
            return (rtpPort, rtcpPort)
        }
        return nil
    }

    private static func sinkClientRTPPort(from raw: String) -> UInt16? {
        let components = raw.split(separator: ";", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let barePort = parseBareRTPPortPair(in: components)?.0 {
            return barePort
        }
        if let clientPortRaw = components.first(where: { $0.lowercased().hasPrefix("client_port=") })?
            .dropFirst("client_port=".count)
            .description {
            return parsePortPair(clientPortRaw).0
        }
        return nil
    }

    private static func isBareUnicastPortComponent(_ component: String) -> Bool {
        let tokens = component.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2,
              tokens.first?.lowercased() == "unicast",
              let port = UInt16(tokens[1]) else {
            return false
        }
        return port > 0
    }

    private static let defaultH264VideoFormats = "a8 00 01 01 0061ffff 3fffffff 00000fff 00 0000 0000 00 none none"
    private static let sourceCurrentVideoInfo = "640 360 15 5000000"
}

private struct RTSPConnectionState {
    var buffer = Data()
    var nextCSeq = 1
    var pendingRequests: [Int: String] = [:]
    var sentOptions = false
    var sentGetParameter = false
    var sentSetParameter = false
    var loggedFirstInbound = false
    var session: String?
    var sinkCapabilitiesFingerprint: String?
    var sinkVideoFormats: String?
    var sinkVideoEnctype: String?
    var sinkVideoGamutType: String?
    var sinkAudioCodecs: String?
    var sinkClientRTPPorts: String?
    var setupTransport: RTSPTransportSelection?
    var mediaSender: XiaomiMirrorRTPMediaSender?
}

private struct RTSPTransportResponse {
    let value: String
    let preservedTokens: [String]
    let omittedTokens: [String]
}

private struct RTSPTransportSelection {
    let raw: String
    let transportProtocol: String
    let destinationHost: String?
    let clientPortRaw: String?
    let clientRTPPort: UInt16?
    let clientRTCPPort: UInt16?
    let interleavedRaw: String?
    let isTCPInterleaved: Bool

    var clientPortResponseValue: String? {
        guard let clientRTPPort else {
            return nil
        }
        let rtcpPort = clientRTCPPort ?? clientRTPPort + 1
        return "\(clientRTPPort)-\(rtcpPort)"
    }
}

private final class XiaomiMirrorRTPMediaSender {
    private let queue = DispatchQueue(label: "EdgeLink.XiaomiMirrorRTPMediaSender")
    private let destinationHost: String
    private let destinationRTPPort: UInt16
    private let localRTPPort: UInt16
    private let sessionID: UUID
    private let frameRate: Int32 = 15
    private let rtpPacketsPerPayload = 7
    private var connection: NWConnection?
    private var frameTimer: DispatchSourceTimer?
    private var encoder: XiaomiMirrorH264Encoder
    private var muxer = XiaomiMirrorMPEGTSMuxer()
    private var sequenceNumber = UInt16.random(in: 0...UInt16.max)
    private var ssrc = UInt32.random(in: 1...UInt32.max)
    private var frameIndex: UInt64 = 0
    private var framesSent: UInt64 = 0
    private var rtpPacketsSent: UInt64 = 0
    private var stopped = false

    init(destinationHost: String, destinationRTPPort: UInt16, localRTPPort: UInt16, sessionID: UUID) throws {
        self.destinationHost = destinationHost
        self.destinationRTPPort = destinationRTPPort
        self.localRTPPort = localRTPPort
        self.sessionID = sessionID
        self.encoder = try XiaomiMirrorH264Encoder(width: 640, height: 360, frameRate: frameRate)
    }

    func start() {
        queue.async {
            self.startOnQueue()
        }
    }

    func stop(reason: String) {
        queue.async {
            self.stopOnQueue(reason: reason)
        }
    }

    private func startOnQueue() {
        guard connection == nil, !stopped else {
            return
        }
        guard let remotePort = NWEndpoint.Port(rawValue: destinationRTPPort),
              let localPort = NWEndpoint.Port(rawValue: localRTPPort) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtp.start_skipped session=\(sessionID.uuidString) reason=invalid_port " +
                    "destinationPort=\(destinationRTPPort) localPort=\(localRTPPort)"
            )
            return
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: localPort)
        let connection = NWConnection(host: NWEndpoint.Host(destinationHost), port: remotePort, using: parameters)
        self.connection = connection
        encoder.onFrame = { [weak self] frame in
            self?.queue.async {
                self?.send(frame)
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                self?.handleConnectionState(state)
            }
        }
        connection.start(queue: queue)
        startFrameTimer()
        DiagnosticsLog.info(
            "xiaomi.mirror.rtp.start session=\(sessionID.uuidString) destination=\(destinationHost):\(destinationRTPPort) " +
                "localRTPPort=\(localRTPPort) payload=RTP/PT33/MP2T/H264AnnexB video=640x360@\(frameRate)"
        )
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            DiagnosticsLog.info(
                "xiaomi.mirror.rtp.ready session=\(sessionID.uuidString) destination=\(destinationHost):\(destinationRTPPort)"
            )
        case .failed(let error):
            DiagnosticsLog.error("xiaomi.mirror.rtp.failed session=\(sessionID.uuidString)", error)
            stopOnQueue(reason: "udp_failed")
        case .cancelled:
            DiagnosticsLog.info("xiaomi.mirror.rtp.cancelled session=\(sessionID.uuidString)")
        default:
            break
        }
    }

    private func startFrameTimer() {
        frameTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let intervalNanoseconds = UInt64(1_000_000_000 / UInt64(frameRate))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNanoseconds)), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.encodeNextFrame()
        }
        frameTimer = timer
        timer.resume()
    }

    private func encodeNextFrame() {
        guard !stopped else {
            return
        }
        do {
            try encoder.encodeBlackFrame(index: frameIndex)
            frameIndex += 1
        } catch {
            DiagnosticsLog.error("xiaomi.mirror.rtp.encode_failed session=\(sessionID.uuidString)", error)
            stopOnQueue(reason: "encode_failed")
        }
    }

    private func send(_ frame: XiaomiMirrorEncodedH264Frame) {
        guard !stopped, let connection else {
            return
        }
        let includeProgramInfo = frame.isKeyframe || framesSent % UInt64(frameRate) == 0
        let tsPackets = muxer.makePackets(
            frame: frame.annexB,
            pts90k: frame.pts90k,
            includeProgramInfo: includeProgramInfo
        )
        var packetIndex = 0
        while packetIndex < tsPackets.count {
            let end = min(packetIndex + rtpPacketsPerPayload, tsPackets.count)
            var payload = Data(capacity: (end - packetIndex) * 188)
            for packet in tsPackets[packetIndex..<end] {
                payload.append(packet)
            }
            sendRTPPayload(
                payload,
                timestamp: UInt32(frame.pts90k & 0xffff_ffff),
                marker: end == tsPackets.count,
                connection: connection
            )
            packetIndex = end
        }
        framesSent += 1
        if framesSent <= 5 || frame.isKeyframe || framesSent % UInt64(frameRate * 5) == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtp.frame_sent session=\(sessionID.uuidString) frame=\(framesSent) " +
                    "keyframe=\(frame.isKeyframe) nalCount=\(frame.nalCount) h264Bytes=\(frame.annexB.count) " +
                    "tsPackets=\(tsPackets.count) rtpPackets=\(rtpPacketsSent) pts90k=\(frame.pts90k)"
            )
        }
    }

    private func sendRTPPayload(_ payload: Data, timestamp: UInt32, marker: Bool, connection: NWConnection) {
        var packet = Data(capacity: 12 + payload.count)
        packet.append(0x80)
        packet.append(UInt8((marker ? 0x80 : 0x00) | 33))
        packet.appendUInt16(sequenceNumber)
        packet.appendUInt32(timestamp)
        packet.appendUInt32(ssrc)
        packet.append(payload)
        let currentSequence = sequenceNumber
        sequenceNumber &+= 1
        rtpPacketsSent += 1
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.error(
                    "xiaomi.mirror.rtp.send_failed session=\(self.sessionID.uuidString) seq=\(currentSequence)",
                    error
                )
            }
        })
    }

    private func stopOnQueue(reason: String) {
        guard !stopped || connection != nil || frameTimer != nil else {
            return
        }
        stopped = true
        frameTimer?.cancel()
        frameTimer = nil
        encoder.invalidate()
        connection?.cancel()
        connection = nil
        DiagnosticsLog.info(
            "xiaomi.mirror.rtp.stop session=\(sessionID.uuidString) reason=\(reason) " +
                "frames=\(framesSent) rtpPackets=\(rtpPacketsSent)"
        )
    }
}

private final class XiaomiMirrorH264Encoder {
    var onFrame: ((XiaomiMirrorEncodedH264Frame) -> Void)?

    private let width: Int32
    private let height: Int32
    private let frameRate: Int32
    private var compressionSession: VTCompressionSession?
    private var nalLengthSize = 4

    init(width: Int32, height: Int32, frameRate: Int32) throws {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        var session: VTCompressionSession?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: XiaomiMirrorH264Encoder.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw XiaomiMirrorRTSPDiagnosticSourceError.videoToolboxCreateFailed(status)
        }
        compressionSession = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: frameRate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFTypeRef)
        let bitRate = 500_000 as CFTypeRef
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encodeBlackFrame(index: UInt64) throws {
        guard let session = compressionSession else {
            throw XiaomiMirrorRTSPDiagnosticSourceError.videoToolboxSessionMissing
        }
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(width),
            Int(height),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            throw XiaomiMirrorRTSPDiagnosticSourceError.pixelBufferCreateFailed(createStatus)
        }
        fillBlack(pixelBuffer)
        let pts = CMTime(value: CMTimeValue(index), timescale: frameRate)
        let duration = CMTime(value: 1, timescale: frameRate)
        let options: CFDictionary? = index % UInt64(frameRate) == 0
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: options,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            throw XiaomiMirrorRTSPDiagnosticSourceError.videoToolboxEncodeFailed(status)
        }
    }

    func invalidate() {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
        }
        compressionSession = nil
        onFrame = nil
    }

    private func fillBlack(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        for plane in 0..<planeCount {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                continue
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let value: Int32 = plane == 0 ? 16 : 128
            for row in 0..<rows {
                memset(base.advanced(by: row * bytesPerRow), value, bytesPerRow)
            }
        }
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon else {
            return
        }
        let encoder = Unmanaged<XiaomiMirrorH264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr, let sampleBuffer else {
            DiagnosticsLog.warn("xiaomi.mirror.h264.output_skipped status=\(status)")
            return
        }
        encoder.handle(sampleBuffer)
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }
        let isKeyframe = Self.isKeyframe(sampleBuffer)
        var annexB = Data()
        var nalCount = 0
        if isKeyframe, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            appendParameterSets(from: formatDescription, to: &annexB, nalCount: &nalCount)
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer, totalLength > 0 else {
            DiagnosticsLog.warn("xiaomi.mirror.h264.blockbuffer_skipped status=\(status) totalLength=\(totalLength)")
            return
        }
        let avcc = Data(bytes: dataPointer, count: totalLength)
        var offset = 0
        while offset + nalLengthSize <= avcc.count {
            var nalLength = 0
            for index in 0..<nalLengthSize {
                nalLength = (nalLength << 8) | Int(avcc[offset + index])
            }
            offset += nalLengthSize
            guard nalLength > 0, offset + nalLength <= avcc.count else {
                break
            }
            annexB.appendStartCode()
            annexB.append(avcc.subdata(in: offset..<(offset + nalLength)))
            nalCount += 1
            offset += nalLength
        }
        guard !annexB.isEmpty else {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let pts90k = UInt64(max(0, CMTimeConvertScale(pts, timescale: 90_000, method: .default).value))
        onFrame?(XiaomiMirrorEncodedH264Frame(annexB: annexB, isKeyframe: isKeyframe, pts90k: pts90k, nalCount: nalCount))
    }

    private func appendParameterSets(from formatDescription: CMFormatDescription, to annexB: inout Data, nalCount: inout Int) {
        var parameterSetCount = 0
        var lengthSize: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &lengthSize
        )
        guard countStatus == noErr else {
            return
        }
        nalLengthSize = Int(lengthSize)
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else {
                continue
            }
            annexB.appendStartCode()
            annexB.append(pointer, count: size)
            nalCount += 1
        }
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        return first[kCMSampleAttachmentKey_NotSync] == nil
    }
}

private struct XiaomiMirrorEncodedH264Frame {
    let annexB: Data
    let isKeyframe: Bool
    let pts90k: UInt64
    let nalCount: Int
}

private struct XiaomiMirrorMPEGTSMuxer {
    private let pmtPID: UInt16 = 0x0100
    private let videoPID: UInt16 = 0x0101
    private var continuityCounters: [UInt16: UInt8] = [:]

    mutating func makePackets(frame: Data, pts90k: UInt64, includeProgramInfo: Bool) -> [Data] {
        var packets: [Data] = []
        if includeProgramInfo {
            packets.append(makePATPacket())
            packets.append(makePMTPacket())
        }
        var pes = Data()
        pes.append(contentsOf: [0x00, 0x00, 0x01, 0xe0])
        pes.appendUInt16(0)
        pes.append(0x84)
        pes.append(0x80)
        pes.append(0x05)
        pes.appendPTS(pts90k)
        pes.appendAccessUnitDelimiter()
        pes.append(frame)
        packets.append(contentsOf: packetize(pid: videoPID, payload: pes, payloadUnitStart: true, pcr90k: pts90k))
        return packets
    }

    private mutating func makePATPacket() -> Data {
        var section = Data()
        section.append(0x00)
        section.appendUInt16(0xb000 | 13)
        section.appendUInt16(1)
        section.append(0xc1)
        section.append(0x00)
        section.append(0x00)
        section.appendUInt16(1)
        section.appendUInt16(0xe000 | pmtPID)
        section.appendUInt32(Self.crc32MPEG(section))
        var payload = Data([0x00])
        payload.append(section)
        return packetize(pid: 0x0000, payload: payload, payloadUnitStart: true, pcr90k: nil).first ?? Data()
    }

    private mutating func makePMTPacket() -> Data {
        var section = Data()
        section.append(0x02)
        section.appendUInt16(0xb000 | 18)
        section.appendUInt16(1)
        section.append(0xc1)
        section.append(0x00)
        section.append(0x00)
        section.appendUInt16(0xe000 | videoPID)
        section.appendUInt16(0xf000)
        section.append(0x1b)
        section.appendUInt16(0xe000 | videoPID)
        section.appendUInt16(0xf000)
        section.appendUInt32(Self.crc32MPEG(section))
        var payload = Data([0x00])
        payload.append(section)
        return packetize(pid: pmtPID, payload: payload, payloadUnitStart: true, pcr90k: nil).first ?? Data()
    }

    private mutating func packetize(pid: UInt16, payload: Data, payloadUnitStart: Bool, pcr90k: UInt64?) -> [Data] {
        var packets: [Data] = []
        var offset = 0
        var first = true
        while offset < payload.count {
            let includePCR = first && pcr90k != nil
            let maxPayload = includePCR ? 176 : 184
            let remaining = payload.count - offset
            let payloadCount = min(remaining, maxPayload)
            let chunk = payload.subdata(in: offset..<(offset + payloadCount))
            packets.append(makeTSPacket(
                pid: pid,
                payloadUnitStart: payloadUnitStart && first,
                payload: chunk,
                pcr90k: includePCR ? pcr90k : nil
            ))
            offset += payloadCount
            first = false
        }
        return packets
    }

    private mutating func makeTSPacket(pid: UInt16, payloadUnitStart: Bool, payload: Data, pcr90k: UInt64?) -> Data {
        let continuityCounter = continuityCounters[pid] ?? 0
        continuityCounters[pid] = (continuityCounter + 1) & 0x0f
        let needsAdaptation = pcr90k != nil || payload.count < 184
        var packet = Data(capacity: 188)
        packet.append(0x47)
        packet.append(UInt8((payloadUnitStart ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1f)))
        packet.append(UInt8(pid & 0xff))
        packet.append(UInt8((needsAdaptation ? 0x30 : 0x10) | continuityCounter))
        if needsAdaptation {
            let adaptationLength = 188 - 4 - payload.count - 1
            packet.append(UInt8(adaptationLength))
            if adaptationLength > 0 {
                packet.append(pcr90k == nil ? 0x00 : 0x10)
                var used = 1
                if let pcr90k {
                    packet.appendPCR(pcr90k)
                    used += 6
                }
                if adaptationLength > used {
                    packet.append(Data(repeating: 0xff, count: adaptationLength - used))
                }
            }
        }
        packet.append(payload)
        if packet.count < 188 {
            packet.append(Data(repeating: 0xff, count: 188 - packet.count))
        }
        if packet.count > 188 {
            return packet.prefix(188)
        }
        return packet
    }

    private static func crc32MPEG(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                if (crc & 0x8000_0000) != 0 {
                    crc = (crc &<< 1) ^ 0x04c1_1db7
                } else {
                    crc = crc &<< 1
                }
            }
        }
        return crc
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendStartCode() {
        append(contentsOf: [0x00, 0x00, 0x00, 0x01])
    }

    mutating func appendAccessUnitDelimiter() {
        appendStartCode()
        append(contentsOf: [0x09, 0xf0])
    }

    mutating func appendPTS(_ pts90k: UInt64) {
        let value = pts90k & 0x1_ffff_ffff
        append(UInt8(0x20 | (((value >> 30) & 0x07) << 1) | 0x01))
        append(UInt8((value >> 22) & 0xff))
        append(UInt8((((value >> 15) & 0x7f) << 1) | 0x01))
        append(UInt8((value >> 7) & 0xff))
        append(UInt8(((value & 0x7f) << 1) | 0x01))
    }

    mutating func appendPCR(_ pcr90k: UInt64) {
        let base = pcr90k & 0x1_ffff_ffff
        append(UInt8((base >> 25) & 0xff))
        append(UInt8((base >> 17) & 0xff))
        append(UInt8((base >> 9) & 0xff))
        append(UInt8((base >> 1) & 0xff))
        append(UInt8(((base & 0x01) << 7) | 0x7e))
        append(0x00)
    }
}

private struct RTSPMessage {
    let firstLine: String
    let headers: [String: String]
    let body: String

    var isResponse: Bool {
        firstLine.hasPrefix("RTSP/")
    }

    var method: String? {
        guard !isResponse else {
            return nil
        }
        return firstLine.split(separator: " ").first.map(String.init)
    }

    var cseq: Int? {
        headers["cseq"].flatMap(Int.init)
    }
}

private enum XiaomiMirrorRTSPDiagnosticSourceError: Error {
    case invalidPort(UInt16)
    case pixelBufferCreateFailed(CVReturn)
    case videoToolboxCreateFailed(OSStatus)
    case videoToolboxEncodeFailed(OSStatus)
    case videoToolboxSessionMissing
}
