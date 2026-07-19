import Foundation
import AVFoundation
import Darwin
import Network

struct MiLinkPhoneRelayPCMStats: Equatable {
    let sessionID: UUID
    let pcmBytes: Int
    let totalPCMBytes: Int
    let pesPacketCount: Int
    let samples: Int
    let nonzeroSamples: Int
    let maxAbs: Int
    let averageAbs: Int
    let fingerprint: String
    let prefix: String

    var hasValidStream: Bool {
        totalPCMBytes >= 16_000 && nonzeroSamples > 0 && maxAbs >= 256
    }

    var diagnosticSummary: String {
        "session=\(sessionID.uuidString) pcmBytes=\(pcmBytes) pcmTotal=\(totalPCMBytes) " +
            "pes=\(pesPacketCount) samples=\(samples) nonzero=\(nonzeroSamples) " +
            "maxAbs=\(maxAbs) avgAbs=\(averageAbs) fp=\(fingerprint)"
    }
}

final class MiLinkPhoneRelayProbe {
    var onSinkPCMStats: ((MiLinkPhoneRelayPCMStats) -> Void)?

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
    private var mpegTSPlayerErrorOutput: FileHandle?
    private var mpegTSPlayerDevNull: FileHandle?
    private var mpegTSBytesWritten = 0
    private var mpegTSPCMBytesWritten = 0
    private var mpegTSPCMPESPacketCount = 0
    private var mpegTSPlayerStderrBytesLogged = 0
    private var sinkPCMValidationSessionID = UUID()
    private var sinkPCMValidStreamReported = false
    private var latestSinkPCMStats: MiLinkPhoneRelayPCMStats?
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
    private var sourceRTPPacketHandler: ((Data) -> Void)?
    private var sourceRTPProcess: Process?
    private var sourceRTPInput: FileHandle?
    private var sourceRTPOutput: FileHandle?
    private var sourceRTPDevNull: FileHandle?
    private var sourceRTPBuffer = Data()
    private var sourceRTPSequenceNumber: UInt16 = 0
    private var sourceRTPTimestamp: UInt32 = 0
    private var sourceRTPPacketsSent = 0
    private var sourceAudioTSContinuityCounter: UInt8 = 0
    private var sourcePATContinuityCounter: UInt8 = 0
    private var sourcePMTContinuityCounter: UInt8 = 0
    private var sourceAudioEngine: AVAudioEngine?
    private var sourceAudioConverter: AVAudioConverter?
    private var sourcePCMBytesWritten = 0
    private var sourceRTPArmedUntil = Date.distantPast
    private var sourceRTPArmReason: String?
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
        tcp.start(queue: queue)
        udp.start(queue: queue)
        for listener in rtpListeners.values {
            listener.start(queue: queue)
        }

        if let peerSourceHost {
            connectPeerSource(host: peerSourceHost, port: peerSourcePort, reason: "start")
        }
    }

    func armSourceRTP(reason: String) {
        queue.async {
            self.armSourceRTPOnQueue(reason: reason, duration: Self.sourceRTPArmDurationSeconds)
        }
    }

    func disarmSourceRTP(reason: String, stopActive: Bool) {
        queue.async {
            self.disarmSourceRTPOnQueue(reason: reason, stopActive: stopActive)
        }
    }

    func startExternalSourceRTP(reason: String, packetHandler: @escaping (Data) -> Void) {
        queue.async {
            self.startExternalSourceRTPOnQueue(reason: reason, packetHandler: packetHandler)
        }
    }

    func stopExternalSourceRTP(reason: String) {
        queue.async {
            guard self.sourceRTPPacketHandler != nil else {
                return
            }
            self.stopSourceRTP(reason: "external_\(reason)")
        }
    }

    func resetSinkPCMValidation(reason: String) -> UUID {
        queue.sync {
            sinkPCMValidationSessionID = UUID()
            sinkPCMValidStreamReported = false
            latestSinkPCMStats = nil
            DiagnosticsLog.info(
                "phonerelay.mac.sink_pcm_validation_reset session=\(sinkPCMValidationSessionID.uuidString) reason=\(reason)"
            )
            return sinkPCMValidationSessionID
        }
    }

    func currentSinkPCMStats() -> MiLinkPhoneRelayPCMStats? {
        queue.sync {
            latestSinkPCMStats
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
        sourceRTPArmedUntil = .distantPast
        sourceRTPArmReason = nil
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
        let pcmPayload = extractPhoneRelayPCM(fromMPEGTS: payload)
        guard !pcmPayload.isEmpty else {
            return
        }
        startMPEGTSPlayerIfNeeded(reason: "rtp_mpegts_pcm")
        guard let mpegTSPlayerInput else {
            return
        }
        do {
            let previousPCMTotal = mpegTSPCMBytesWritten
            try mpegTSPlayerInput.write(contentsOf: pcmPayload)
            mpegTSBytesWritten += payload.count
            mpegTSPCMBytesWritten += pcmPayload.count
            let sampleStats = pcmS16LEStats(pcmPayload)
            let stats = MiLinkPhoneRelayPCMStats(
                sessionID: sinkPCMValidationSessionID,
                pcmBytes: pcmPayload.count,
                totalPCMBytes: mpegTSPCMBytesWritten,
                pesPacketCount: mpegTSPCMPESPacketCount,
                samples: sampleStats.samples,
                nonzeroSamples: sampleStats.nonzeroSamples,
                maxAbs: sampleStats.maxAbs,
                averageAbs: sampleStats.averageAbs,
                fingerprint: DiagnosticsLog.fingerprint(pcmPayload),
                prefix: hexPrefix(pcmPayload)
            )
            latestSinkPCMStats = stats
            let isFirstValidStream = stats.hasValidStream && !sinkPCMValidStreamReported
            if isFirstValidStream {
                sinkPCMValidStreamReported = true
                DiagnosticsLog.info("phonerelay.mac.sink_pcm_valid \(stats.diagnosticSummary)")
            }
            let shouldLogStats = previousPCMTotal == 0 ||
                mpegTSPCMBytesWritten % 64_000 < pcmPayload.count ||
                isFirstValidStream
            if shouldLogStats || isFirstValidStream {
                onSinkPCMStats?(stats)
            }
            if shouldLogStats {
                DiagnosticsLog.info(
                    "phonerelay.mac.mpegts_pcm_playback_write tsBytes=\(payload.count) " +
                        "pcmBytes=\(stats.pcmBytes) pcmTotal=\(stats.totalPCMBytes) " +
                        "pes=\(stats.pesPacketCount) samples=\(stats.samples) " +
                        "nonzero=\(stats.nonzeroSamples) maxAbs=\(stats.maxAbs) avgAbs=\(stats.averageAbs) " +
                        "fp=\(stats.fingerprint) prefix=\(stats.prefix)"
                )
            }
        } catch {
            DiagnosticsLog.warn("phonerelay.mac.mpegts_pcm_playback_write_failed error=\(error)")
            stopMPEGTSPlayer(reason: "write_failed")
        }
    }

    private func extractPhoneRelayPCM(fromMPEGTS payload: Data) -> Data {
        let bytes = Array(payload)
        var output = Data()
        var offset = 0
        while offset + Self.mpegTSPacketSize <= bytes.count {
            guard bytes[offset] == 0x47 else {
                offset += 1
                continue
            }
            let packetStart = offset
            let packetEnd = offset + Self.mpegTSPacketSize
            let payloadUnitStart = (bytes[packetStart + 1] & 0x40) != 0
            let pid = (UInt16(bytes[packetStart + 1] & 0x1f) << 8) | UInt16(bytes[packetStart + 2])
            let adaptationFieldControl = (bytes[packetStart + 3] >> 4) & 0x03
            var payloadStart = packetStart + 4

            if adaptationFieldControl == 2 || adaptationFieldControl == 3 {
                guard payloadStart < packetEnd else {
                    offset = packetEnd
                    continue
                }
                payloadStart += 1 + Int(bytes[payloadStart])
            }
            guard (adaptationFieldControl == 1 || adaptationFieldControl == 3),
                  pid == Self.phoneRelayAudioTSPID,
                  payloadStart < packetEnd else {
                offset = packetEnd
                continue
            }

            if payloadUnitStart,
               payloadStart + 9 <= packetEnd,
               bytes[payloadStart] == 0x00,
               bytes[payloadStart + 1] == 0x00,
               bytes[payloadStart + 2] == 0x01 {
                let headerLength = Int(bytes[payloadStart + 8])
                let pcmStart = payloadStart + 9 + headerLength
                if pcmStart < packetEnd {
                    output.append(contentsOf: bytes[pcmStart..<packetEnd])
                    mpegTSPCMPESPacketCount += 1
                }
            } else {
                output.append(contentsOf: bytes[payloadStart..<packetEnd])
            }
            offset = packetEnd
        }
        return output
    }

    private func pcmS16LEStats(_ data: Data) -> (samples: Int, nonzeroSamples: Int, maxAbs: Int, averageAbs: Int) {
        let bytes = Array(data)
        var sampleCount = 0
        var nonzeroSamples = 0
        var maxAbs = 0
        var absTotal = 0
        var index = 0
        while index + 1 < bytes.count {
            let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            let sample = Int(Int16(bitPattern: raw))
            let magnitude = abs(sample)
            sampleCount += 1
            if sample != 0 {
                nonzeroSamples += 1
            }
            maxAbs = max(maxAbs, magnitude)
            absTotal += magnitude
            index += 2
        }
        return (
            samples: sampleCount,
            nonzeroSamples: nonzeroSamples,
            maxAbs: maxAbs,
            averageAbs: sampleCount > 0 ? absTotal / sampleCount : 0
        )
    }

    private func writeMPEGTSFileCapture(_ payload: Data) {
        guard mpegTSCaptureEnabled else {
            return
        }
        if mpegTSCaptureBytes >= Self.mpegTSCaptureLimitBytes ||
            mpegTSCaptureBytes + payload.count > Self.mpegTSCaptureLimitBytes {
            if !mpegTSCaptureLimitLogged {
                mpegTSCaptureLimitLogged = true
                DiagnosticsLog.info(
                    "phonerelay.mac.mpegts_capture_limit path=\(Self.mpegTSCapturePath) bytes=\(mpegTSCaptureBytes)"
                )
            }
            stopMPEGTSFileCapture(reason: "limit")
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
        let path = Self.mpegTSCapturePath
        if mpegTSCaptureHandle != nil {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            DiagnosticsLog.warn("phonerelay.mac.mpegts_capture_missing path=\(path)")
            stopMPEGTSFileCapture(reason: "missing_file")
        }
        do {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            FileManager.default.createFile(atPath: path, contents: nil)
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
        let errorPipe = Pipe()
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        process.executableURL = ffplayURL
        process.arguments = [
            "-nodisp",
            "-loglevel", "warning",
            "-nostats",
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-f", "s16le",
            "-ar", "8000",
            "-ch_layout", "mono",
            "-i", "pipe:0"
        ]
        process.standardInput = inputPipe
        process.standardError = errorPipe
        if let devNull {
            process.standardOutput = devNull
        }
        let errorOutput = errorPipe.fileHandleForReading
        errorOutput.readabilityHandler = { [weak self, weak errorOutput] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            self?.queue.async {
                guard let self, let errorOutput, self.mpegTSPlayerErrorOutput === errorOutput else {
                    return
                }
                self.logMPEGTSPlayerStderr(data)
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.queue.async {
                guard self?.mpegTSPlayerProcess === terminatedProcess else {
                    return
                }
                DiagnosticsLog.info("phonerelay.mac.mpegts_playback_exit status=\(terminatedProcess.terminationStatus)")
                self?.mpegTSPlayerErrorOutput?.readabilityHandler = nil
                try? self?.mpegTSPlayerErrorOutput?.close()
                self?.mpegTSPlayerProcess = nil
                self?.mpegTSPlayerInput = nil
                self?.mpegTSPlayerErrorOutput = nil
                self?.mpegTSPlayerDevNull = nil
                self?.mpegTSBytesWritten = 0
                self?.mpegTSPCMBytesWritten = 0
                self?.mpegTSPCMPESPacketCount = 0
                self?.mpegTSPlayerStderrBytesLogged = 0
            }
        }
        do {
            try process.run()
            mpegTSPlayerProcess = process
            mpegTSPlayerInput = inputPipe.fileHandleForWriting
            mpegTSPlayerErrorOutput = errorOutput
            mpegTSPlayerDevNull = devNull
            mpegTSBytesWritten = 0
            mpegTSPCMBytesWritten = 0
            mpegTSPCMPESPacketCount = 0
            mpegTSPlayerStderrBytesLogged = 0
            DiagnosticsLog.info(
                "phonerelay.mac.mpegts_pcm_playback_start path=\(ffplayURL.path) " +
                    "format=s16le sampleRate=8000 channelLayout=mono reason=\(reason)"
            )
        } catch {
            errorOutput.readabilityHandler = nil
            try? errorOutput.close()
            DiagnosticsLog.warn("phonerelay.mac.mpegts_playback_start_failed path=\(ffplayURL.path) error=\(error)")
            mpegTSPlayerProcess = nil
            mpegTSPlayerInput = nil
            mpegTSPlayerErrorOutput = nil
            mpegTSPlayerDevNull = nil
            mpegTSBytesWritten = 0
            mpegTSPCMBytesWritten = 0
            mpegTSPCMPESPacketCount = 0
            mpegTSPlayerStderrBytesLogged = 0
        }
    }

    private func logMPEGTSPlayerStderr(_ data: Data) {
        guard mpegTSPlayerStderrBytesLogged < Self.mpegTSPlayerStderrLogLimitBytes else {
            return
        }
        let remainingBytes = Self.mpegTSPlayerStderrLogLimitBytes - mpegTSPlayerStderrBytesLogged
        let chunk = data.prefix(remainingBytes)
        mpegTSPlayerStderrBytesLogged += chunk.count
        let text = String(decoding: chunk, as: UTF8.self)
        DiagnosticsLog.warn("phonerelay.mac.mpegts_playback_stderr preview=\(sanitizeRTSPLogValue(text))")
        if mpegTSPlayerStderrBytesLogged >= Self.mpegTSPlayerStderrLogLimitBytes {
            DiagnosticsLog.warn("phonerelay.mac.mpegts_playback_stderr_truncated bytes=\(mpegTSPlayerStderrBytesLogged)")
        }
    }

    private func stopMPEGTSPlayer(reason: String) {
        let process = mpegTSPlayerProcess
        let hadProcess = process != nil
        try? mpegTSPlayerInput?.close()
        mpegTSPlayerInput = nil
        mpegTSPlayerErrorOutput?.readabilityHandler = nil
        try? mpegTSPlayerErrorOutput?.close()
        mpegTSPlayerErrorOutput = nil
        mpegTSPlayerDevNull = nil
        mpegTSPlayerProcess = nil
        mpegTSBytesWritten = 0
        mpegTSPCMBytesWritten = 0
        mpegTSPCMPESPacketCount = 0
        mpegTSPlayerStderrBytesLogged = 0
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
        guard isSourceRTPArmed else {
            DiagnosticsLog.info(
                "phonerelay.mac.source_rtp_unarmed id=\(id.uuidString) reason=\(reason) " +
                    "armReason=\(sourceRTPArmReason ?? "none")"
            )
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
        sourceAudioTSContinuityCounter = 0
        sourcePATContinuityCounter = 0
        sourcePMTContinuityCounter = 0
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

    private func startExternalSourceRTPOnQueue(reason: String, packetHandler: @escaping (Data) -> Void) {
        if sourceRTPPacketHandler != nil, sourceRTPProcess?.isRunning == true {
            return
        }
        stopSourceRTP(reason: "external_restart")
        let id = UUID()
        sourceRTPPacketHandler = packetHandler
        sourceRTPConnectionID = id
        sourceRTPSequenceNumber = 0
        sourceRTPTimestamp = UInt32.random(in: 0..<UInt32.max)
        sourceRTPPacketsSent = 0
        sourceAudioTSContinuityCounter = 0
        sourcePATContinuityCounter = 0
        sourcePMTContinuityCounter = 0
        sourceRTPBuffer.removeAll(keepingCapacity: true)
        DiagnosticsLog.info("phonerelay.mac.source_rtp_external_ready id=\(id.uuidString) reason=\(reason)")
        startSourceMPEGTSProcess(id: id, reason: "external_\(reason)")
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
                    self.sendSourcePCMTransport(data)
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
                "-i", "anullsrc=channel_layout=mono:sample_rate=8000",
                "-ac", "1",
                "-ar", "8000",
                "-f", "s16le",
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
                "-ac", "1",
                "-ar", "8000",
                "-f", "s16le",
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

    private func sendSourcePCMTransport(_ data: Data) {
        sourceRTPBuffer.append(data)
        while sourceRTPBuffer.count >= Self.sourcePCMBytesPerFrame {
            let pcm = Data(sourceRTPBuffer.prefix(Self.sourcePCMBytesPerFrame))
            sourceRTPBuffer.removeFirst(Self.sourcePCMBytesPerFrame)
            sendSourcePCMFrame(pcm)
        }
    }

    private func sendSourcePCMFrame(_ pcm: Data) {
        var payload = Data()
        if sourceRTPPacketsSent % Self.sourceProgramHeaderIntervalFrames == 0 {
            payload.append(sourcePATPacket())
            payload.append(sourcePMTPacket())
            payload.append(sourcePCRPacket(base: UInt64(sourceRTPTimestamp)))
        }
        let pcmTimeUs = UInt64(sourceRTPPacketsSent) * Self.sourcePCMFrameDurationMicroseconds
        let includesPCMFormat = sourceRTPPacketsSent % Self.sourcePCMFormatIntervalFrames == 0
        for packet in sourcePCMPESPackets(
            pcm: pcm,
            pts: UInt64(sourceRTPTimestamp),
            pcmTimeUs: pcmTimeUs,
            includesPCMFormat: includesPCMFormat
        ) {
            payload.append(packet)
        }
        sendSourceRTPPayload(payload)
    }

    private func sourcePATPacket() -> Data {
        var packet = Data([
            0x47, 0x40, 0x00, 0x10 | (sourcePATContinuityCounter & 0x0f),
            0x00, 0x00, 0xb0, 0x0d, 0x00, 0x00, 0xc3, 0x00, 0x00,
            0x00, 0x01, 0xe1, 0x00, 0x2d, 0xf6, 0x52, 0x95
        ])
        sourcePATContinuityCounter &+= 1
        packet.append(contentsOf: repeatElement(0xff, count: Self.mpegTSPacketSize - packet.count))
        return packet
    }

    private func sourcePMTPacket() -> Data {
        var packet = Data([
            0x47, 0x41, 0x00, 0x10 | (sourcePMTContinuityCounter & 0x0f),
            0x00, 0x02, 0xb0, 0x12, 0x00, 0x01, 0xc3, 0x00, 0x00,
            // Xiaomi's TS packetizer uses private stream type 0x83 for
            // audio/raw. Advertising 0x0f routes these bytes through its AAC
            // elementary-stream parser even when RTSP selected LPCM.
            0xf0, 0x00, 0xf0, 0x00, 0x83, 0xf1, 0x00, 0xf0, 0x00,
            0xc8, 0xae, 0x18, 0xf4
        ])
        sourcePMTContinuityCounter &+= 1
        packet.append(contentsOf: repeatElement(0xff, count: Self.mpegTSPacketSize - packet.count))
        return packet
    }

    private func sourcePCRPacket(base: UInt64) -> Data {
        let pcrBase = base & 0x1ffffffff
        var packet = Data([0x47, 0x50, 0x00, 0x20, 0xb7, 0x10])
        packet.append(UInt8((pcrBase >> 25) & 0xff))
        packet.append(UInt8((pcrBase >> 17) & 0xff))
        packet.append(UInt8((pcrBase >> 9) & 0xff))
        packet.append(UInt8((pcrBase >> 1) & 0xff))
        packet.append(UInt8(((pcrBase & 1) << 7) | 0x7e))
        packet.append(0x00)
        packet.append(contentsOf: repeatElement(0xff, count: Self.mpegTSPacketSize - packet.count))
        return packet
    }

    private func sourcePCMPESPackets(
        pcm: Data,
        pts: UInt64,
        pcmTimeUs: UInt64,
        includesPCMFormat: Bool
    ) -> [Data] {
        precondition(pcm.count == Self.sourcePCMBytesPerFrame)
        let pcmHeader = sourcePCMAccessUnitHeader(
            timeUs: pcmTimeUs,
            includesFormat: includesPCMFormat
        )
        let pesPacketLength = UInt16(3 + 5 + pcmHeader.count + pcm.count)
        var pes = Data([
            // Match Xiaomi's audio/raw TSPacketizer: private_stream_1.
            0x00, 0x00, 0x01, 0xbd
        ])
        appendUInt16BE(pesPacketLength, to: &pes)
        pes.append(contentsOf: [
            0x84, 0x80, 0x05
        ])
        pes.append(contentsOf: sourceEncodedPTS(pts))
        pes.append(pcmHeader)
        pes.append(pcm)

        let firstPayloadCount = Self.mpegTSPacketSize - 4
        var first = Data([
            0x47, 0x51, 0x00, 0x10 | (sourceAudioTSContinuityCounter & 0x0f)
        ])
        sourceAudioTSContinuityCounter &+= 1
        first.append(pes.prefix(firstPayloadCount))

        let remainder = Data(pes.dropFirst(firstPayloadCount))
        let adaptationLength = Self.mpegTSPacketSize - 4 - 1 - remainder.count
        var second = Data([
            0x47, 0x11, 0x00, 0x30 | (sourceAudioTSContinuityCounter & 0x0f),
            UInt8(adaptationLength), 0x00
        ])
        sourceAudioTSContinuityCounter &+= 1
        if adaptationLength > 1 {
            second.append(contentsOf: repeatElement(0xff, count: adaptationLength - 1))
        }
        second.append(remainder)
        return [first, second]
    }

    private func sourcePCMAccessUnitHeader(timeUs: UInt64, includesFormat: Bool) -> Data {
        // This is the private framing produced by Xiaomi MirrorIO::addPcmHead.
        // A format-bearing header is 32 bytes; subsequent access units only
        // need the 18-byte descriptor. Refresh the format periodically so a
        // restarted Xiaomi sink can resume without flooding logcat per frame.
        var header: Data
        if includesFormat {
            header = Data([
                0xff, 0x03,
                0x00, 0x00, 0x00, 0x0e,
                0x01, 0x10,
                0x00, 0x00, 0x1f, 0x40,
                0x00, 0x00, 0x00, 0xa0,
                0x00, 0x00, 0x00, 0x10,
                0x00, 0x00, 0x01, 0x40
            ])
        } else {
            header = Data([
                0xff, 0x02,
                0x00, 0x00, 0x00, 0x10,
                0x00, 0x00, 0x01, 0x40
            ])
        }
        appendUInt64BE(timeUs, to: &header)
        return header
    }

    private func sourceEncodedPTS(_ value: UInt64) -> [UInt8] {
        let pts = value & 0x1ffffffff
        return [
            0x20 | UInt8(((pts >> 30) & 0x07) << 1) | 0x01,
            UInt8((pts >> 22) & 0xff),
            UInt8(((pts >> 15) & 0x7f) << 1) | 0x01,
            UInt8((pts >> 7) & 0xff),
            UInt8((pts & 0x7f) << 1) | 0x01
        ]
    }

    private func sendSourceRTPPayload(_ payload: Data) {
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
        if let sourceRTPPacketHandler {
            sourceRTPPacketHandler(packet)
        } else if let connection = sourceRTPConnection {
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    DiagnosticsLog.warn("phonerelay.mac.source_rtp_send_failed seq=\(sequenceNumber) error=\(error)")
                }
            })
        } else {
            return
        }
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
        let hadSource = sourceRTPConnection != nil || sourceRTPPacketHandler != nil || sourceRTPProcess != nil || sourceAudioEngine != nil
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
        sourceRTPPacketHandler = nil
        sourceRTPBuffer.removeAll(keepingCapacity: true)
        sourceRTPSequenceNumber = 0
        sourceRTPTimestamp = 0
        sourceRTPPacketsSent = 0
        sourceAudioTSContinuityCounter = 0
        sourcePATContinuityCounter = 0
        sourcePMTContinuityCounter = 0
        sourcePCMBytesWritten = 0
        if hadSource {
            DiagnosticsLog.info("phonerelay.mac.source_rtp_stop reason=\(reason)")
        }
    }

    private func armSourceRTPOnQueue(reason: String, duration: TimeInterval) {
        let boundedDuration = min(max(duration, 1), Self.sourceRTPMaxArmDurationSeconds)
        let until = Date().addingTimeInterval(boundedDuration)
        if until > sourceRTPArmedUntil {
            sourceRTPArmedUntil = until
            sourceRTPArmReason = reason
        }
        DiagnosticsLog.info(
            "phonerelay.mac.source_rtp_armed reason=\(reason) duration=\(Int(boundedDuration)) " +
                "until=\(Self.armDateFormatter.string(from: sourceRTPArmedUntil))"
        )
    }

    private func disarmSourceRTPOnQueue(reason: String, stopActive: Bool) {
        let wasArmed = isSourceRTPArmed
        sourceRTPArmedUntil = .distantPast
        sourceRTPArmReason = nil
        if stopActive {
            stopSourceRTP(reason: "disarm_\(reason)")
        }
        if wasArmed || stopActive {
            DiagnosticsLog.info("phonerelay.mac.source_rtp_disarmed reason=\(reason) stopActive=\(stopActive)")
        }
    }

    private var isSourceRTPArmed: Bool {
        sourceRTPArmedUntil > Date()
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

    private func appendUInt64BE(_ value: UInt64, to data: inout Data) {
        data.append(UInt8((value >> 56) & 0xff))
        data.append(UInt8((value >> 48) & 0xff))
        data.append(UInt8((value >> 40) & 0xff))
        data.append(UInt8((value >> 32) & 0xff))
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
            if bodyText.localizedCaseInsensitiveContains("wfd_trigger_method: TEARDOWN") {
                stopMPEGTSPlayer(reason: "trigger_teardown")
                stopMPEGTSFileCapture(reason: "trigger_teardown")
                stopSourceRTPIfOwned(by: id, reason: "trigger_teardown")
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

    private func handleRTSPResponse(
        connection: NWConnection,
        id: UUID,
        headerText: String,
        bodyText: String,
        cseq: String
    ) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        let requestMethod = state.pendingRequests.removeValue(forKey: cseq)
        if let session = rtspHeader("Session", in: headerText)?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces),
           !session.isEmpty {
            state.sessionID = session
        }
        tcpStates[id] = state

        switch requestMethod {
        case "GET_PARAMETER":
            recordSourceRTPDestination(fromWFDParameters: bodyText, connection: connection, id: id)
            sendSourceSETParameterIfNeeded(connection: connection, id: id, reason: "get_parameter_response")
        case "SET_PARAMETER":
            sendSourceSETUPIfNeeded(connection: connection, id: id, reason: "set_parameter_response")
        case "SETUP":
            if tcpStates[id]?.isPeerSourceConnection == true {
                sendPLAYIfNeeded(connection: connection, id: id, reason: "setup_response")
            } else {
                logSourceNonSuccessResponseIfNeeded(headerText: headerText, id: id, requestMethod: "SETUP")
                sendSourcePLAYIfNeeded(connection: connection, id: id, reason: "setup_response")
            }
        case "PLAY":
            if tcpStates[id]?.isPeerSourceConnection == false {
                logSourceNonSuccessResponseIfNeeded(headerText: headerText, id: id, requestMethod: "PLAY")
                startSourceRTPIfReady(id: id, reason: "play_response")
            }
        default:
            break
        }
    }

    private func logSourceNonSuccessResponseIfNeeded(headerText: String, id: UUID, requestMethod: String) {
        let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
        guard let status = rtspStatusCode(in: firstLine), status >= 300 else {
            return
        }
        DiagnosticsLog.info(
            "phonerelay.mac.source_rtsp_non_success_continue id=\(id.uuidString) " +
                "request=\(requestMethod) status=\(status) firstLine=\(sanitizeRTSPLogValue(firstLine))"
        )
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
        let presentationURL = sourcePresentationURL()
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

    private func sendSourceSETUPIfNeeded(connection: NWConnection, id: UUID, reason: String) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        guard !state.isPeerSourceConnection,
              state.sentSourceSETParameter,
              !state.sentSourceSETUP else {
            return
        }
        guard let rtpPort = state.sourceRemoteRTPPort else {
            DiagnosticsLog.warn("phonerelay.mac.source_setup_missing_destination id=\(id.uuidString) reason=\(reason)")
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
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        guard !state.isPeerSourceConnection,
              state.sentSourceSETUP,
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
        let bodyText = rtspBody(in: message)
        if !bodyText.isEmpty {
            DiagnosticsLog.info(
                "phonerelay.mac.rtsp_body dir=out id=\(id.uuidString) label=\(label) " +
                    "preview=\(sanitizeRTSPLogValue(bodyText))"
            )
        }
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
        armSourceRTPOnQueue(reason: "rtsp_setup_destination", duration: Self.sourceRTPRequestArmDurationSeconds)
        DiagnosticsLog.info(
            "phonerelay.mac.source_rtp_destination id=\(id.uuidString) remote=\(host):\(rtpPort) " +
                "transport=\(sanitizeRTSPLogValue(transport))"
        )
    }

    private func recordSourceRTPDestination(fromWFDParameters bodyText: String, connection: NWConnection, id: UUID) {
        var state = tcpStates[id] ?? TCPConnectionState(sendsGreetingOnReady: false, isPeerSourceConnection: false)
        guard !state.isPeerSourceConnection else {
            return
        }
        guard let line = bodyText.components(separatedBy: .newlines).first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("wfd_client_rtp_ports:")
        }),
              let value = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init),
              let rtpPort = firstRTPPortToken(in: value),
              let host = endpointHostString(connection.endpoint) else {
            DiagnosticsLog.warn(
                "phonerelay.mac.source_rtp_destination_missing id=\(id.uuidString) " +
                    "wfdClientPorts=\(sanitizeRTSPLogValue(wfdClientRTPPortsLine(in: bodyText) ?? "none"))"
            )
            return
        }
        state.sourceRemoteHost = host
        state.sourceRemoteRTPPort = rtpPort
        tcpStates[id] = state
        DiagnosticsLog.info(
            "phonerelay.mac.source_rtp_destination id=\(id.uuidString) remote=\(host):\(rtpPort) " +
                "wfdClientPorts=\(sanitizeRTSPLogValue(value))"
        )
    }

    private func wfdClientRTPPortsLine(in bodyText: String) -> String? {
        bodyText.components(separatedBy: .newlines).first {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("wfd_client_rtp_ports:")
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
        if let override = UserDefaults.standard.string(forKey: "phoneRelayProbeSourceHost")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return Self.preferredLocalIPv4Address() ?? "localhost"
    }

    private func sourcePresentationURL() -> String {
        "rtsp://\(sourcePresentationHost())/wfd1.0/streamid=0"
    }

    static func preferredLocalIPv4Address() -> String? {
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
    private static let sourceRTPArmDurationSeconds: TimeInterval = 45
    private static let sourceRTPRequestArmDurationSeconds: TimeInterval = 15
    private static let sourceRTPMaxArmDurationSeconds: TimeInterval = 120
    private static let sourceRTPSSRC: UInt32 = 0xed9e_1101
    private static let sourcePCMBytesPerFrame = 320
    private static let sourcePCMFrameDurationMicroseconds: UInt64 = 20_000
    private static let sourcePCMFormatIntervalFrames = 50
    private static let sourceProgramHeaderIntervalFrames = 5
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
    private static let mpegTSPlayerStderrLogLimitBytes = 4 * 1024
    private static let mpegTSCapturePath = "/private/tmp/edgelink-phonerelay.ts"
    private static let mpegTSPacketSize = 188
    private static let phoneRelayAudioTSPID: UInt16 = 0x1100
    private static let armDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private enum SourceRTPAudioMode: String {
    case silent
    case microphone

    init(defaultsValue: String?) {
        switch defaultsValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mic", "microphone", "input", "mac_microphone", "mac-microphone":
            self = .microphone
        case "silent", "off", "none", "disabled":
            self = .silent
        default:
            self = .microphone
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
    var sentSourceSETUP = false
    var sentSourcePLAY = false
    var sentSinkSETUP = false
    var sentPLAY = false
    let sendsGreetingOnReady: Bool
    let isPeerSourceConnection: Bool
}

private enum MiLinkPhoneRelayProbeError: Error {
    case invalidPort(UInt16)
}
