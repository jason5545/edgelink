import Foundation
import Network

final class MiLinkPhoneRelayProbe {
    var onStatusChanged: ((String) -> Void)?

    private let queue = DispatchQueue(label: "EdgeLink.MiLinkPhoneRelayProbe")
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var rtpListeners: [UInt16: NWListener] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var tcpStates: [UUID: TCPConnectionState] = [:]
    private var udpConnectionPorts: [UUID: UInt16] = [:]
    private var rtpPacketCounts: [UInt16: Int] = [:]
    private var mpegTSPlayerProcess: Process?
    private var mpegTSPlayerInput: FileHandle?
    private var mpegTSPlayerDevNull: FileHandle?
    private var mpegTSBytesWritten = 0
    private var mpegTSCaptureHandle: FileHandle?
    private var mpegTSCaptureBytes = 0
    private var mpegTSCaptureLimitLogged = false
    private var peerSourceHost: String?
    private var peerSourcePort: UInt16 = 7102
    private var peerSourceConnectionID: UUID?
    private var peerSourceRetryWorkItem: DispatchWorkItem?
    private var peerSourceRetryAttempt = 0
    private var port: UInt16 = 7102
    private let sinkRTPPort: UInt16 = 19_000
    private let sourceRTPPort: UInt16 = 19_002
    private var rtpProbePorts: [UInt16] {
        [sinkRTPPort, sinkRTPPort + 1, sourceRTPPort, sourceRTPPort + 1]
    }

    func start(port: UInt16 = 7102, peerHost: String? = nil, peerPort: UInt16 = 7102) throws {
        stop()
        self.port = port
        let trimmedPeerHost = peerHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedPeerHost, !trimmedPeerHost.isEmpty {
            peerSourceHost = trimmedPeerHost
            peerSourcePort = peerPort
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw MiLinkPhoneRelayProbeError.invalidPort(port)
        }

        let tcpParameters = NWParameters.tcp
        tcpParameters.allowLocalEndpointReuse = true
        let udpParameters = NWParameters.udp
        udpParameters.allowLocalEndpointReuse = true

        let tcp = try NWListener(using: tcpParameters, on: endpointPort)
        let udp = try NWListener(using: udpParameters, on: endpointPort)
        var rtpListeners: [UInt16: NWListener] = [:]
        for rtpPort in rtpProbePorts {
            guard let endpointPort = NWEndpoint.Port(rawValue: rtpPort) else {
                throw MiLinkPhoneRelayProbeError.invalidPort(rtpPort)
            }
            rtpListeners[rtpPort] = try NWListener(using: udpParameters, on: endpointPort)
        }
        tcpListener = tcp
        udpListener = udp
        self.rtpListeners = rtpListeners

        configureTCPListener(tcp)
        configureUDPListener(udp)
        for (rtpPort, listener) in rtpListeners {
            configureRTPListener(listener, port: rtpPort)
        }

        DiagnosticsLog.info("phonerelay.mac.probe_start port=\(port) rtpPorts=\(rtpProbePorts.map(String.init).joined(separator: ","))")
        onStatusChanged?("PHONERELAY RTSP \(port) RTP \(sinkRTPPort)-\(sinkRTPPort + 1)")
        tcp.start(queue: queue)
        udp.start(queue: queue)
        for listener in rtpListeners.values {
            listener.start(queue: queue)
        }

        if let peerSourceHost {
            connectPeerSource(host: peerSourceHost, port: peerSourcePort, reason: "start")
        }
    }

    func stop() {
        let hadActiveProbe = tcpListener != nil || udpListener != nil || !rtpListeners.isEmpty || !connections.isEmpty
        let activePort = port
        peerSourceHost = nil
        peerSourceConnectionID = nil
        peerSourceRetryWorkItem?.cancel()
        peerSourceRetryWorkItem = nil
        peerSourceRetryAttempt = 0
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
        rtpPacketCounts.removeAll()
        stopMPEGTSPlayer(reason: "probe_stop")
        stopMPEGTSFileCapture(reason: "probe_stop")
        if hadActiveProbe {
            DiagnosticsLog.info("phonerelay.mac.probe_stop port=\(activePort)")
            onStatusChanged?("")
        }
    }

    private func configureTCPListener(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState("tcp", port: self?.port, state)
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

    private func handleListenerState(_ proto: String, port listenerPort: UInt16?, _ state: NWListener.State) {
        let listenerPortText = listenerPort.map(String.init) ?? "unknown"
        switch state {
        case .ready:
            DiagnosticsLog.info("phonerelay.mac.probe_listener_ready proto=\(proto) port=\(listenerPortText)")
        case .failed(let error):
            DiagnosticsLog.warn("phonerelay.mac.probe_listener_failed proto=\(proto) port=\(listenerPortText) error=\(error)")
            onStatusChanged?("PHONERELAY \(proto) failed")
        case .cancelled:
            DiagnosticsLog.info("phonerelay.mac.probe_listener_cancelled proto=\(proto) port=\(listenerPortText)")
        default:
            break
        }
    }

    private func acceptTCPConnection(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        tcpStates[id] = TCPConnectionState(sendsGreetingOnReady: true, isPeerSourceConnection: false)
        DiagnosticsLog.info("phonerelay.mac.probe_connection proto=tcp id=\(id.uuidString) remote=\(connection.endpoint)")
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
        DiagnosticsLog.info(
            "phonerelay.mac.probe_connection proto=udp id=\(id.uuidString) " +
                "localPort=\(listenerPort) remote=\(connection.endpoint)"
        )
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState("udp", id: id, endpoint: connection.endpoint, state: state, connection: connection)
        }
        connection.start(queue: queue)
        receiveUDP(connection, id: id)
    }

    private func connectPeerSource(host: String, port: UInt16, reason: String) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            DiagnosticsLog.warn("phonerelay.mac.probe_peer_invalid_port host=\(host) port=\(port)")
            return
        }
        peerSourceRetryWorkItem?.cancel()
        peerSourceRetryWorkItem = nil
        let id = UUID()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        connections[id] = connection
        tcpStates[id] = TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: true)
        peerSourceConnectionID = id
        DiagnosticsLog.info(
            "phonerelay.mac.probe_connect_start proto=tcp id=\(id.uuidString) remote=\(host):\(port) " +
                "reason=\(reason)"
        )
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState("tcp", id: id, endpoint: connection.endpoint, state: state, connection: connection)
        }
        connection.start(queue: queue)
        receiveTCP(connection, id: id)
    }

    private func handleConnectionState(
        _ proto: String,
        id: UUID,
        endpoint: NWEndpoint,
        state: NWConnection.State,
        connection: NWConnection
    ) {
        let isPeerSourceConnection = tcpStates[id]?.isPeerSourceConnection == true
        switch state {
        case .ready:
            DiagnosticsLog.info("phonerelay.mac.probe_connection_ready proto=\(proto) id=\(id.uuidString) remote=\(endpoint)")
            if isPeerSourceConnection {
                peerSourceRetryAttempt = 0
                peerSourceRetryWorkItem?.cancel()
                peerSourceRetryWorkItem = nil
            }
            if proto == "tcp" {
                sendRTSPOptionsIfNeeded(connection: connection, id: id, reason: "ready")
            }
        case .failed(let error):
            DiagnosticsLog.warn("phonerelay.mac.probe_connection_failed proto=\(proto) id=\(id.uuidString) error=\(error)")
            if isPeerSourceConnection {
                markPeerSourceDisconnected(id: id, reason: "state_failed")
            }
            connections[id] = nil
            tcpStates[id] = nil
            udpConnectionPorts[id] = nil
        case .cancelled:
            DiagnosticsLog.info("phonerelay.mac.probe_connection_cancelled proto=\(proto) id=\(id.uuidString)")
            if isPeerSourceConnection {
                markPeerSourceDisconnected(id: id, reason: "state_cancelled")
            }
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
                self.logPacket(proto: "tcp", id: id, data: data, complete: isComplete)
                self.processTCPData(connection: connection, id: id, data: data)
            }
            if let error {
                DiagnosticsLog.warn("phonerelay.mac.probe_receive_failed proto=tcp id=\(id.uuidString) error=\(error)")
                if self.tcpStates[id]?.isPeerSourceConnection == true {
                    self.markPeerSourceDisconnected(id: id, reason: "receive_failed")
                }
                connection.cancel()
                self.connections[id] = nil
                self.tcpStates[id] = nil
                return
            }
            if isComplete {
                DiagnosticsLog.info("phonerelay.mac.probe_receive_complete proto=tcp id=\(id.uuidString)")
                if self.tcpStates[id]?.isPeerSourceConnection == true {
                    self.markPeerSourceDisconnected(id: id, reason: "receive_complete")
                }
                connection.cancel()
                self.connections[id] = nil
                self.tcpStates[id] = nil
                return
            }
            self.receiveTCP(connection, id: id)
        }
    }

    private func markPeerSourceDisconnected(id: UUID, reason: String) {
        guard peerSourceConnectionID == id else {
            return
        }
        peerSourceConnectionID = nil
        schedulePeerSourceRetry(reason: reason)
    }

    private func schedulePeerSourceRetry(reason: String) {
        guard let peerSourceHost else {
            return
        }
        peerSourceRetryWorkItem?.cancel()
        peerSourceRetryAttempt += 1
        let attempt = peerSourceRetryAttempt
        let host = peerSourceHost
        let port = peerSourcePort
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.peerSourceHost == host, self.peerSourcePort == port else {
                return
            }
            self.connectPeerSource(host: host, port: port, reason: "retry_\(attempt)")
        }
        peerSourceRetryWorkItem = workItem
        DiagnosticsLog.info(
            "phonerelay.mac.probe_connect_retry_scheduled remote=\(host):\(port) " +
                "attempt=\(attempt) delayMs=\(Self.peerSourceRetryDelayMilliseconds) reason=\(reason)"
        )
        queue.asyncAfter(deadline: .now() + .milliseconds(Self.peerSourceRetryDelayMilliseconds), execute: workItem)
    }

    private func receiveUDP(_ connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                if let listenerPort = self.udpConnectionPorts[id], self.rtpProbePorts.contains(listenerPort) {
                    self.logRTPPacket(port: listenerPort, id: id, data: data, complete: isComplete)
                } else {
                    self.logPacket(proto: "udp", id: id, data: data, complete: isComplete)
                }
            }
            if let error {
                DiagnosticsLog.warn("phonerelay.mac.probe_receive_failed proto=udp id=\(id.uuidString) error=\(error)")
                self.connections[id] = nil
                self.udpConnectionPorts[id] = nil
                return
            }
            self.receiveUDP(connection, id: id)
        }
    }

    private func logPacket(proto: String, id: UUID, data: Data, complete: Bool) {
        DiagnosticsLog.info(
            "phonerelay.mac.probe_packet proto=\(proto) id=\(id.uuidString) " +
                "bytes=\(data.count) complete=\(complete) fp=\(DiagnosticsLog.fingerprint(data)) " +
                "prefix=\(hexPrefix(data))"
        )
    }

    private func hexPrefix(_ data: Data) -> String {
        data.prefix(32).map { String(format: "%02x", $0) }.joined()
    }

    private func logRTPPacket(port: UInt16, id: UUID, data: Data, complete: Bool) {
        let nextCount = (rtpPacketCounts[port] ?? 0) + 1
        rtpPacketCounts[port] = nextCount
        forwardMPEGTSForPlaybackIfNeeded(port: port, data: data)
        guard nextCount <= 12 || nextCount % 50 == 0 else {
            return
        }
        DiagnosticsLog.info(
            "phonerelay.mac.rtp_packet port=\(port) id=\(id.uuidString) count=\(nextCount) " +
                "bytes=\(data.count) complete=\(complete) \(rtpPacketSummary(data)) " +
                "fp=\(DiagnosticsLog.fingerprint(data)) prefix=\(hexPrefix(data)) " +
                "payloadPrefix=\(rtpPayloadHexPrefix(data))"
        )
    }

    private func rtpPacketSummary(_ data: Data) -> String {
        let bytes = Array(data.prefix(16))
        guard bytes.count >= 2 else {
            return "format=short"
        }
        let version = bytes[0] >> 6
        guard version == 2 else {
            return "format=unknown version=\(version)"
        }
        let packetType = bytes[1]
        if packetType >= 192 {
            return "format=rtcp type=\(packetType)"
        }
        guard bytes.count >= 12 else {
            return "format=rtp_short"
        }
        let marker = (packetType & 0x80) != 0
        let payloadType = packetType & 0x7f
        let sequenceNumber = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let timestamp = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16) | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
        let ssrc = (UInt32(bytes[8]) << 24) | (UInt32(bytes[9]) << 16) | (UInt32(bytes[10]) << 8) | UInt32(bytes[11])
        let payloadOffset = rtpPayloadOffset(data) ?? 0
        let payloadBytes = payloadOffset > 0 ? max(data.count - payloadOffset, 0) : 0
        return "format=rtp pt=\(payloadType) marker=\(marker) seq=\(sequenceNumber) ts=\(timestamp) " +
            "ssrc=0x\(String(format: "%08x", ssrc)) payloadOffset=\(payloadOffset) payloadBytes=\(payloadBytes)"
    }

    private func rtpPayloadHexPrefix(_ data: Data) -> String {
        guard let offset = rtpPayloadOffset(data), offset < data.count else {
            return ""
        }
        return data.dropFirst(offset).prefix(24).map { String(format: "%02x", $0) }.joined()
    }

    private func rtpPayloadOffset(_ data: Data) -> Int? {
        let bytes = Array(data.prefix(16))
        guard bytes.count >= 12, bytes[0] >> 6 == 2, bytes[1] < 192 else {
            return nil
        }
        let csrcCount = Int(bytes[0] & 0x0f)
        var offset = 12 + (csrcCount * 4)
        guard data.count >= offset else {
            return nil
        }
        let hasExtension = (bytes[0] & 0x10) != 0
        if hasExtension {
            guard data.count >= offset + 4 else {
                return nil
            }
            let extensionHeader = Array(data.dropFirst(offset).prefix(4))
            let extensionWordCount = (Int(extensionHeader[2]) << 8) | Int(extensionHeader[3])
            offset += 4 + (extensionWordCount * 4)
            guard data.count >= offset else {
                return nil
            }
        }
        return offset
    }

    private func forwardMPEGTSForPlaybackIfNeeded(port: UInt16, data: Data) {
        guard port == sinkRTPPort,
              let payloadOffset = rtpPayloadOffset(data),
              payloadOffset < data.count else {
            return
        }
        let payload = Data(data.dropFirst(payloadOffset))
        guard payload.first == 0x47 else {
            return
        }
        writeMPEGTSFileCapture(payload)
        startMPEGTSPlayerIfNeeded(reason: "rtp_mpegts")
        guard let mpegTSPlayerInput else {
            return
        }
        do {
            try mpegTSPlayerInput.write(contentsOf: payload)
            mpegTSBytesWritten += payload.count
            if mpegTSBytesWritten == payload.count || mpegTSBytesWritten % (188 * 500) < payload.count {
                DiagnosticsLog.info(
                    "phonerelay.mac.mpegts_playback_write bytes=\(payload.count) total=\(mpegTSBytesWritten) " +
                        "fp=\(DiagnosticsLog.fingerprint(payload)) prefix=\(hexPrefix(payload))"
                )
            }
        } catch {
            DiagnosticsLog.warn("phonerelay.mac.mpegts_playback_write_failed error=\(error)")
            stopMPEGTSPlayer(reason: "write_failed")
        }
    }

    private func writeMPEGTSFileCapture(_ payload: Data) {
        guard mpegTSCaptureEnabled, mpegTSCaptureBytes < Self.mpegTSCaptureLimitBytes else {
            if !mpegTSCaptureLimitLogged, mpegTSCaptureBytes >= Self.mpegTSCaptureLimitBytes {
                mpegTSCaptureLimitLogged = true
                DiagnosticsLog.info(
                    "phonerelay.mac.mpegts_capture_limit path=\(Self.mpegTSCapturePath) bytes=\(mpegTSCaptureBytes)"
                )
            }
            return
        }
        startMPEGTSFileCaptureIfNeeded()
        guard let mpegTSCaptureHandle else {
            return
        }
        let remainingBytes = Self.mpegTSCaptureLimitBytes - mpegTSCaptureBytes
        let bytesToWrite = min(payload.count, remainingBytes)
        let chunk = bytesToWrite == payload.count ? payload : Data(payload.prefix(bytesToWrite))
        do {
            try mpegTSCaptureHandle.write(contentsOf: chunk)
            mpegTSCaptureBytes += chunk.count
        } catch {
            DiagnosticsLog.warn("phonerelay.mac.mpegts_capture_write_failed error=\(error)")
            stopMPEGTSFileCapture(reason: "write_failed")
        }
    }

    private func startMPEGTSFileCaptureIfNeeded() {
        guard mpegTSCaptureHandle == nil else {
            return
        }
        let path = Self.mpegTSCapturePath
        FileManager.default.createFile(atPath: path, contents: nil)
        do {
            mpegTSCaptureHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            mpegTSCaptureBytes = 0
            mpegTSCaptureLimitLogged = false
            DiagnosticsLog.info("phonerelay.mac.mpegts_capture_start path=\(path) limit=\(Self.mpegTSCaptureLimitBytes)")
        } catch {
            DiagnosticsLog.warn("phonerelay.mac.mpegts_capture_start_failed path=\(path) error=\(error)")
            mpegTSCaptureHandle = nil
            mpegTSCaptureBytes = 0
        }
    }

    private func stopMPEGTSFileCapture(reason: String) {
        let hadCapture = mpegTSCaptureHandle != nil
        try? mpegTSCaptureHandle?.close()
        mpegTSCaptureHandle = nil
        if hadCapture {
            DiagnosticsLog.info(
                "phonerelay.mac.mpegts_capture_stop path=\(Self.mpegTSCapturePath) " +
                    "bytes=\(mpegTSCaptureBytes) reason=\(reason)"
            )
        }
        mpegTSCaptureBytes = 0
        mpegTSCaptureLimitLogged = false
    }

    private func startMPEGTSPlayerIfNeeded(reason: String) {
        if let process = mpegTSPlayerProcess, process.isRunning {
            return
        }
        guard mpegTSPlaybackEnabled else {
            return
        }
        guard let ffplayURL = ffplayExecutableURL() else {
            DiagnosticsLog.warn("phonerelay.mac.mpegts_playback_unavailable reason=\(reason)")
            return
        }
        let process = Process()
        let inputPipe = Pipe()
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        process.executableURL = ffplayURL
        process.arguments = [
            "-nodisp",
            "-autoexit",
            "-loglevel", "error",
            "-nostats",
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-probesize", "32768",
            "-analyzeduration", "0",
            "-f", "mpegts",
            "-i", "pipe:0"
        ]
        process.standardInput = inputPipe
        if let devNull {
            process.standardOutput = devNull
            process.standardError = devNull
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.queue.async {
                guard self?.mpegTSPlayerProcess === terminatedProcess else {
                    return
                }
                DiagnosticsLog.info("phonerelay.mac.mpegts_playback_exit status=\(terminatedProcess.terminationStatus)")
                self?.mpegTSPlayerProcess = nil
                self?.mpegTSPlayerInput = nil
                self?.mpegTSPlayerDevNull = nil
                self?.mpegTSBytesWritten = 0
            }
        }
        do {
            try process.run()
            mpegTSPlayerProcess = process
            mpegTSPlayerInput = inputPipe.fileHandleForWriting
            mpegTSPlayerDevNull = devNull
            mpegTSBytesWritten = 0
            DiagnosticsLog.info("phonerelay.mac.mpegts_playback_start path=\(ffplayURL.path) reason=\(reason)")
        } catch {
            DiagnosticsLog.warn("phonerelay.mac.mpegts_playback_start_failed path=\(ffplayURL.path) error=\(error)")
            mpegTSPlayerProcess = nil
            mpegTSPlayerInput = nil
            mpegTSPlayerDevNull = nil
            mpegTSBytesWritten = 0
        }
    }

    private func stopMPEGTSPlayer(reason: String) {
        let process = mpegTSPlayerProcess
        let hadProcess = process != nil
        try? mpegTSPlayerInput?.close()
        mpegTSPlayerInput = nil
        mpegTSPlayerDevNull = nil
        mpegTSPlayerProcess = nil
        mpegTSBytesWritten = 0
        if let process, process.isRunning {
            process.terminate()
        }
        if hadProcess {
            DiagnosticsLog.info("phonerelay.mac.mpegts_playback_stop reason=\(reason)")
        }
    }

    private var mpegTSPlaybackEnabled: Bool {
        UserDefaults.standard.object(forKey: "phoneRelayProbePlaybackEnabled") as? Bool ?? true
    }

    private var mpegTSCaptureEnabled: Bool {
        UserDefaults.standard.object(forKey: "phoneRelayProbeCaptureEnabled") as? Bool ?? true
    }

    private func ffplayExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffplay",
            "/usr/local/bin/ffplay",
            "/usr/bin/ffplay"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private func processTCPData(connection: NWConnection, id: UUID, data: Data) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
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
            "phonerelay.mac.rtsp_message dir=in id=\(id.uuidString) " +
                "firstLine=\(sanitizeRTSPLogValue(firstLine)) cseq=\(sanitizeRTSPLogValue(cseq)) bytes=\(data.count)"
        )
        if !bodyText.isEmpty {
            DiagnosticsLog.info(
                "phonerelay.mac.rtsp_body dir=in id=\(id.uuidString) " +
                    "preview=\(sanitizeRTSPLogValue(bodyText))"
            )
        }

        if firstLine.uppercased().hasPrefix("RTSP/") {
            handleRTSPResponse(connection: connection, id: id, headerText: headerText, cseq: cseq)
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
                firstLine: firstLine,
                headers: [
                    ("Public", "org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER"),
                    ("fastRTSPVersion", "0")
                ]
            )
            sendRTSPOptionsIfNeeded(connection: connection, id: id, reason: "peer_options")
            if tcpStates[id]?.isPeerSourceConnection == false {
                sendSourceGETParameterIfNeeded(connection: connection, id: id, reason: "peer_options")
            }
        case "GET_PARAMETER":
            sendRTSPResponse(
                connection: connection,
                id: id,
                cseq: cseq,
                firstLine: firstLine,
                headers: [("Content-Type", "text/parameters")],
                body: wfdParameterResponseBody(requestBody: bodyText)
            )
        case "SET_PARAMETER":
            recordPresentationURL(from: bodyText, id: id)
            sendRTSPResponse(connection: connection, id: id, cseq: cseq, firstLine: firstLine)
            if bodyText.localizedCaseInsensitiveContains("wfd_trigger_method: SETUP") {
                sendSinkSETUPIfNeeded(connection: connection, id: id, reason: "trigger_setup")
            }
        case "SETUP":
            let session = ensureSessionID(for: id)
            sendRTSPResponse(
                connection: connection,
                id: id,
                cseq: cseq,
                firstLine: firstLine,
                headers: [
                    ("Session", session),
                    ("Transport", setupResponseTransport(requestHeaderText: headerText))
                ]
            )
        case "PLAY", "PAUSE", "TEARDOWN":
            sendRTSPResponse(connection: connection, id: id, cseq: cseq, firstLine: firstLine)
        default:
            sendRTSPResponse(connection: connection, id: id, cseq: cseq, firstLine: firstLine)
        }
    }

    private func handleRTSPResponse(connection: NWConnection, id: UUID, headerText: String, cseq: String) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        let requestMethod = state.pendingRequests.removeValue(forKey: cseq)
        if let session = rtspHeader("Session", in: headerText)?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces),
           !session.isEmpty {
            state.sessionID = session
        }
        tcpStates[id] = state

        switch requestMethod {
        case "GET_PARAMETER":
            sendSourceSETParameterIfNeeded(connection: connection, id: id, reason: "get_parameter_response")
        case "SETUP":
            sendPLAYIfNeeded(connection: connection, id: id, reason: "setup_response")
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

    private func sendRTSPOptionsIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        guard !state.sentGreeting && (state.sendsGreetingOnReady || reason == "peer_options") else {
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
                ("lib_version", "edgelink_probe"),
                ("fastRTSPVersion", "0")
            ],
            label: "options"
        )
    }

    private func sendSourceGETParameterIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
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
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        guard !state.sentSourceSETParameter else {
            return
        }
        state.sentSourceSETParameter = true
        tcpStates[id] = state
        let body = """
        wfd_presentation_URL: rtsp://localhost/wfd1.0/streamid=0 none\r
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

    private func sendSinkSETUPIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
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
            label: "setup_\(reason)"
        )
    }

    private func sendPLAYIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        guard !state.sentPLAY else {
            return
        }
        state.sentPLAY = true
        let uri = state.presentationURL ?? "rtsp://localhost/wfd1.0/streamid=0"
        let session = state.sessionID
        tcpStates[id] = state
        var headers: [(String, String)] = []
        if let session, !session.isEmpty {
            headers.append(("Session", session))
        }
        sendRTSPRequest(
            method: "PLAY",
            uri: uri,
            connection: connection,
            id: id,
            headers: headers,
            label: "play_\(reason)"
        )
    }

    private func sendRTSPResponse(
        connection: NWConnection,
        id: UUID,
        cseq: String,
        firstLine: String,
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
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
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
        let firstLine = message.components(separatedBy: "\r\n").first ?? label
        DiagnosticsLog.info(
            "phonerelay.mac.rtsp_message dir=out id=\(id.uuidString) " +
                "firstLine=\(sanitizeRTSPLogValue(firstLine)) bytes=\(data.count)"
        )
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.warn("phonerelay.mac.rtsp_send_failed id=\(id.uuidString) label=\(label) error=\(error)")
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
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        state.presentationURL = url
        tcpStates[id] = state
        DiagnosticsLog.info("phonerelay.mac.rtsp_presentation_url id=\(id.uuidString) url=\(sanitizeRTSPLogValue(url))")
    }

    private func ensureSessionID(for id: UUID) -> String {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
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

    private func sanitizeRTSPLogValue(_ value: String) -> String {
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

    private static let peerSourceRetryDelayMilliseconds = 2_000
    private static let mpegTSCaptureLimitBytes = 8 * 1024 * 1024
    private static let mpegTSCapturePath = "/private/tmp/edgelink-phonerelay.ts"
}

private struct TCPConnectionState {
    var buffer = Data()
    var sentGreeting = false
    var nextCSeq = 1
    var pendingRequests: [String: String] = [:]
    var presentationURL: String?
    var sessionID: String?
    var sentSourceGETParameter = false
    var sentSourceSETParameter = false
    var sentSinkSETUP = false
    var sentPLAY = false
    let sendsGreetingOnReady: Bool
    let isPeerSourceConnection: Bool
}

private enum MiLinkPhoneRelayProbeError: Error {
    case invalidPort(UInt16)
}
