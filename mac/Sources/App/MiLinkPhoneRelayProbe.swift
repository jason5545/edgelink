import Foundation
import AVFoundation
import Darwin
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
    private var sourceRTPConnection: NWConnection?
    private var sourceRTPConnectionID: UUID?
    private var sourceRTPProcess: Process?
    private var sourceRTPInput: FileHandle?
    private var sourceRTPOutput: FileHandle?
    private var sourceRTPDevNull: FileHandle?
    private var sourceRTPBuffer = Data()
    private var sourceRTPSequenceNumber: UInt16 = 0
    private var sourceRTPTimestamp: UInt32 = 0
    private var sourceRTPPacketsSent = 0
    private var sourceAudioEngine: AVAudioEngine?
    private var sourceAudioConverter: AVAudioConverter?
    private var sourcePCMBytesWritten = 0
    private var port: UInt16 = 7102
    private let sinkRTPPort: UInt16 = 19_000
    private let sourceRTPPort: UInt16 = 19_002
    private var rtpProbePorts: [UInt16] {
        [sinkRTPPort, sinkRTPPort + 1, sourceRTPPort + 1]
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
        stopSourceRTP(reason: "probe_stop")
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
            stopSourceRTPIfOwned(by: id, reason: "connection_failed")
            connections[id] = nil
            tcpStates[id] = nil
            udpConnectionPorts[id] = nil
        case .cancelled:
            DiagnosticsLog.info("phonerelay.mac.probe_connection_cancelled proto=\(proto) id=\(id.uuidString)")
            if isPeerSourceConnection {
                markPeerSourceDisconnected(id: id, reason: "state_cancelled")
            }
            stopSourceRTPIfOwned(by: id, reason: "connection_cancelled")
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
                self.stopSourceRTPIfOwned(by: id, reason: "tcp_receive_failed")
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
                self.stopSourceRTPIfOwned(by: id, reason: "tcp_receive_complete")
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

    private func startSourceRTPIfReady(id: UUID, reason: String) {
        let state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        guard !state.isPeerSourceConnection else {
            return
        }
        guard sourceRTPTestEnabled else {
            DiagnosticsLog.info("phonerelay.mac.source_rtp_disabled id=\(id.uuidString) reason=\(reason)")
            return
        }
        guard let host = state.sourceRemoteHost,
              let rtpPort = state.sourceRemoteRTPPort else {
            DiagnosticsLog.warn("phonerelay.mac.source_rtp_missing_destination id=\(id.uuidString) reason=\(reason)")
            return
        }
        if sourceRTPConnectionID == id, sourceRTPProcess?.isRunning == true {
            return
        }
        stopSourceRTP(reason: "restart")
        guard let remotePort = NWEndpoint.Port(rawValue: rtpPort),
              let localPort = NWEndpoint.Port(rawValue: sourceRTPPort),
              let anyIPv4 = IPv4Address("0.0.0.0") else {
            DiagnosticsLog.warn("phonerelay.mac.source_rtp_invalid_port id=\(id.uuidString) remote=\(host):\(rtpPort)")
            return
        }

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(anyIPv4), port: localPort)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: remotePort, using: parameters)
        sourceRTPConnection = connection
        sourceRTPConnectionID = id
        sourceRTPSequenceNumber = 0
        sourceRTPTimestamp = UInt32.random(in: 0..<UInt32.max)
        sourceRTPPacketsSent = 0
        sourceRTPBuffer.removeAll(keepingCapacity: true)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                DiagnosticsLog.info(
                    "phonerelay.mac.source_rtp_ready id=\(id.uuidString) localPort=\(self.sourceRTPPort) " +
                        "remote=\(host):\(rtpPort)"
                )
            case .failed(let error):
                DiagnosticsLog.warn("phonerelay.mac.source_rtp_failed id=\(id.uuidString) error=\(error)")
            case .cancelled:
                DiagnosticsLog.info("phonerelay.mac.source_rtp_cancelled id=\(id.uuidString)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        startSourceMPEGTSProcess(id: id, reason: reason)
    }

    private func startSourceMPEGTSProcess(id: UUID, reason: String) {
        guard let ffmpegURL = ffmpegExecutableURL() else {
            DiagnosticsLog.warn("phonerelay.mac.source_mpegts_unavailable id=\(id.uuidString) reason=\(reason)")
            stopSourceRTP(reason: "ffmpeg_unavailable")
            return
        }
        let audioMode = sourceRTPAudioMode
        if audioMode == .microphone && !microphoneCaptureAuthorizedForSourceRTP(id: id, reason: reason) {
            stopSourceRTP(reason: "microphone_permission_unavailable")
            return
        }
        let process = Process()
        let inputPipe = audioMode == .microphone ? Pipe() : nil
        let outputPipe = Pipe()
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        process.executableURL = ffmpegURL
        process.arguments = sourceMPEGTSArguments(audioMode: audioMode)
        if let inputPipe {
            process.standardInput = inputPipe
        }
        process.standardOutput = outputPipe
        if let devNull {
            process.standardError = devNull
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async {
                guard let self, self.sourceRTPProcess === process else {
                    return
                }
                if data.isEmpty {
                    self.stopSourceRTP(reason: "mpegts_eof")
                } else {
                    self.sendSourceMPEGTS(data)
                }
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.queue.async {
                guard self?.sourceRTPProcess === terminatedProcess else {
                    return
                }
                DiagnosticsLog.info("phonerelay.mac.source_mpegts_exit status=\(terminatedProcess.terminationStatus)")
                self?.stopSourceRTP(reason: "mpegts_exit")
            }
        }
        do {
            try process.run()
            sourceRTPProcess = process
            sourceRTPInput = inputPipe?.fileHandleForWriting
            sourceRTPOutput = outputPipe.fileHandleForReading
            sourceRTPDevNull = devNull
            sourcePCMBytesWritten = 0
            DiagnosticsLog.info(
                "phonerelay.mac.source_mpegts_start path=\(ffmpegURL.path) id=\(id.uuidString) " +
                    "mode=\(audioMode.rawValue) reason=\(reason)"
            )
            if audioMode == .microphone {
                startSourceMicrophoneCapture(id: id)
            }
        } catch {
            DiagnosticsLog.warn("phonerelay.mac.source_mpegts_start_failed path=\(ffmpegURL.path) error=\(error)")
            stopSourceRTP(reason: "mpegts_start_failed")
        }
    }

    private func sourceMPEGTSArguments(audioMode: SourceRTPAudioMode) -> [String] {
        switch audioMode {
        case .silent:
            return [
                "-hide_banner",
                "-loglevel", "error",
                "-re",
                "-f", "lavfi",
                "-i", "anullsrc=channel_layout=mono:sample_rate=48000",
                "-ac", "1",
                "-c:a", "aac",
                "-profile:a", "aac_low",
                "-b:a", "64k",
                "-f", "mpegts",
                "pipe:1"
            ]
        case .microphone:
            return [
                "-hide_banner",
                "-loglevel", "error",
                "-f", "s16le",
                "-ar", "\(Int(Self.sourcePCMSampleRate))",
                "-ac", "\(Int(Self.sourcePCMChannels))",
                "-i", "pipe:0",
                "-c:a", "aac",
                "-profile:a", "aac_low",
                "-b:a", "64k",
                "-f", "mpegts",
                "pipe:1"
            ]
        }
    }

    private func microphoneCaptureAuthorizedForSourceRTP(id: UUID, reason: String) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DiagnosticsLog.info("phonerelay.mac.source_microphone_permission_result granted=\(granted)")
                guard granted else {
                    return
                }
                self?.queue.async {
                    self?.startSourceRTPIfReady(id: id, reason: "microphone_permission_granted_\(reason)")
                }
            }
            DiagnosticsLog.warn("phonerelay.mac.source_microphone_permission_pending id=\(id.uuidString) reason=\(reason)")
            return false
        case .denied, .restricted:
            DiagnosticsLog.warn("phonerelay.mac.source_microphone_permission_denied id=\(id.uuidString) reason=\(reason)")
            return false
        @unknown default:
            DiagnosticsLog.warn("phonerelay.mac.source_microphone_permission_unknown id=\(id.uuidString) reason=\(reason)")
            return false
        }
    }

    private func startSourceMicrophoneCapture(id: UUID) {
        guard sourceAudioEngine == nil else {
            return
        }
        guard let sourceRTPInput else {
            DiagnosticsLog.warn("phonerelay.mac.source_microphone_missing_input id=\(id.uuidString)")
            stopSourceRTP(reason: "microphone_missing_input")
            return
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0,
              let outputFormat = Self.sourcePCMFormat,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            DiagnosticsLog.warn(
                "phonerelay.mac.source_microphone_format_unavailable id=\(id.uuidString) " +
                    "inputRate=\(inputFormat.sampleRate) inputChannels=\(inputFormat.channelCount)"
            )
            stopSourceRTP(reason: "microphone_format_unavailable")
            return
        }

        sourceAudioEngine = engine
        sourceAudioConverter = converter
        inputNode.installTap(onBus: 0, bufferSize: Self.sourcePCMFramesPerBuffer, format: inputFormat) { [weak self, converter, outputFormat] buffer, _ in
            guard let pcm = Self.convertSourceMicrophoneBuffer(buffer, converter: converter, outputFormat: outputFormat),
                  !pcm.isEmpty else {
                return
            }
            self?.queue.async {
                guard let self, self.sourceRTPInput === sourceRTPInput else {
                    return
                }
                self.writeSourcePCM(pcm)
            }
        }

        do {
            try engine.start()
            DiagnosticsLog.info(
                "phonerelay.mac.source_microphone_start id=\(id.uuidString) " +
                    "inputRate=\(inputFormat.sampleRate) inputChannels=\(inputFormat.channelCount) " +
                    "outputRate=\(Self.sourcePCMSampleRate) outputChannels=\(Self.sourcePCMChannels)"
            )
        } catch {
            inputNode.removeTap(onBus: 0)
            sourceAudioEngine = nil
            sourceAudioConverter = nil
            DiagnosticsLog.warn("phonerelay.mac.source_microphone_start_failed id=\(id.uuidString) error=\(error)")
            stopSourceRTP(reason: "microphone_start_failed")
        }
    }

    private static func convertSourceMicrophoneBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            DiagnosticsLog.warn("phonerelay.mac.source_microphone_convert_failed error=\(conversionError)")
            return nil
        }
        guard status != .error,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData else {
            return nil
        }
        let byteCount = Int(outputBuffer.frameLength) * Int(outputFormat.channelCount) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }

    private func writeSourcePCM(_ data: Data) {
        guard let sourceRTPInput,
              sourceRTPProcess?.isRunning == true else {
            return
        }
        do {
            try sourceRTPInput.write(contentsOf: data)
            sourcePCMBytesWritten += data.count
            if sourcePCMBytesWritten == data.count || sourcePCMBytesWritten % 96_000 < data.count {
                DiagnosticsLog.info(
                    "phonerelay.mac.source_microphone_pcm_write bytes=\(data.count) total=\(sourcePCMBytesWritten)"
                )
            }
        } catch {
            DiagnosticsLog.warn("phonerelay.mac.source_microphone_pcm_write_failed error=\(error)")
            stopSourceRTP(reason: "microphone_pcm_write_failed")
        }
    }

    private func stopSourceMicrophoneCapture(reason: String) {
        let engine = sourceAudioEngine
        let hadEngine = engine != nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        sourceAudioEngine = nil
        sourceAudioConverter = nil
        sourcePCMBytesWritten = 0
        if hadEngine {
            DiagnosticsLog.info("phonerelay.mac.source_microphone_stop reason=\(reason)")
        }
    }

    private func sendSourceMPEGTS(_ data: Data) {
        sourceRTPBuffer.append(data)
        while true {
            guard let syncIndex = sourceRTPBuffer.firstIndex(of: 0x47) else {
                sourceRTPBuffer.removeAll(keepingCapacity: true)
                return
            }
            if syncIndex != sourceRTPBuffer.startIndex {
                sourceRTPBuffer.removeSubrange(sourceRTPBuffer.startIndex..<syncIndex)
            }
            guard sourceRTPBuffer.count >= 188 else {
                return
            }
            let availablePackets = min(7, sourceRTPBuffer.count / 188)
            var packetCount = 0
            while packetCount < availablePackets {
                let packetStart = sourceRTPBuffer.startIndex.advanced(by: packetCount * 188)
                guard sourceRTPBuffer[packetStart] == 0x47 else {
                    break
                }
                packetCount += 1
            }
            guard packetCount > 0 else {
                sourceRTPBuffer.removeFirst()
                continue
            }
            let payloadBytes = packetCount * 188
            let payload = Data(sourceRTPBuffer.prefix(payloadBytes))
            sourceRTPBuffer.removeSubrange(..<sourceRTPBuffer.index(sourceRTPBuffer.startIndex, offsetBy: payloadBytes))
            sendSourceRTPPayload(payload)
        }
    }

    private func sendSourceRTPPayload(_ payload: Data) {
        guard let connection = sourceRTPConnection else {
            return
        }
        var packet = Data(capacity: 12 + payload.count)
        packet.append(0x80)
        packet.append(0x80 | 33)
        appendUInt16BE(sourceRTPSequenceNumber, to: &packet)
        appendUInt32BE(sourceRTPTimestamp, to: &packet)
        appendUInt32BE(Self.sourceRTPSSRC, to: &packet)
        packet.append(payload)
        let sequenceNumber = sourceRTPSequenceNumber
        let timestamp = sourceRTPTimestamp
        sourceRTPSequenceNumber &+= 1
        sourceRTPTimestamp &+= 1_800
        sourceRTPPacketsSent += 1
        let count = sourceRTPPacketsSent
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.warn("phonerelay.mac.source_rtp_send_failed seq=\(sequenceNumber) error=\(error)")
            }
        })
        if count <= 12 || count % 50 == 0 {
            DiagnosticsLog.info(
                "phonerelay.mac.source_rtp_packet count=\(count) seq=\(sequenceNumber) ts=\(timestamp) " +
                    "bytes=\(packet.count) payloadBytes=\(payload.count) fp=\(DiagnosticsLog.fingerprint(packet)) " +
                    "payloadPrefix=\(hexPrefix(payload))"
            )
        }
    }

    private func stopSourceRTPIfOwned(by id: UUID, reason: String) {
        guard sourceRTPConnectionID == id else {
            return
        }
        stopSourceRTP(reason: reason)
    }

    private func stopSourceRTP(reason: String) {
        let hadSource = sourceRTPConnection != nil || sourceRTPProcess != nil || sourceAudioEngine != nil
        stopSourceMicrophoneCapture(reason: reason)
        try? sourceRTPInput?.close()
        sourceRTPInput = nil
        sourceRTPOutput?.readabilityHandler = nil
        try? sourceRTPOutput?.close()
        sourceRTPOutput = nil
        try? sourceRTPDevNull?.close()
        sourceRTPDevNull = nil
        let process = sourceRTPProcess
        sourceRTPProcess = nil
        if let process, process.isRunning {
            process.terminate()
        }
        sourceRTPConnection?.cancel()
        sourceRTPConnection = nil
        sourceRTPConnectionID = nil
        sourceRTPBuffer.removeAll(keepingCapacity: true)
        sourceRTPSequenceNumber = 0
        sourceRTPTimestamp = 0
        sourceRTPPacketsSent = 0
        sourcePCMBytesWritten = 0
        if hadSource {
            DiagnosticsLog.info("phonerelay.mac.source_rtp_stop reason=\(reason)")
        }
    }

    private var sourceRTPTestEnabled: Bool {
        UserDefaults.standard.object(forKey: "phoneRelayProbeSourceRTPEnabled") as? Bool ?? false
    }

    private var sourceRTPAudioMode: SourceRTPAudioMode {
        SourceRTPAudioMode(defaultsValue: UserDefaults.standard.string(forKey: "phoneRelayProbeSourceAudioMode"))
    }

    private func ffmpegExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
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
            recordSourceRTPDestination(from: headerText, connection: connection, id: id)
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
        case "PLAY":
            sendRTSPResponse(connection: connection, id: id, cseq: cseq, firstLine: firstLine)
            startSourceRTPIfReady(id: id, reason: "play_request")
        case "PAUSE":
            sendRTSPResponse(connection: connection, id: id, cseq: cseq, firstLine: firstLine)
            stopSourceRTPIfOwned(by: id, reason: "pause_request")
        case "TEARDOWN":
            sendRTSPResponse(connection: connection, id: id, cseq: cseq, firstLine: firstLine)
            stopSourceRTPIfOwned(by: id, reason: "teardown_request")
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
        let presentationURL = "rtsp://\(sourcePresentationHost())/wfd1.0/streamid=0"
        tcpStates[id] = state
        let body = """
        wfd_presentation_URL: \(presentationURL) none\r
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

    private func recordSourceRTPDestination(from headerText: String, connection: NWConnection, id: UUID) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        guard !state.isPeerSourceConnection else {
            return
        }
        guard let transport = rtspHeader("Transport", in: headerText),
              let clientPort = rtspTransportValue("client_port", in: transport),
              let rtpPort = firstRTPPort(in: clientPort),
              let host = endpointHostString(connection.endpoint) else {
            DiagnosticsLog.warn(
                "phonerelay.mac.source_rtp_destination_missing id=\(id.uuidString) " +
                    "transport=\(sanitizeRTSPLogValue(rtspHeader("Transport", in: headerText) ?? "none"))"
            )
            return
        }
        state.sourceRemoteHost = host
        state.sourceRemoteRTPPort = rtpPort
        tcpStates[id] = state
        DiagnosticsLog.info(
            "phonerelay.mac.source_rtp_destination id=\(id.uuidString) remote=\(host):\(rtpPort) " +
                "transport=\(sanitizeRTSPLogValue(transport))"
        )
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
        if let override = UserDefaults.standard.string(forKey: "phoneRelayProbeSourceHost")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return Self.preferredLocalIPv4Address() ?? "localhost"
    }

    private static func preferredLocalIPv4Address() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let firstAddress = addresses else {
            return nil
        }
        defer { freeifaddrs(addresses) }

        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                continue
            }
            let address = String(cString: host)
            let interfaceName = String(cString: interface.ifa_name)
            if interfaceName == "en0" {
                return address
            }
            if fallback == nil {
                fallback = address
            }
        }
        return fallback
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
    private static let sourceRTPSSRC: UInt32 = 0xed9e_1101
    private static let sourcePCMSampleRate: Double = 48_000
    private static let sourcePCMChannels: AVAudioChannelCount = 1
    private static let sourcePCMFramesPerBuffer: AVAudioFrameCount = 960
    private static var sourcePCMFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sourcePCMSampleRate,
            channels: sourcePCMChannels,
            interleaved: false
        )
    }
    private static let mpegTSCaptureLimitBytes = 8 * 1024 * 1024
    private static let mpegTSCapturePath = "/private/tmp/edgelink-phonerelay.ts"
}

private enum SourceRTPAudioMode: String {
    case silent
    case microphone

    init(defaultsValue: String?) {
        switch defaultsValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mic", "microphone", "input", "mac_microphone", "mac-microphone":
            self = .microphone
        default:
            self = .silent
        }
    }
}

private struct TCPConnectionState {
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
    var sentSinkSETUP = false
    var sentPLAY = false
    let sendsGreetingOnReady: Bool
    let isPeerSourceConnection: Bool
}

private enum MiLinkPhoneRelayProbeError: Error {
    case invalidPort(UInt16)
}
