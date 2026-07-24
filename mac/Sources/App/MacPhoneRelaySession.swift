import Darwin
import EdgeLinkKit
import Foundation
import Network

final class MacPhoneRelaySession {
    var onDownlinkRTPPacket: ((Data) -> Void)?
    var onUplinkDestination: ((String, UInt16) -> Void)?
    var onTeardown: ((String) -> Void)?

    private let queue = DispatchQueue(label: "EdgeLink.MacPhoneRelaySession")
    private var tcpListener: NWListener?
    private let listenerStateLock = NSLock()
    private var tcpListenerReady = false
    private var udpListener: NWListener?
    private var rtpListeners: [UInt16: NWListener] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var tcpStates: [UUID: RelayTCPState] = [:]
    private var udpConnectionPorts: [UUID: UInt16] = [:]
    private var port: UInt16 = 7102
    private var uplinkConnection: NWConnection?
    private var uplinkDestination: (host: String, port: UInt16)?
    private var uplinkArmed = false
    private var uplinkPacketsSent = 0
    private var downlinkPacketsReceived = 0

    private let sinkRTPPort: UInt16 = 19_000
    private let sourceRTPPort: UInt16 = 19_002
    private var rtpListenPorts: [UInt16] {
        [sinkRTPPort, sinkRTPPort + 1, sourceRTPPort + 1]
    }

    func start(port: UInt16 = 7102) throws {
        stop(reason: "restart")
        listenerStateLock.withLock {
            tcpListenerReady = false
        }
        self.port = port
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw MacPhoneRelaySessionError.invalidPort(port)
        }
        let tcpParameters = NWParameters.tcp
        tcpParameters.allowLocalEndpointReuse = true
        let udpParameters = NWParameters.udp
        udpParameters.allowLocalEndpointReuse = true

        let tcp = try NWListener(using: tcpParameters, on: endpointPort)
        let udp = try NWListener(using: udpParameters, on: endpointPort)
        var rtpListeners: [UInt16: NWListener] = [:]
        for rtpPort in rtpListenPorts {
            guard let rtpEndpointPort = NWEndpoint.Port(rawValue: rtpPort) else {
                throw MacPhoneRelaySessionError.invalidPort(rtpPort)
            }
            rtpListeners[rtpPort] = try NWListener(using: udpParameters, on: rtpEndpointPort)
        }
        tcpListener = tcp
        udpListener = udp
        self.rtpListeners = rtpListeners

        configureTCPListener(tcp)
        configureUDPListener(udp)
        for (rtpPort, listener) in rtpListeners {
            configureRTPListener(listener, port: rtpPort)
        }

        DiagnosticsLog.info("phonerelay.mac.session_start port=\(port)")
        tcp.start(queue: queue)
        udp.start(queue: queue)
        for listener in rtpListeners.values {
            listener.start(queue: queue)
        }
    }

    func stop(reason: String) {
        let hadActiveSession = tcpListener != nil || udpListener != nil || !rtpListeners.isEmpty || !connections.isEmpty
        listenerStateLock.withLock {
            tcpListenerReady = false
        }
        tcpListener?.cancel()
        udpListener?.cancel()
        for listener in rtpListeners.values {
            listener.cancel()
        }
        tcpListener = nil
        udpListener = nil
        rtpListeners.removeAll()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        tcpStates.removeAll()
        udpConnectionPorts.removeAll()
        uplinkConnection?.cancel()
        uplinkConnection = nil
        uplinkDestination = nil
        uplinkArmed = false
        if hadActiveSession {
            DiagnosticsLog.info(
                "phonerelay.mac.session_stop reason=\(reason) uplinkPackets=\(uplinkPacketsSent) " +
                    "downlinkPackets=\(downlinkPacketsReceived)"
            )
        }
        uplinkPacketsSent = 0
        downlinkPacketsReceived = 0
    }

    func isTCPListenerReady() -> Bool {
        listenerStateLock.withLock { tcpListenerReady }
    }

    var hasUplinkDestination: Bool {
        queue.sync {
            uplinkDestination != nil
        }
    }

    func setUplinkActive(_ active: Bool) {
        queue.async {
            self.uplinkArmed = active
            if !active {
                self.uplinkConnection?.cancel()
                self.uplinkConnection = nil
            } else {
                self.ensureUplinkConnection(reason: "armed")
            }
            DiagnosticsLog.info("phonerelay.mac.session_uplink_armed active=\(active)")
        }
    }

    func sendUplinkRTP(_ packet: Data) {
        queue.async {
            guard self.uplinkArmed else {
                return
            }
            guard let connection = self.ensureUplinkConnection(reason: "send") else {
                return
            }
            self.uplinkPacketsSent += 1
            let count = self.uplinkPacketsSent
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    DiagnosticsLog.warn("phonerelay.mac.session_uplink_send_failed count=\(count) error=\(error)")
                }
            })
            if count <= 3 || count % 250 == 0 {
                DiagnosticsLog.info(
                    "phonerelay.mac.session_uplink_packet count=\(count) bytes=\(packet.count)"
                )
            }
        }
    }

    private func ensureUplinkConnection(reason: String) -> NWConnection? {
        if let uplinkConnection {
            return uplinkConnection
        }
        guard uplinkArmed, let destination = uplinkDestination,
              let remotePort = NWEndpoint.Port(rawValue: destination.port),
              let localPort = NWEndpoint.Port(rawValue: sourceRTPPort),
              let anyIPv4 = IPv4Address("0.0.0.0") else {
            return nil
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(anyIPv4), port: localPort)
        let connection = NWConnection(host: NWEndpoint.Host(destination.host), port: remotePort, using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                DiagnosticsLog.info(
                    "phonerelay.mac.session_uplink_ready localPort=19002 remote=\(destination.host):\(destination.port) reason=\(reason)"
                )
            case .failed(let error):
                DiagnosticsLog.warn("phonerelay.mac.session_uplink_failed error=\(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        uplinkConnection = connection
        return connection
    }

    private func configureTCPListener(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else {
                return
            }
            self.handleListenerState("tcp", port: self.port, state, isCurrentTCPListener: self.tcpListener === listener)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptTCPConnection(connection)
        }
    }

    private func configureUDPListener(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState("udp", port: self?.port, state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                return
            }
            self.acceptUDPConnection(connection, listenerPort: self.port)
        }
    }

    private func configureRTPListener(_ listener: NWListener, port: UInt16) {
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState("rtp_udp", port: port, state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptUDPConnection(connection, listenerPort: port)
        }
    }

    private func handleListenerState(
        _ proto: String,
        port listenerPort: UInt16?,
        _ state: NWListener.State,
        isCurrentTCPListener: Bool = false
    ) {
        let listenerPortText = listenerPort.map(String.init) ?? "unknown"
        switch state {
        case .ready:
            if isCurrentTCPListener {
                listenerStateLock.withLock {
                    tcpListenerReady = true
                }
            }
            DiagnosticsLog.info("phonerelay.mac.session_listener_ready proto=\(proto) port=\(listenerPortText)")
        case .failed(let error):
            if isCurrentTCPListener {
                listenerStateLock.withLock {
                    tcpListenerReady = false
                }
            }
            DiagnosticsLog.warn("phonerelay.mac.session_listener_failed proto=\(proto) port=\(listenerPortText) error=\(error)")
        case .cancelled:
            if isCurrentTCPListener {
                listenerStateLock.withLock {
                    tcpListenerReady = false
                }
            }
        default:
            break
        }
    }

    private func acceptTCPConnection(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        tcpStates[id] = RelayTCPState()
        DiagnosticsLog.info("phonerelay.mac.session_connection proto=tcp id=\(id.uuidString) remote=\(connection.endpoint)")
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState("tcp", id: id, endpoint: connection.endpoint, state: state, connection: connection)
        }
        connection.start(queue: queue)
        receiveTCP(connection, id: id)
    }

    private func acceptUDPConnection(_ connection: NWConnection, listenerPort: UInt16) {
        let id = UUID()
        connections[id] = connection
        udpConnectionPorts[id] = listenerPort
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState("udp", id: id, endpoint: connection.endpoint, state: state, connection: connection)
        }
        connection.start(queue: queue)
        receiveUDP(connection, id: id)
    }

    private func handleConnectionState(
        _ proto: String,
        id: UUID,
        endpoint: NWEndpoint,
        state: NWConnection.State,
        connection: NWConnection
    ) {
        switch state {
        case .ready:
            DiagnosticsLog.info("phonerelay.mac.session_connection_ready proto=\(proto) id=\(id.uuidString) remote=\(endpoint)")
            if proto == "tcp" {
                sendRTSPOptionsIfNeeded(connection: connection, id: id, reason: "ready")
            }
        case .failed(let error):
            DiagnosticsLog.warn("phonerelay.mac.session_connection_failed proto=\(proto) id=\(id.uuidString) error=\(error)")
            connections[id] = nil
            tcpStates[id] = nil
            udpConnectionPorts[id] = nil
        case .cancelled:
            connections[id] = nil
            tcpStates[id] = nil
            udpConnectionPorts[id] = nil
        default:
            break
        }
    }

    private func receiveTCP(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.processTCPData(connection: connection, id: id, data: data)
            }
            if error != nil || isComplete {
                connection.cancel()
                self.connections[id] = nil
                self.tcpStates[id] = nil
                return
            }
            self.receiveTCP(connection, id: id)
        }
    }

    private func receiveUDP(_ connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty,
               let listenerPort = self.udpConnectionPorts[id],
               listenerPort == self.sinkRTPPort {
                self.downlinkPacketsReceived += 1
                let count = self.downlinkPacketsReceived
                if count <= 3 || count % 250 == 0 {
                    DiagnosticsLog.info(
                        "phonerelay.mac.session_downlink_rtp count=\(count) bytes=\(data.count)"
                    )
                }
                self.onDownlinkRTPPacket?(data)
            }
            if error != nil {
                self.connections[id] = nil
                self.udpConnectionPorts[id] = nil
                return
            }
            self.receiveUDP(connection, id: id)
        }
    }

    private func processTCPData(connection: NWConnection, id: UUID, data: Data) {
        var state = tcpStates[id] ?? RelayTCPState()
        state.buffer.append(data)
        let delimiter = Data("\r\n\r\n".utf8)

        while let headerRange = state.buffer.range(of: delimiter) {
            let headerData = Data(state.buffer[..<headerRange.upperBound])
            let headerText = String(data: headerData, encoding: .isoLatin1) ?? ""
            let contentLength = rtspHeader("Content-Length", in: headerText).flatMap { Int($0) } ?? 0
            let messageEnd = headerRange.upperBound + max(contentLength, 0)
            guard state.buffer.count >= messageEnd else {
                break
            }
            let messageData = Data(state.buffer[..<messageEnd])
            state.buffer.removeSubrange(..<messageEnd)
            tcpStates[id] = state
            handleRTSPMessage(connection: connection, id: id, data: messageData)
            state = tcpStates[id] ?? state
        }

        tcpStates[id] = state
    }

    private func handleRTSPMessage(connection: NWConnection, id: UUID, data: Data) {
        guard let text = String(data: data, encoding: .isoLatin1) else {
            return
        }
        let headerText = text.components(separatedBy: "\r\n\r\n").first ?? text
        let bodyText = rtspBody(in: text)
        let firstLine = headerText.components(separatedBy: "\r\n").first ?? "<empty>"
        let cseq = rtspHeader("CSeq", in: headerText) ?? "?"
        DiagnosticsLog.info(
            "phonerelay.mac.session_rtsp dir=in id=\(id.uuidString) firstLine=\(sanitize(firstLine)) cseq=\(sanitize(cseq))"
        )
        if firstLine.uppercased().hasPrefix("RTSP/") {
            handleRTSPResponse(connection: connection, id: id, headerText: headerText, bodyText: bodyText, cseq: cseq)
        } else if let method = rtspRequestMethod(firstLine), cseq != "?" {
            handleRTSPRequest(
                method: method,
                firstLine: firstLine,
                headerText: headerText,
                bodyText: bodyText,
                connection: connection,
                id: id,
                cseq: cseq
            )
        }
    }

    private func handleRTSPRequest(
        method: String,
        firstLine: String,
        headerText: String,
        bodyText: String,
        connection: NWConnection,
        id: UUID,
        cseq: String
    ) {
        switch method {
        case "OPTIONS":
            sendRTSPResponse(
                connection: connection,
                id: id,
                cseq: cseq,
                headers: [
                    ("Public", "org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER"),
                    ("fastRTSPVersion", "0")
                ]
            )
            sendRTSPOptionsIfNeeded(connection: connection, id: id, reason: "peer_options")
            sendSourceGETParameterIfNeeded(connection: connection, id: id, reason: "peer_options")
        case "GET_PARAMETER":
            sendRTSPResponse(
                connection: connection,
                id: id,
                cseq: cseq,
                headers: [("Content-Type", "text/parameters")],
                body: wfdParameterResponseBody(requestBody: bodyText)
            )
        case "SET_PARAMETER":
            recordPresentationURL(from: bodyText, id: id)
            sendRTSPResponse(connection: connection, id: id, cseq: cseq)
            if bodyText.localizedCaseInsensitiveContains("wfd_trigger_method: SETUP") {
                sendSinkSETUPIfNeeded(connection: connection, id: id, reason: "trigger_setup")
            }
            if bodyText.localizedCaseInsensitiveContains("wfd_trigger_method: TEARDOWN") {
                onTeardown?("trigger_teardown")
            }
        case "SETUP":
            recordUplinkDestination(fromTransport: headerText, connection: connection, id: id)
            let session = ensureSessionID(for: id)
            sendRTSPResponse(
                connection: connection,
                id: id,
                cseq: cseq,
                headers: [
                    ("Session", session),
                    ("Transport", setupResponseTransport(requestHeaderText: headerText))
                ]
            )
        case "PLAY":
            sendRTSPResponse(connection: connection, id: id, cseq: cseq)
        case "PAUSE":
            sendRTSPResponse(connection: connection, id: id, cseq: cseq)
            onTeardown?("pause_request")
        case "TEARDOWN":
            sendRTSPResponse(connection: connection, id: id, cseq: cseq)
            onTeardown?("teardown_request")
        default:
            sendRTSPResponse(connection: connection, id: id, cseq: cseq)
        }
    }

    private func handleRTSPResponse(
        connection: NWConnection,
        id: UUID,
        headerText: String,
        bodyText: String,
        cseq: String
    ) {
        var state = tcpStates[id] ?? RelayTCPState()
        let requestMethod = state.pendingRequests.removeValue(forKey: cseq)
        if let session = rtspHeader("Session", in: headerText)?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces),
           !session.isEmpty {
            state.sessionID = session
        }
        tcpStates[id] = state

        let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
        if let status = rtspStatusCode(in: firstLine), status >= 300 {
            // The peer sink currently rejects source-side SETUP/PLAY but still
            // consumes the uplink RTP stream; treat non-success as non-fatal.
            DiagnosticsLog.info(
                "phonerelay.mac.session_rtsp_non_success id=\(id.uuidString) request=\(requestMethod ?? "none") " +
                    "status=\(status)"
            )
        }

        switch requestMethod {
        case "GET_PARAMETER":
            recordUplinkDestination(fromWFDParameters: bodyText, connection: connection, id: id)
            sendSourceSETParameterIfNeeded(connection: connection, id: id, reason: "get_parameter_response")
        case "SET_PARAMETER":
            sendSourceSETUPIfNeeded(connection: connection, id: id, reason: "set_parameter_response")
        case "SETUP":
            sendSourcePLAYIfNeeded(connection: connection, id: id, reason: "setup_response")
        default:
            break
        }
    }

    private func rtspRequestMethod(_ firstLine: String) -> String? {
        guard firstLine.uppercased().hasSuffix(" RTSP/1.0") else {
            return nil
        }
        return firstLine.components(separatedBy: " ").first?.uppercased()
    }

    private func rtspStatusCode(in firstLine: String) -> Int? {
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2,
              String(parts[0]).uppercased().hasPrefix("RTSP/") else {
            return nil
        }
        return Int(parts[1])
    }

    private func sendRTSPOptionsIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? RelayTCPState()
        guard !state.sentGreeting else {
            return
        }
        state.sentGreeting = true
        tcpStates[id] = state
        sendRTSPRequest(
            method: "OPTIONS",
            uri: "*",
            connection: connection,
            id: id,
            headers: [
                ("Require", "org.wfa.wfd1.0"),
                ("lib_version", "edgelink_relay"),
                ("fastRTSPVersion", "0")
            ],
            label: "options_\(reason)"
        )
    }

    private func sendSourceGETParameterIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? RelayTCPState()
        guard !state.sentSourceGETParameter else {
            return
        }
        state.sentSourceGETParameter = true
        tcpStates[id] = state
        let body = """
        wfd_audio_codecs\r
        wfd_client_rtp_ports\r
        wfd_content_protection\r
        wfd_content_SP_protection\r
        wfd_mirror_control_enable\r
        """
        sendRTSPRequest(
            method: "GET_PARAMETER",
            uri: "rtsp://localhost/wfd1.0",
            connection: connection,
            id: id,
            headers: [("Content-Type", "text/parameters")],
            body: body,
            label: "get_parameter_\(reason)"
        )
    }

    private func sendSourceSETParameterIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? RelayTCPState()
        guard !state.sentSourceSETParameter else {
            return
        }
        state.sentSourceSETParameter = true
        tcpStates[id] = state
        let body = """
        wfd_presentation_URL: \(sourcePresentationURL()) none\r
        wfd_platform_type: 2\r
        wfd_trigger_method: SETUP\r
        """
        sendRTSPRequest(
            method: "SET_PARAMETER",
            uri: "rtsp://localhost/wfd1.0",
            connection: connection,
            id: id,
            headers: [("Content-Type", "text/parameters")],
            body: body,
            label: "set_parameter_\(reason)"
        )
    }

    private func sendSourceSETUPIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? RelayTCPState()
        guard state.sentSourceSETParameter,
              !state.sentSourceSETUP else {
            return
        }
        guard let rtpPort = uplinkDestination?.port ?? state.sourceRemoteRTPPort else {
            DiagnosticsLog.warn("phonerelay.mac.session_source_setup_missing_destination id=\(id.uuidString) reason=\(reason)")
            return
        }
        state.sentSourceSETUP = true
        tcpStates[id] = state
        sendRTSPRequest(
            method: "SETUP",
            uri: sourcePresentationURL(),
            connection: connection,
            id: id,
            headers: [("Transport", "RTP/AVP/UDP;unicast;client_port=\(rtpPort)-\(rtpPort + 1)")],
            label: "source_setup_\(reason)"
        )
    }

    private func sendSourcePLAYIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? RelayTCPState()
        guard state.sentSourceSETUP,
              !state.sentSourcePLAY else {
            return
        }
        state.sentSourcePLAY = true
        let session = state.sessionID
        tcpStates[id] = state
        var headers: [(String, String)] = []
        if let session, !session.isEmpty {
            headers.append(("Session", session))
        }
        sendRTSPRequest(
            method: "PLAY",
            uri: sourcePresentationURL(),
            connection: connection,
            id: id,
            headers: headers,
            label: "source_play_\(reason)"
        )
    }

    private func sendSinkSETUPIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? RelayTCPState()
        guard !state.sentSinkSETUP else {
            return
        }
        state.sentSinkSETUP = true
        let uri = state.presentationURL ?? "rtsp://localhost/wfd1.0/streamid=0"
        tcpStates[id] = state
        sendRTSPRequest(
            method: "SETUP",
            uri: uri,
            connection: connection,
            id: id,
            headers: [("Transport", "RTP/AVP/UDP;unicast;client_port=\(sinkRTPPort)-\(sinkRTPPort + 1)")],
            label: "sink_setup_\(reason)"
        )
    }

    private func sendRTSPResponse(
        connection: NWConnection,
        id: UUID,
        cseq: String,
        headers: [(String, String)] = [],
        body: String? = nil
    ) {
        var responseHeaders: [(String, String)] = [
            ("Date", rtspDate()),
            ("User-Agent", "EdgeLinkMac"),
            ("CSeq", cseq)
        ]
        responseHeaders.append(contentsOf: headers)
        let message = buildRTSPMessage(firstLine: "RTSP/1.0 200 OK", headers: responseHeaders, body: body)
        sendRTSP(message, connection: connection, id: id, label: "response")
    }

    private func sendRTSPRequest(
        method: String,
        uri: String,
        connection: NWConnection,
        id: UUID,
        headers: [(String, String)] = [],
        body: String? = nil,
        label: String
    ) {
        let cseq = reserveCSeq(for: id, method: method)
        var requestHeaders: [(String, String)] = [
            ("Date", rtspDate()),
            ("Server", "EdgeLinkMac"),
            ("CSeq", cseq)
        ]
        requestHeaders.append(contentsOf: headers)
        let message = buildRTSPMessage(firstLine: "\(method) \(uri) RTSP/1.0", headers: requestHeaders, body: body)
        sendRTSP(message, connection: connection, id: id, label: label)
    }

    private func buildRTSPMessage(firstLine: String, headers: [(String, String)], body: String?) -> String {
        var lines = [firstLine]
        var finalHeaders = headers
        if let body {
            finalHeaders.append(("Content-Length", "\(body.data(using: .utf8)?.count ?? 0)"))
        }
        for (name, value) in finalHeaders {
            lines.append("\(name): \(value)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + (body ?? "")
    }

    private func reserveCSeq(for id: UUID, method: String) -> String {
        var state = tcpStates[id] ?? RelayTCPState()
        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.pendingRequests["\(cseq)"] = method
        tcpStates[id] = state
        return "\(cseq)"
    }

    private func sendRTSP(_ message: String, connection: NWConnection, id: UUID, label: String) {
        guard let data = message.data(using: .utf8) else {
            return
        }
        DiagnosticsLog.info(
            "phonerelay.mac.session_rtsp dir=out id=\(id.uuidString) " +
                "firstLine=\(sanitize(message.components(separatedBy: "\r\n").first ?? label))"
        )
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.warn("phonerelay.mac.session_rtsp_send_failed id=\(id.uuidString) label=\(label) error=\(error)")
            }
        })
    }

    private func wfdParameterResponseBody(requestBody: String) -> String {
        let requestedNames = Set(
            requestBody
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { $0.components(separatedBy: ":").first ?? $0 }
        )
        let parameters: [(String, String)] = [
            ("wfd_video_formats", "none"),
            ("wfd_video_bitrate", "none"),
            ("wfd_video_enctype", "none"),
            ("wfd_video_gamuttype", "none"),
            ("wfd_current_video_info", "none"),
            ("wfd_audio_codecs", "AAC 00000001 00"),
            ("audio_sample_time_ms", "20"),
            ("wfd_client_rtp_ports", "RTP/AVP/UDP;unicast \(sinkRTPPort) 0 mode=play"),
            ("wfd_content_protection", "none"),
            ("wfd_content_SP_protection", "0 0 0 0 0 0 0 0"),
            ("wfd_mirror_control_enable", "enable"),
            ("wfd_support_secure_win", "enable"),
            ("wfd_standby_resume_capability", "supported"),
            ("wfd_mpt_enable", "none"),
            ("wfd_tcp_enable", "none"),
            ("wfd_tcp_multi_session_enable", "none"),
            ("wfd_image_enable_v2", "none"),
            ("wfd_slice_codec", "none"),
            ("wfd_delay_test_enable", "enable"),
            ("wfd_connector_type", "07")
        ]
        let lines = parameters.compactMap { name, value -> String? in
            let isLegacyAudioFallback = name == "wfd_audio_codecs" && requestedNames.contains("wfd_audio_codecs_v2")
            if requestedNames.isEmpty || requestedNames.contains(name) || isLegacyAudioFallback {
                return "\(name): \(value)"
            }
            return nil
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func recordPresentationURL(from bodyText: String, id: UUID) {
        guard let line = bodyText.components(separatedBy: .newlines).first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("wfd_presentation_url:")
        }) else {
            return
        }
        let value = line.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
        let url = value.components(separatedBy: .whitespaces).first
        guard let url, !url.isEmpty else {
            return
        }
        var state = tcpStates[id] ?? RelayTCPState()
        state.presentationURL = url
        tcpStates[id] = state
    }

    private func recordUplinkDestination(fromTransport headerText: String, connection: NWConnection, id: UUID) {
        guard let transport = rtspHeader("Transport", in: headerText),
              let clientPort = rtspTransportValue("client_port", in: transport),
              let rtpPort = firstRTPPort(in: clientPort),
              let host = endpointHostString(connection.endpoint) else {
            return
        }
        setUplinkDestination(host: host, port: rtpPort, id: id, source: "transport")
    }

    private func recordUplinkDestination(fromWFDParameters bodyText: String, connection: NWConnection, id: UUID) {
        guard let line = bodyText.components(separatedBy: .newlines).first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("wfd_client_rtp_ports:")
        }),
              let value = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init),
              let rtpPort = firstRTPPortToken(in: value),
              let host = endpointHostString(connection.endpoint) else {
            DiagnosticsLog.warn("phonerelay.mac.session_uplink_destination_missing id=\(id.uuidString)")
            return
        }
        setUplinkDestination(host: host, port: rtpPort, id: id, source: "wfd_client_rtp_ports")
    }

    private func setUplinkDestination(host: String, port: UInt16, id: UUID, source: String) {
        var state = tcpStates[id] ?? RelayTCPState()
        state.sourceRemoteHost = host
        state.sourceRemoteRTPPort = port
        tcpStates[id] = state
        if uplinkDestination?.host != host || uplinkDestination?.port != port {
            uplinkDestination = (host, port)
            uplinkConnection?.cancel()
            uplinkConnection = nil
            DiagnosticsLog.info(
                "phonerelay.mac.session_uplink_destination id=\(id.uuidString) remote=\(host):\(port) source=\(source)"
            )
            onUplinkDestination?(host, port)
        }
        if uplinkArmed {
            ensureUplinkConnection(reason: "destination_\(source)")
        }
    }

    private func firstRTPPortToken(in value: String) -> UInt16? {
        let normalized = value.replacingOccurrences(of: ";", with: " ")
        for rawToken in normalized.split(whereSeparator: { $0.isWhitespace }) {
            let firstValue = rawToken.split(separator: "-").first ?? rawToken[...]
            if let port = UInt16(firstValue), port > 0 {
                return port
            }
        }
        return nil
    }

    private func firstRTPPort(in value: String) -> UInt16? {
        let first = value
            .split(separator: "-")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first,
              let port = UInt16(first),
              port > 0 else {
            return nil
        }
        return port
    }

    private func endpointHostString(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else {
            return nil
        }
        return String(describing: host)
    }

    private func sourcePresentationHost() -> String {
        MiLinkPhoneRelayProbe.preferredLocalIPv4Address() ?? "localhost"
    }

    private func sourcePresentationURL() -> String {
        "rtsp://\(sourcePresentationHost())/wfd1.0/streamid=0"
    }

    private func ensureSessionID(for id: UUID) -> String {
        var state = tcpStates[id] ?? RelayTCPState()
        if let sessionID = state.sessionID, !sessionID.isEmpty {
            return sessionID
        }
        let sessionID = String(abs(id.uuidString.hashValue))
        state.sessionID = sessionID
        tcpStates[id] = state
        return sessionID
    }

    private func setupResponseTransport(requestHeaderText: String) -> String {
        let transport = rtspHeader("Transport", in: requestHeaderText) ?? "RTP/AVP/UDP;unicast"
        let clientPort = rtspTransportValue("client_port", in: transport)
        if let clientPort, !clientPort.isEmpty {
            return "RTP/AVP/UDP;unicast;client_port=\(clientPort);server_port=\(sourceRTPPort)-\(sourceRTPPort + 1)"
        }
        return "RTP/AVP/UDP;unicast;server_port=\(sourceRTPPort)-\(sourceRTPPort + 1)"
    }

    private func rtspTransportValue(_ name: String, in transport: String) -> String? {
        let prefix = name.lowercased() + "="
        for component in transport.components(separatedBy: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private func rtspHeader(_ name: String, in headerText: String) -> String? {
        let prefix = name.lowercased() + ":"
        for line in headerText.components(separatedBy: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func rtspBody(in text: String) -> String {
        guard let range = text.range(of: "\r\n\r\n") else {
            return ""
        }
        return String(text[range.upperBound...])
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .prefix(120)
            .description
    }

    private func rtspDate() -> String {
        Self.rtspDateFormatter.string(from: Date())
    }

    private static let rtspDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}

private struct RelayTCPState {
    var buffer = Data()
    var sentGreeting = false
    var nextCSeq = 1
    var pendingRequests: [String: String] = [:]
    var presentationURL: String?
    var sessionID: String?
    var sourceRemoteHost: String?
    var sourceRemoteRTPPort: UInt16?
    var sentSourceGETParameter = false
    var sentSourceSETParameter = false
    var sentSourceSETUP = false
    var sentSourcePLAY = false
    var sentSinkSETUP = false
}

private enum MacPhoneRelaySessionError: Error {
    case invalidPort(UInt16)
}
