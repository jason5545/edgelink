import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import EdgeLinkKit
import Foundation
import Network
import VideoToolbox

private enum XiaomiMirrorRTSPTransportMode: String {
    case udp
    case mpt
}

private enum XiaomiMirrorRTSPProtocolProfile: String {
    case edge
    case official
}

private enum XiaomiMirrorVideoDefaults {
    static let width: Int32 = 640
    static let height: Int32 = 360
    static let frameRate: Int32 = 30
    static let bitrate = 5_000_000

    private static let hh640x360p30Mask = "00000040"

    static let h264VideoFormats = [
        "a8",
        "00",
        "01",
        "01",
        "00000000",
        "00000000",
        hh640x360p30Mask,
        "00",
        "0000",
        "0000",
        "00",
        "none",
        "none"
    ].joined(separator: " ")

    static var currentVideoInfo: String {
        "\(width) \(height) \(frameRate) \(bitrate)"
    }
}

private enum XiaomiMirrorOfficialRTSPDefaults {
    static let videoFormats = "40 0 2 10 1ffff 1fffffff 0fff 0 0 0 0 none none"
    static let currentVideoInfo = "-1 -1 -1 -1"
    static let audioCodecsV2 = "2 0 0 0"
    static let selectedAudioCodecsV2 = "0 1"
    static let contentSPProtection = "4 1 256 3 1 1 1 1"
    static let typeEncryption = "4 1 1 1 1"
    static let bufferCapability = "1F"
    static let fallbackClientRTPPorts = "RTP/AVP/MPT;unicast 15550 0 mode=play"
    static let screenAuthKey = Data("EdgeLinkMirrorK!".utf8)
}

struct XiaomiMirrorRTSPRecoveryEvent {
    let sessionID: UUID
    let trigger: String
    let reason: String
    let retryAttempt: Int
    let host: String?
    let port: UInt16?
    let elapsedMediaSeconds: Double
    let elapsedFrameSeconds: Double?
    let datagramsReceived: UInt64
    let pushReceived: UInt64
    let inboundRTP: UInt64
    let decodedFrames: UInt64
}

private struct XiaomiMirrorMPTStallSnapshot {
    let sessionID: UUID
    let reason: String
    let elapsedMediaSeconds: Double
    let elapsedFrameSeconds: Double?
    let datagramsReceived: UInt64
    let pushReceived: UInt64
    let inboundRTP: UInt64
    let decodedFrames: UInt64
}

private struct XiaomiMirrorHEVCParameterSets {
    let vps: Data
    let sps: Data
    let pps: Data
}

final class XiaomiMirrorRTSPDiagnosticSource: @unchecked Sendable {
    var onDecodedFrame: ((CVPixelBuffer, Int, Int) -> Void)?
    var onRecoveryRequired: ((XiaomiMirrorRTSPRecoveryEvent) -> Void)?
    var onPeerStop: ((String, UUID, UInt64) -> Void)?
    var onCloudflareMirrorOutboundDatagram: ((Data, String) -> Void)?

    private let queue = DispatchQueue(label: "EdgeLink.XiaomiMirrorRTSPDiagnosticSource")
    private let queueKey = DispatchSpecificKey<Void>()
    private var listener: NWListener?
    private var listenerReady = false
    private var connections: [UUID: NWConnection] = [:]
    private var states: [UUID: RTSPConnectionState] = [:]
    private var sessionLifecycle = SessionLifecycleFence<UUID>()
    private var stopWorkItem: DispatchWorkItem?
    private var activeClientRetryWorkItems: [UUID: DispatchWorkItem] = [:]
    private var rtspKeepaliveWorkItems: [UUID: DispatchWorkItem] = [:]
    private var port: UInt16 = 7102
    private var advertisedHost: String?
    private var cloudflareMirrorSessionId: String?
    private var cloudflareMirrorReceiverID: UUID?
    private var cloudflareMirrorReceiver: XiaomiMirrorRTPMediaSender?
    private var cloudflareMirrorHEVCParameterSets: XiaomiMirrorHEVCParameterSets?
    private var cloudflareMirrorPacketsReceived: UInt64 = 0

    private let sourceRTPPort: UInt16 = 19_002
    private let officialMPTClientPort: UInt16 = 15_550
    private let officialMPTMaxRTSPRetries = 3
    private let officialMPTRTSPRetryDelay: TimeInterval = 1
    private let rtspSessionKeepaliveInterval: TimeInterval = 10
    private let rtspSessionKeepaliveMaxMisses = 3
    private let sessionRecoveryNotificationMinInterval: TimeInterval = 2
    private let transportModeDefaultsKey = "xiaomiMirrorRTSPTransportMode"
    private let protocolProfileDefaultsKey = "xiaomiMirrorRTSPProtocolProfile"
    private let authKeyDefaultsKey = "xiaomiMirrorRTSPAuthKey"

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    func start(port: UInt16 = 7102, advertisedHost: String?, lifetime: TimeInterval) throws {
        try performOnQueue {
            try self.startOnQueue(port: port, advertisedHost: advertisedHost, lifetime: lifetime)
        }
    }

    func isListenerReady() -> Bool {
        performOnQueue { listenerReady }
    }

    func hasActiveSession() -> Bool {
        performOnQueue {
            sessionLifecycle.hasActiveSessions || cloudflareMirrorReceiver != nil
        }
    }

    func shouldHonorPeerStop(generation: UInt64) -> Bool {
        performOnQueue {
            sessionLifecycle.shouldHonorStop(from: generation)
        }
    }

    func connect(host: String, port: UInt16, advertisedHost: String?, lifetime: TimeInterval) throws {
        try performOnQueue {
            try self.connectOnQueue(
                host: host,
                port: port,
                advertisedHost: advertisedHost,
                lifetime: lifetime,
                retryAttempt: 0
            )
        }
    }

    func stop(reason: String) {
        performOnQueue {
            self.stopOnQueue(reason: reason)
        }
    }

    func startCloudflareMirrorRTPReceiver(sessionId: String, lifetime: TimeInterval, reason: String) {
        performOnQueue {
            self.startCloudflareMirrorRTPReceiverOnQueue(
                sessionId: sessionId,
                lifetime: lifetime,
                reason: reason
            )
        }
    }

    func handleCloudflareMirrorMedia(_ body: MiLinkMirrorMediaBody) {
        performOnQueue {
            self.handleCloudflareMirrorMediaOnQueue(body)
        }
    }

    func stopCloudflareMirrorRTPReceiver(reason: String) {
        performOnQueue {
            self.stopCloudflareMirrorRTPReceiverOnQueue(reason: reason)
        }
    }

    private func startCloudflareMirrorRTPReceiverOnQueue(
        sessionId: String,
        lifetime: TimeInterval,
        reason: String
    ) {
        if cloudflareMirrorSessionId == sessionId, cloudflareMirrorReceiver != nil {
            scheduleAutoStop(lifetime: lifetime)
            DiagnosticsLog.info(
                "xiaomi.mirror.cloudflare.receiver_reuse sessionId=\(sessionId) " +
                    "reason=\(reason) packets=\(cloudflareMirrorPacketsReceived)"
            )
            return
        }

        stopCloudflareMirrorRTPReceiverOnQueue(reason: "replace_\(reason)")
        let receiverID = UUID(uuidString: sessionId) ?? UUID()
        do {
            let receiver = try XiaomiMirrorRTPMediaSender(
                transportMode: .mpt,
                destinationHost: "127.0.0.1",
                destinationRTPPort: 1,
                destinationRTCPPort: 1,
                localRTPPort: 0,
                localRTCPPort: 0,
                sessionID: receiverID,
                mptSinkOnly: true,
                onDecodedFrame: { [weak self] pixelBuffer, width, height in
                    self?.onDecodedFrame?(pixelBuffer, width, height)
                },
                onMPTMediaStalled: { [weak self] stall in
                    self?.queue.async {
                        self?.handleCloudflareMirrorStalled(stall)
                    }
                },
                initialHEVCParameterSets: cloudflareMirrorHEVCParameterSets,
                onMPTHEVCParameterSets: { [weak self] parameterSets in
                    self?.queue.async {
                        self?.cloudflareMirrorHEVCParameterSets = parameterSets
                        DiagnosticsLog.info(
                            "xiaomi.mirror.cloudflare.hevc_parameter_sets_cached sessionId=\(sessionId) " +
                                "vps=\(parameterSets.vps.count) sps=\(parameterSets.sps.count) pps=\(parameterSets.pps.count)"
                        )
                    }
                }
            )
            cloudflareMirrorSessionId = sessionId
            cloudflareMirrorReceiverID = receiverID
            cloudflareMirrorReceiver = receiver
            cloudflareMirrorPacketsReceived = 0
            receiver.onExternalDatagramSend = { [weak self] packet in
                self?.queue.async {
                    guard let self, self.cloudflareMirrorSessionId == sessionId else {
                        return
                    }
                    self.onCloudflareMirrorOutboundDatagram?(packet, sessionId)
                }
            }
            receiver.startExternalRTPReceiver(reason: reason)
            scheduleAutoStop(lifetime: lifetime)
            DiagnosticsLog.info(
                "xiaomi.mirror.cloudflare.receiver_start sessionId=\(sessionId) " +
                    "receiverId=\(receiverID.uuidString) reason=\(reason) lifetime=\(Int(lifetime))"
            )
        } catch {
            DiagnosticsLog.error(
                "xiaomi.mirror.cloudflare.receiver_start_failed sessionId=\(sessionId) reason=\(reason)",
                error
            )
        }
    }

    private func handleCloudflareMirrorMediaOnQueue(_ body: MiLinkMirrorMediaBody) {
        guard body.sessionId == cloudflareMirrorSessionId else {
            DiagnosticsLog.info(
                "xiaomi.mirror.cloudflare.media_ignored sessionId=\(body.sessionId) " +
                    "active=\(cloudflareMirrorSessionId ?? "none") kind=\(body.kind)"
            )
            return
        }
        if body.kind == "status" {
            DiagnosticsLog.info(
                "xiaomi.mirror.cloudflare.status sessionId=\(body.sessionId) event=\(body.event ?? "none")"
            )
            if body.event == "source_stop" || body.event == "bridge_failed" || body.event == "bridge_stopped" {
                stopCloudflareMirrorRTPReceiverOnQueue(reason: "android_\(body.event ?? body.kind)")
            }
            return
        }
        guard body.direction == "android_to_mac",
              body.kind == "rtp" || body.kind == "rtp_batch",
              let dataBase64 = body.dataBase64,
              let packet = Data(base64Encoded: dataBase64),
              let receiver = cloudflareMirrorReceiver else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.cloudflare.media_invalid sessionId=\(body.sessionId) " +
                    "direction=\(body.direction) kind=\(body.kind) bytes=\(body.bytes.map(String.init) ?? "none")"
            )
            return
        }
        cloudflareMirrorPacketsReceived += 1
        if cloudflareMirrorPacketsReceived == 1 || cloudflareMirrorPacketsReceived % 100 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.cloudflare.rtp_in sessionId=\(body.sessionId) " +
                    "count=\(cloudflareMirrorPacketsReceived) sequence=\(body.sequence.map(String.init) ?? "none") " +
                    "bytes=\(packet.count) kind=\(body.kind) fp=\(DiagnosticsLog.fingerprint(packet))"
            )
        }
        if body.kind == "rtp_batch" {
            var offset = 0
            while offset + 2 <= packet.count,
                  let datagramLength = packet.readUInt16BE(at: offset),
                  offset + 2 + Int(datagramLength) <= packet.count {
                let start = offset + 2
                let end = start + Int(datagramLength)
                receiver.pushExternalRTPPacket(packet.subdata(in: start..<end), sequence: body.sequence)
                offset = end
            }
            if offset != packet.count {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.cloudflare.rtp_batch_malformed sessionId=\(body.sessionId) " +
                        "bytes=\(packet.count) consumed=\(offset)"
                )
            }
            return
        }
        receiver.pushExternalRTPPacket(packet, sequence: body.sequence)
    }

    private func stopCloudflareMirrorRTPReceiverOnQueue(reason: String) {
        guard let receiver = cloudflareMirrorReceiver else {
            cloudflareMirrorSessionId = nil
            cloudflareMirrorReceiverID = nil
            cloudflareMirrorPacketsReceived = 0
            return
        }
        let sessionId = cloudflareMirrorSessionId ?? "none"
        receiver.stop(reason: "cloudflare_\(reason)")
        DiagnosticsLog.info(
            "xiaomi.mirror.cloudflare.receiver_stop sessionId=\(sessionId) " +
                "reason=\(reason) packets=\(cloudflareMirrorPacketsReceived)"
        )
        cloudflareMirrorSessionId = nil
        cloudflareMirrorReceiverID = nil
        cloudflareMirrorReceiver = nil
        cloudflareMirrorPacketsReceived = 0
    }

    private func handleCloudflareMirrorStalled(_ stall: XiaomiMirrorMPTStallSnapshot) {
        guard cloudflareMirrorReceiverID == stall.sessionID else {
            return
        }
        DiagnosticsLog.warn(
            "xiaomi.mirror.cloudflare.stalled sessionId=\(cloudflareMirrorSessionId ?? "none") " +
                "reason=\(stall.reason) elapsedMediaSeconds=\(Self.formatSeconds(stall.elapsedMediaSeconds)) " +
                "elapsedFrameSeconds=\(Self.formatOptionalSeconds(stall.elapsedFrameSeconds)) " +
                "inboundRTP=\(stall.inboundRTP) decodedFrames=\(stall.decodedFrames)"
        )
        onRecoveryRequired?(
            XiaomiMirrorRTSPRecoveryEvent(
                sessionID: stall.sessionID,
                trigger: "cloudflare_mirror_stall",
                reason: stall.reason,
                retryAttempt: 0,
                host: nil,
                port: nil,
                elapsedMediaSeconds: stall.elapsedMediaSeconds,
                elapsedFrameSeconds: stall.elapsedFrameSeconds,
                datagramsReceived: stall.datagramsReceived,
                pushReceived: stall.pushReceived,
                inboundRTP: stall.inboundRTP,
                decodedFrames: stall.decodedFrames
            )
        )
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
                    "protocolProfile=\(protocolProfile.rawValue) transportMode=\(transportMode.rawValue)"
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
        listenerReady = false
        configure(listener)
        scheduleAutoStop(lifetime: lifetime)
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.listener_start port=\(port) advertisedHost=\(host ?? "none") " +
                "lifetime=\(Int(lifetime)) protocolProfile=\(protocolProfile.rawValue) transportMode=\(transportMode.rawValue)"
        )
        listener.start(queue: queue)
    }

    private func connectOnQueue(
        host: String,
        port: UInt16,
        advertisedHost: String?,
        lifetime: TimeInterval,
        retryAttempt: Int
    ) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw XiaomiMirrorRTSPDiagnosticSourceError.invalidHost(host)
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw XiaomiMirrorRTSPDiagnosticSourceError.invalidPort(port)
        }
        let trimmedAdvertisedHost = advertisedHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.advertisedHost = trimmedAdvertisedHost?.isEmpty == false ? trimmedAdvertisedHost : self.advertisedHost
        scheduleAutoStop(lifetime: lifetime)

        let id = UUID()
        let connection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: endpointPort, using: .tcp)
        var state = RTSPConnectionState()
        state.mode = "active_client"
        state.activeClientHost = trimmedHost
        state.activeClientPort = port
        state.activeClientLifetime = lifetime
        state.activeClientRetryAttempt = retryAttempt
        connections[id] = connection
        states[id] = state
        sessionLifecycle.register(id)
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.active_client_start id=\(id.uuidString) host=\(trimmedHost) port=\(port) " +
                "advertisedHost=\(self.advertisedHost ?? "none") lifetime=\(Int(lifetime)) retryAttempt=\(retryAttempt) " +
                "protocolProfile=\(protocolProfile.rawValue) transportMode=\(transportMode.rawValue)"
        )
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(id: id, connection: connection, state: state)
        }
        connection.start(queue: queue)
        receive(id: id, connection: connection)
    }

    private func stopOnQueue(reason: String) {
        let hadListener = listener != nil || !connections.isEmpty
        sessionLifecycle.reset()
        stopWorkItem?.cancel()
        stopWorkItem = nil
        for workItem in activeClientRetryWorkItems.values {
            workItem.cancel()
        }
        activeClientRetryWorkItems.removeAll()
        for workItem in rtspKeepaliveWorkItems.values {
            workItem.cancel()
        }
        rtspKeepaliveWorkItems.removeAll()
        listener?.cancel()
        listener = nil
        listenerReady = false
        for state in states.values {
            state.mediaSender?.stopAndWait(reason: "rtsp_listener_\(reason)")
            state.timerSyncClient?.stop(reason: "rtsp_listener_\(reason)")
        }
        stopCloudflareMirrorRTPReceiverOnQueue(reason: reason)
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
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else {
                return
            }
            self?.handleListenerState(listener, state: state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    private func handleListenerState(_ source: NWListener, state: NWListener.State) {
        guard listener === source else {
            return
        }
        switch state {
        case .ready:
            listenerReady = true
            DiagnosticsLog.info("xiaomi.mirror.rtsp.listener_ready port=\(port)")
        case .failed(let error):
            listenerReady = false
            DiagnosticsLog.error("xiaomi.mirror.rtsp.listener_failed port=\(port)", error)
            stopOnQueue(reason: "listener_failed")
        case .cancelled:
            listenerReady = false
            DiagnosticsLog.info("xiaomi.mirror.rtsp.listener_cancelled port=\(port)")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        var state = RTSPConnectionState()
        state.mode = "listener"
        states[id] = state
        sessionLifecycle.register(id)
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
        let mode = states[id]?.mode ?? "unknown"
        switch state {
        case .ready:
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.connection_ready id=\(id.uuidString) " +
                    "mode=\(mode) endpoint=\(Self.endpointDescription(connection.endpoint))"
            )
            if mode == "active_client" {
                DiagnosticsLog.info(
                    "xiaomi.mirror.rtsp.active_client_ready id=\(id.uuidString) " +
                        "endpoint=\(Self.endpointDescription(connection.endpoint))"
                )
            }
            sendOptionsIfNeeded(id: id, connection: connection)
        case .failed(let error):
            if mode == "active_client" {
                DiagnosticsLog.error(
                    "xiaomi.mirror.rtsp.active_client_failed id=\(id.uuidString) " +
                        "endpoint=\(Self.endpointDescription(connection.endpoint))",
                    error
                )
            } else {
                DiagnosticsLog.error("xiaomi.mirror.rtsp.connection_failed id=\(id.uuidString)", error)
            }
            cleanupConnection(id: id)
        case .cancelled:
            DiagnosticsLog.info("xiaomi.mirror.rtsp.connection_cancelled id=\(id.uuidString) mode=\(mode)")
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

        if isOfficialMPTRoute {
            logOfficialAuthHeaders(message, id: id)
        }

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
        if isOfficialMPTRoute, request == "OPTIONS" {
            verifyOfficialM2ResponseAuthIfPossible(message, state: state, id: id)
        }

        switch request {
        case "OPTIONS":
            if isOfficialMPTRoute {
                DiagnosticsLog.info("xiaomi.mirror.rtsp.official_sink_wait_peer_m3 id=\(id.uuidString)")
            } else {
                sendGetParameterIfNeeded(id: id, connection: connection)
            }
        case "GET_PARAMETER":
            recordSinkCapabilities(message.body, id: id)
            sendSetParameterIfNeeded(id: id, connection: connection)
        case "SET_PARAMETER":
            DiagnosticsLog.info("xiaomi.mirror.rtsp.m4_ack id=\(id.uuidString) cseq=\(cseq)")
        case "ACTIVE_SETUP":
            recordActiveSetupResponse(message, id: id)
            sendActivePlayIfNeeded(id: id, connection: connection)
        case "ACTIVE_PLAY":
            DiagnosticsLog.info("xiaomi.mirror.rtsp.active_play_ack id=\(id.uuidString) cseq=\(cseq)")
            startOfficialMPTSinkIfNeeded(id: id, connection: connection, reason: "active_play_ack")
        case "SET_PARAMETER_IDR":
            DiagnosticsLog.info("xiaomi.mirror.rtsp.idr_request_ack id=\(id.uuidString) cseq=\(cseq)")
        case "GET_PARAMETER_RECOVERY":
            DiagnosticsLog.info("xiaomi.mirror.rtsp.recovery_keepalive_ack id=\(id.uuidString) cseq=\(cseq)")
        case "GET_PARAMETER_KEEPALIVE":
            state.keepaliveInFlightCSeq = nil
            state.keepaliveMisses = 0
            state.keepaliveAckCount += 1
            states[id] = state
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.session_keepalive_ack id=\(id.uuidString) cseq=\(cseq) " +
                    "acks=\(state.keepaliveAckCount) session=\(state.session ?? "none")"
            )
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
            let extraHeaders = isOfficialMPTRoute
                ? officialOptionsResponseHeaders(for: message, id: id)
                : [
                    "Public: org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER"
                ]
            sendResponse(
                id: id,
                connection: connection,
                cseq: message.cseq,
                extraHeaders: extraHeaders
            )
            if isOfficialMPTRoute {
                DiagnosticsLog.info("xiaomi.mirror.rtsp.official_sink_peer_options id=\(id.uuidString)")
            } else {
                sendGetParameterIfNeeded(id: id, connection: connection)
            }
        case "GET_PARAMETER":
            let currentState = states[id] ?? RTSPConnectionState()
            let profile = protocolProfile
            let isOfficialM16 = profile == .official && currentState.session != nil
            let body = isOfficialM16 ? "" : sourceParameterResponseBody(requestBody: message.body, state: currentState)
            let extraHeaders = isOfficialM16 ? [] : ["Content-Type: text/parameters"]
            let loggedHeaders = ([currentState.session.map { "Session: \(sessionHeaderValue(for: $0))" }].compactMap { $0 } + extraHeaders)
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
                    "protocolProfile=\(profile.rawValue) officialM16=\(isOfficialM16) " +
                    "session=\(currentState.session ?? "none") headers=\(Self.preview(loggedHeaders)) " +
                    "body=\(Self.preview(body, limit: 900))"
            )
            if isOfficialM16 {
                sendIDRRequest(id: id, connection: connection)
            }
        case "SET_PARAMETER":
            let triggerMethod = Self.rtspTriggerMethod(in: message.body)
            if let triggerMethod {
                DiagnosticsLog.info(
                    "xiaomi.mirror.rtsp.peer_trigger id=\(id.uuidString) trigger=\(triggerMethod) " +
                        "body=\(Self.preview(message.body))"
                )
            }
            sendResponse(id: id, connection: connection, cseq: message.cseq)
            if isOfficialMPTRoute {
                switch triggerMethod {
                case "TEARDOWN":
                    let peerStopGeneration = sessionLifecycle.generation
                    DiagnosticsLog.info(
                        "xiaomi.mirror.rtsp.peer_trigger_teardown id=\(id.uuidString) " +
                            "officialAction=stop_sink"
                    )
                    cleanupConnection(id: id, reason: "peer_trigger_teardown")
                    notifyPeerStopIfCurrent(
                        reason: "peer_trigger_teardown",
                        id: id,
                        generation: peerStopGeneration
                    )
                    return
                case "PAUSE":
                    DiagnosticsLog.info(
                        "xiaomi.mirror.rtsp.peer_trigger_pause id=\(id.uuidString) " +
                            "officialAction=stop_sink_keep_rtsp"
                    )
                    stopMediaIfNeeded(id: id, reason: "peer_trigger_pause")
                    return
                default:
                    break
                }
                recordPeerSetParameter(message.body, id: id)
                startOfficialMPTSinkIfNeeded(id: id, connection: connection, reason: "peer_m4")
                sendActiveSetupIfNeeded(id: id, connection: connection)
            }
        case "SETUP":
            handleSetupRequest(message, id: id, connection: connection)
        case "PLAY":
            sendResponse(
                id: id,
                connection: connection,
                cseq: message.cseq,
                session: session(for: id),
                extraHeaders: ["Range: \(playRangeHeaderValue)"]
            )
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.play_received id=\(id.uuidString) " +
                    "protocolProfile=\(protocolProfile.rawValue) session=\(session(for: id)) range=\(playRangeHeaderValue)"
            )
            startMediaIfPossible(id: id, connection: connection)
        case "PAUSE", "TEARDOWN":
            sendResponse(id: id, connection: connection, cseq: message.cseq, session: session(for: id))
            stopMediaIfNeeded(id: id, reason: method.lowercased())
            if method == "TEARDOWN" {
                let peerStopGeneration = sessionLifecycle.generation
                cleanupConnection(id: id)
                notifyPeerStopIfCurrent(
                    reason: "peer_rtsp_teardown",
                    id: id,
                    generation: peerStopGeneration
                )
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
                "protocolProfile=\(protocolProfile.rawValue) transportMode=\(mode.rawValue) " +
                "requestTransport=\(Self.preview(requestTransport ?? "none")) " +
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
        let extraHeaders: [String]
        if isOfficialMPTRoute {
            let authMsg = state.localAuthMsg ?? Self.randomHex(byteCount: 16)
            state.localAuthMsg = authMsg
            extraHeaders = officialOptionsRequestHeaders(authMsg: authMsg)
        } else {
            extraHeaders = [
                "Require: org.wfa.wfd1.0",
                "User-Agent: EdgeLink-XiaomiMirror/1.0",
                "fastRTSPVersion: 0"
            ]
        }
        states[id] = state
        let message = makeRequest(
            method: "OPTIONS",
            target: "*",
            cseq: cseq,
            extraHeaders: extraHeaders
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
            "xiaomi.mirror.rtsp.m4_body id=\(id.uuidString) protocolProfile=\(protocolProfile.rawValue) " +
                "transportMode=\(mode.rawValue) " +
                "clientRTPPorts=\(Self.preview(clientRTPPorts)) mptEnable=\(mptEnable) " +
                "body=\(Self.preview(body, limit: 900))"
        )
        send(message, id: id, connection: connection)
    }

    private func sendIDRRequest(id: UUID, connection: NWConnection) {
        var state = states[id] ?? RTSPConnectionState()
        guard let session = state.session else {
            DiagnosticsLog.warn("xiaomi.mirror.rtsp.idr_request_skipped id=\(id.uuidString) reason=missing_session")
            return
        }
        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.pendingRequests[cseq] = "SET_PARAMETER_IDR"
        states[id] = state
        let body = "wfd_idr_request\r\n"
        let message = makeRequest(
            method: "SET_PARAMETER",
            target: sourcePresentationURL(),
            cseq: cseq,
            body: body,
            extraHeaders: [
                "Session: \(sessionHeaderValue(for: session))",
                "Content-Type: text/parameters"
            ]
        )
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.idr_request_sent id=\(id.uuidString) " +
                "protocolProfile=\(protocolProfile.rawValue) cseq=\(cseq) session=\(session)"
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

    private func recordPeerSetParameter(_ body: String, id: UUID) {
        var state = states[id] ?? RTSPConnectionState()
        state.peerSetParameterFingerprint = DiagnosticsLog.fingerprint(Data(body.utf8))
        state.peerPresentationURL = Self.parameterValue(named: "wfd_presentation_URL", in: body)
        state.peerClientRTPPorts = Self.parameterValue(named: "wfd_client_rtp_ports", in: body)
        state.peerTimerServer = Self.parameterValue(named: "wfd_timer_server_port", in: body)
        states[id] = state
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.peer_m4 id=\(id.uuidString) " +
                "bodyFp=\(state.peerSetParameterFingerprint ?? "none") " +
                "presentationURL=\(Self.preview(state.peerPresentationURL ?? "none")) " +
                "clientRTPPorts=\(Self.preview(state.peerClientRTPPorts ?? "none")) " +
                "body=\(Self.preview(body, limit: 900))"
        )
    }

    private func sourceSetParameterBody(state: RTSPConnectionState) -> String {
        let presentationURL = sourcePresentationURL()
        let profile = protocolProfile
        let videoFormats = profile == .official ? XiaomiMirrorOfficialRTSPDefaults.videoFormats : Self.defaultH264VideoFormats
        let videoEnctype = "1 1"
        let videoGamutType = "1 1"
        let audioCodecs = sourceAudioCodecs
        let mode = transportMode
        let clientRTPPorts = sourceClientRTPPorts(from: state, mode: mode)
        let mptEnable = sourceMPTEnable(from: state, mode: mode)
        var lines = [
            "wfd_presentation_URL: \(presentationURL) none",
            "wfd_video_formats: \(videoFormats)",
            "wfd_video_bitrate: \(XiaomiMirrorVideoDefaults.bitrate)",
            "wfd_video_enctype: \(videoEnctype)",
            "wfd_video_gamuttype: \(videoGamutType)",
            "wfd_audio_codecs: \(audioCodecs)",
            "wfd_client_rtp_ports: \(clientRTPPorts)",
            "wfd_content_protection: none",
            "wfd_content_SP_protection: \(profile == .official ? XiaomiMirrorOfficialRTSPDefaults.contentSPProtection : "0 0 0 0 0 0 0 0")",
            "wfd_mirror_control_enable: enable",
            "wfd_support_secure_win: enable",
            "wfd_standby_resume_capability: supported",
            "wfd_tcp_enable: 0",
            "wfd_tcp_multi_session_enable: 0",
            "wfd_mpt_enable: \(mptEnable)",
            "wfd_connector_type: 07",
            "wfd_platform_type: 2",
            "wfd_trigger_method: SETUP"
        ]
        if profile == .official {
            if let audioIndex = lines.firstIndex(of: "wfd_audio_codecs: \(audioCodecs)") {
                lines.insert("wfd_audio_codecs_v2: \(XiaomiMirrorOfficialRTSPDefaults.selectedAudioCodecsV2)", at: audioIndex + 1)
            }
            lines.append("wfd_type_encryp: \(XiaomiMirrorOfficialRTSPDefaults.typeEncryption)")
            if let timerServerPort = sourceTimerServerPort() {
                lines.append("wfd_timer_server_port:\(timerServerPort)")
            } else {
                DiagnosticsLog.info("xiaomi.mirror.rtsp.official_timer_server_port_skipped reason=missing_ipv4_advertised_host")
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func sourceParameterResponseBody(requestBody: String, state: RTSPConnectionState) -> String {
        let requestedNames = Self.requestedParameterNames(in: requestBody)
        let mode = transportMode
        let profile = protocolProfile
        let videoFormats = profile == .official ? XiaomiMirrorOfficialRTSPDefaults.videoFormats : Self.defaultH264VideoFormats
        let currentVideoInfo = profile == .official ? XiaomiMirrorOfficialRTSPDefaults.currentVideoInfo : Self.sourceCurrentVideoInfo
        let contentSPProtection = profile == .official ? XiaomiMirrorOfficialRTSPDefaults.contentSPProtection : "0 0 0 0 0 0 0 0"
        var parameters: [(String, String)] = [
            ("wfd_audio_codecs", sourceAudioCodecs),
            ("wfd_video_formats", videoFormats),
            ("wfd_video_enctype", "1 1"),
            ("wfd_video_gamuttype", "1 1"),
            ("wfd_current_video_info", currentVideoInfo),
            ("wfd_client_rtp_ports", sourceClientRTPPorts(from: state, mode: mode)),
            ("wfd_content_protection", "none"),
            ("wfd_content_SP_protection", contentSPProtection),
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
        if profile == .official {
            if let audioIndex = parameters.firstIndex(where: { $0.0 == "wfd_audio_codecs" }) {
                parameters.insert(("wfd_audio_codecs_v2", XiaomiMirrorOfficialRTSPDefaults.audioCodecsV2), at: audioIndex + 1)
            }
            if let secureWinIndex = parameters.firstIndex(where: { $0.0 == "wfd_support_secure_win" }) {
                parameters.insert(
                    ("wfd_buffer_capabity", XiaomiMirrorOfficialRTSPDefaults.bufferCapability),
                    at: secureWinIndex + 1
                )
            }
        }
        return parameters.compactMap { name, value -> String? in
            if profile == .official && Self.isOfficialAlwaysReturnedParameter(name) {
                return "\(name): \(value)"
            }
            if requestedNames.isEmpty || requestedNames.contains(name.lowercased()) {
                return "\(name): \(value)"
            }
            return nil
        }.joined(separator: "\r\n") + "\r\n"
    }

    private func sourceClientRTPPorts(from state: RTSPConnectionState, mode: XiaomiMirrorRTSPTransportMode) -> String {
        guard let raw = state.sinkClientRTPPorts?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            if mode == .mpt || protocolProfile == .official {
                return XiaomiMirrorOfficialRTSPDefaults.fallbackClientRTPPorts
            }
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

    private var playRangeHeaderValue: String {
        protocolProfile == .official ? "npt=now-" : "npt=0-"
    }

    private func sessionHeaderValue(for session: String) -> String {
        guard protocolProfile == .official,
              !session.localizedCaseInsensitiveContains("timeout=") else {
            return session
        }
        return "\(session);timeout=60"
    }

    private func sourcePresentationURL() -> String {
        let host = advertisedHost ?? "localhost"
        if host.contains(":") {
            return "rtsp://[\(host)]:\(port)/wfd1.0/streamid=0"
        }
        return "rtsp://\(host):\(port)/wfd1.0/streamid=0"
    }

    private var transportMode: XiaomiMirrorRTSPTransportMode {
        if let rawMode = UserDefaults.standard.string(forKey: transportModeDefaultsKey),
           !rawMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return XiaomiMirrorRTSPTransportMode(rawValue: rawMode) ?? .udp
        }
        return protocolProfile == .official ? .mpt : .udp
    }

    private var protocolProfile: XiaomiMirrorRTSPProtocolProfile {
        XiaomiMirrorRTSPProtocolProfile(rawValue: UserDefaults.standard.string(forKey: protocolProfileDefaultsKey) ?? "") ?? .edge
    }

    private var isOfficialMPTRoute: Bool {
        protocolProfile == .official && transportMode == .mpt
    }

    private func officialOptionsRequestHeaders(authMsg: String) -> [String] {
        [
            "Date: \(Self.rtspDate())",
            "User-Agent: \(Self.officialRTSPUserAgent)",
            "Require: org.wfa.wfd1.0",
            "lib_version: \(Self.officialRTSPLibVersion)",
            "authMsg:\(authMsg)",
            "authKeyType:\(Self.officialRTSPAuthKeyType)",
            "authAlgorithmTypes:\(Self.officialRTSPAuthAlgorithmTypes)",
            "fastRTSPVersion: 0"
        ]
    }

    private func officialOptionsResponseHeaders(for message: RTSPMessage, id: UUID) -> [String] {
        var headers = [
            "Date: \(Self.rtspDate())",
            "User-Agent: \(Self.officialRTSPUserAgent)",
            "Public: org.wfa.wfd1.0, GET_PARAMETER, SET_PARAMETER",
            "fastRTSPVersion: 0"
        ]
        guard let peerAuthMsg = message.headers["authmsg"],
              !peerAuthMsg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DiagnosticsLog.warn("xiaomi.mirror.rtsp.official_auth_ack_unavailable id=\(id.uuidString) reason=missing_peer_auth_msg")
            return headers
        }
        guard let ack = officialAuthMsgAck(for: peerAuthMsg) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.official_auth_ack_unavailable id=\(id.uuidString) " +
                    "reason=missing_auth_key defaultsKey=\(authKeyDefaultsKey) peerAuthMsgFp=\(Self.authFingerprint(peerAuthMsg))"
            )
            return headers
        }
        let authKeyType = officialResponseAuthKeyType(for: message)
        let authAlgorithmVal = officialResponseAuthAlgorithmVal(for: message)
        headers.append("authKeyType:\(authKeyType)")
        headers.append("authAlgorithmVal:\(authAlgorithmVal)")
        headers.append("authMsgAck:\(ack)")
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.official_auth_ack_ready id=\(id.uuidString) " +
                "peerAuthMsgFp=\(Self.authFingerprint(peerAuthMsg)) ackFp=\(Self.authFingerprint(ack)) " +
                "authKeyType=\(authKeyType) authAlgorithmVal=\(authAlgorithmVal)"
        )
        return headers
    }

    private func officialResponseAuthKeyType(for message: RTSPMessage) -> String {
        let peerType = message.headers["authkeytype"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return peerType?.isEmpty == false ? peerType! : Self.officialRTSPAuthKeyType
    }

    private func officialResponseAuthAlgorithmVal(for message: RTSPMessage) -> String {
        guard let rawTypes = message.headers["authalgorithmtypes"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let types = Self.parseRTSPAuthInteger(rawTypes) else {
            return Self.officialRTSPPreferredAuthAlgorithmVal
        }
        if types & 4 != 0 {
            return "4"
        }
        if types & 2 != 0 {
            return "2"
        }
        if types & 1 != 0 {
            return "1"
        }
        return Self.officialRTSPPreferredAuthAlgorithmVal
    }

    private static func parseRTSPAuthInteger(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return Int(trimmed.dropFirst(2), radix: 16)
        }
        return Int(trimmed)
    }

    private func verifyOfficialM2ResponseAuthIfPossible(_ message: RTSPMessage, state: RTSPConnectionState, id: UUID) {
        guard let localAuthMsg = state.localAuthMsg else {
            return
        }
        guard let peerAck = message.headers["authmsgack"],
              !peerAck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.official_m2_auth_missing id=\(id.uuidString) localAuthMsgFp=\(Self.authFingerprint(localAuthMsg))"
            )
            return
        }
        guard let expectedAck = officialAuthMsgAck(for: localAuthMsg) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.official_m2_auth_unverified id=\(id.uuidString) " +
                    "reason=missing_auth_key defaultsKey=\(authKeyDefaultsKey) " +
                    "localAuthMsgFp=\(Self.authFingerprint(localAuthMsg)) peerAckFp=\(Self.authFingerprint(peerAck))"
            )
            return
        }
        let matches = peerAck.caseInsensitiveCompare(expectedAck) == .orderedSame
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.official_m2_auth_check id=\(id.uuidString) match=\(matches) " +
                "localAuthMsgFp=\(Self.authFingerprint(localAuthMsg)) peerAckFp=\(Self.authFingerprint(peerAck))"
        )
    }

    private func officialAuthMsgAck(for authMsg: String) -> String? {
        guard let authKeyData = configuredOfficialAuthKeyData() else {
            return nil
        }
        let key = SymmetricKey(data: authKeyData)
        let code = HMAC<SHA256>.authenticationCode(for: Data(authMsg.utf8), using: key)
        return Data(code).hexString
    }

    private func configuredOfficialAuthKeyData() -> Data? {
        guard let raw = UserDefaults.standard.string(forKey: authKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return isOfficialMPTRoute ? XiaomiMirrorOfficialRTSPDefaults.screenAuthKey : nil
        }
        if let hex = Self.hexData(from: raw) {
            return hex
        }
        return Data(raw.utf8)
    }

    private func logOfficialAuthHeaders(_ message: RTSPMessage, id: UUID) {
        let authMsg = message.headers["authmsg"].map(Self.authFingerprint) ?? "none"
        let authMsgAck = message.headers["authmsgack"].map(Self.authFingerprint) ?? "none"
        let authKeyType = message.headers["authkeytype"] ?? "none"
        let authAlgorithmTypes = message.headers["authalgorithmtypes"] ?? "none"
        let authAlgorithmVal = message.headers["authalgorithmval"] ?? "none"
        let fastRTSPVersion = message.headers["fastrtspversion"] ?? "none"
        let libVersion = message.headers["lib_version"] ?? "none"
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.official_auth_headers id=\(id.uuidString) " +
                "response=\(message.isResponse) method=\(message.method ?? "none") " +
                "cseq=\(message.cseq.map(String.init) ?? "none") " +
                "authMsgFp=\(authMsg) authMsgAckFp=\(authMsgAck) " +
                "authKeyType=\(Self.preview(authKeyType)) authAlgorithmTypes=\(Self.preview(authAlgorithmTypes)) " +
                "authAlgorithmVal=\(Self.preview(authAlgorithmVal)) fastRTSPVersion=\(Self.preview(fastRTSPVersion)) " +
                "libVersion=\(Self.preview(libVersion))"
        )
    }

    private func sourceTimerServerPort() -> String? {
        guard let host = sourceHostForTransport(),
              let ipInteger = Self.ipv4Integer(host) else {
            return nil
        }
        return "\(ipInteger):\(port)"
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

    private func startMediaIfPossible(id: UUID, connection: NWConnection) {
        if isOfficialMPTRoute {
            startOfficialMPTSinkIfNeeded(id: id, connection: connection, reason: "peer_play")
            return
        }
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
        let mode = transportMode
        let clientRTCPPort = transport.clientRTCPPort ?? clientRTPPort &+ 1
        do {
            let sender = try XiaomiMirrorRTPMediaSender(
                transportMode: mode,
                destinationHost: host,
                destinationRTPPort: clientRTPPort,
                destinationRTCPPort: clientRTCPPort,
                localRTPPort: sourceRTPPort,
                localRTCPPort: sourceRTPPort + 1,
                sessionID: id,
                mptSinkOnly: false,
                onDecodedFrame: nil,
                onMPTMediaStalled: nil,
                initialHEVCParameterSets: nil,
                onMPTHEVCParameterSets: nil
            )
            state.mediaSender = sender
            states[id] = state
            sender.start()
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.media_started id=\(id.uuidString) transportMode=\(mode.rawValue) destination=\(host):\(clientRTPPort) " +
                    "remoteRTCPPort=\(clientRTCPPort) localRTPPort=\(sourceRTPPort) localRTCPPort=\(sourceRTPPort + 1) " +
                    "payload=rtp_pt33_mpegts_h264_annexb"
            )
        } catch {
            DiagnosticsLog.error(
                "xiaomi.mirror.rtsp.media_start_failed id=\(id.uuidString) destination=\(host):\(clientRTPPort)",
                error
            )
        }
    }

    private func startOfficialMPTSinkIfNeeded(id: UUID, connection: NWConnection, reason: String) {
        guard var state = states[id] else {
            return
        }
        guard state.mediaSender == nil else {
            scheduleRTSPSessionKeepaliveIfNeeded(id: id, connection: connection, reason: "mpt_sink_already_running_\(reason)")
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.mpt_sink_already_running id=\(id.uuidString) reason=\(reason)"
            )
            return
        }
        guard let host = Self.endpointHost(connection.endpoint) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.mpt_sink_start_skipped id=\(id.uuidString) reason=missing_peer_host"
            )
            return
        }
        let remotePort = state.activePeerMPTServerPort ?? officialMPTClientPort
        do {
            let sender = try XiaomiMirrorRTPMediaSender(
                transportMode: .mpt,
                destinationHost: host,
                destinationRTPPort: remotePort,
                destinationRTCPPort: remotePort,
                localRTPPort: officialMPTClientPort,
                localRTCPPort: officialMPTClientPort,
                sessionID: id,
                mptSinkOnly: true,
                onDecodedFrame: { [weak self] pixelBuffer, width, height in
                    self?.queue.async {
                        self?.noteFirstVideoFrameRendered(id: id)
                    }
                    self?.onDecodedFrame?(pixelBuffer, width, height)
                },
                onMPTMediaStalled: { [weak self] stall in
                    self?.queue.async {
                        self?.handleOfficialMPTSinkStalled(stall)
                    }
                },
                initialHEVCParameterSets: state.mptHEVCParameterSets,
                onMPTHEVCParameterSets: { [weak self] parameterSets in
                    self?.queue.async {
                        guard var state = self?.states[id] else {
                            return
                        }
                        let hadCachedParameterSets = state.mptHEVCParameterSets != nil
                        state.mptHEVCParameterSets = parameterSets
                        self?.states[id] = state
                        DiagnosticsLog.info(
                            "xiaomi.mirror.rtsp.mpt_hevc_parameter_sets_cached id=\(id.uuidString) " +
                                "vps=\(parameterSets.vps.count) sps=\(parameterSets.sps.count) " +
                                "pps=\(parameterSets.pps.count) hadCached=\(hadCachedParameterSets)"
                        )
                    }
                }
            )
            sender.onFirstAudioRendered = { [weak self] in
                self?.queue.async {
                    self?.noteFirstAudioFrameRendered(id: id)
                }
            }
            state.mediaSender = sender
            state.mediaStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            states[id] = state
            sender.start()
            startTimerSyncIfNeeded(id: id)
            scheduleRTSPSessionKeepaliveIfNeeded(id: id, connection: connection, reason: "mpt_sink_started_\(reason)")
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.mpt_sink_started id=\(id.uuidString) reason=\(reason) " +
                    "localPort=\(officialMPTClientPort) peer=\(host):\(remotePort) " +
                    "protocolProfile=\(protocolProfile.rawValue) transportMode=\(transportMode.rawValue) " +
                    "primedHEVC=\(state.mptHEVCParameterSets != nil)"
            )
        } catch {
            DiagnosticsLog.error(
                "xiaomi.mirror.rtsp.mpt_sink_start_failed id=\(id.uuidString) peer=\(host):\(remotePort)",
                error
            )
        }
    }

    private func sendActiveSetupIfNeeded(id: UUID, connection: NWConnection) {
        var state = states[id] ?? RTSPConnectionState()
        guard !state.sentActiveSetup else {
            return
        }
        guard let target = peerPresentationURL(for: connection.endpoint) else {
            DiagnosticsLog.warn("xiaomi.mirror.rtsp.active_setup_skipped id=\(id.uuidString) reason=missing_peer_url")
            return
        }
        let userID = activeMPTUserID(for: &state)
        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.sentActiveSetup = true
        state.pendingRequests[cseq] = "ACTIVE_SETUP"
        states[id] = state
        let message = makeRequest(
            method: "SETUP",
            target: target,
            cseq: cseq,
            extraHeaders: [
                "Transport: RTP/AVP/MPT;unicast;client_port=\(officialMPTClientPort);userid=\(userID)"
            ]
        )
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.active_setup_sent id=\(id.uuidString) cseq=\(cseq) " +
                "target=\(Self.preview(target)) clientPort=\(officialMPTClientPort) userid=\(userID)"
        )
        send(message, id: id, connection: connection)
    }

    private func sendActivePlayIfNeeded(id: UUID, connection: NWConnection) {
        var state = states[id] ?? RTSPConnectionState()
        guard !state.sentActivePlay else {
            return
        }
        guard let session = state.session else {
            DiagnosticsLog.warn("xiaomi.mirror.rtsp.active_play_skipped id=\(id.uuidString) reason=missing_session")
            return
        }
        guard let target = peerPresentationURL(for: connection.endpoint) else {
            DiagnosticsLog.warn("xiaomi.mirror.rtsp.active_play_skipped id=\(id.uuidString) reason=missing_peer_url")
            return
        }
        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.sentActivePlay = true
        state.pendingRequests[cseq] = "ACTIVE_PLAY"
        states[id] = state
        let message = makeRequest(
            method: "PLAY",
            target: target,
            cseq: cseq,
            extraHeaders: ["Session: \(sessionHeaderValue(for: session))"]
        )
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.active_play_sent id=\(id.uuidString) cseq=\(cseq) " +
                "target=\(Self.preview(target)) session=\(session)"
        )
        send(message, id: id, connection: connection)
    }

    private func recordActiveSetupResponse(_ message: RTSPMessage, id: UUID) {
        var state = states[id] ?? RTSPConnectionState()
        let transport = message.headers["transport"]
        state.activeSetupTransportRaw = transport
        state.activePeerMPTServerPort = Self.serverPort(fromTransport: transport)
        states[id] = state
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.active_setup_ack id=\(id.uuidString) " +
                "session=\(state.session ?? "none") transport=\(Self.preview(transport ?? "none")) " +
                "peerServerPort=\(state.activePeerMPTServerPort.map(String.init) ?? "none")"
        )
    }

    private func activeMPTUserID(for state: inout RTSPConnectionState) -> String {
        if let userID = state.activeMPTUserID {
            return userID
        }
        let userID = String(Int.random(in: 10_000...65_535))
        state.activeMPTUserID = userID
        return userID
    }

    private func peerPresentationURL(for endpoint: NWEndpoint) -> String? {
        guard let host = Self.endpointHost(endpoint), !host.isEmpty else {
            return nil
        }
        if host.contains(":") {
            return "rtsp://[\(host)]/wfd1.0/streamid=0"
        }
        return "rtsp://\(host)/wfd1.0/streamid=0"
    }

    private func stopMediaIfNeeded(id: UUID, reason: String) {
        guard var state = states[id], let sender = state.mediaSender else {
            return
        }
        sender.stopAndWait(reason: reason)
        state.mediaSender = nil
        state.timerSyncClient?.stop(reason: reason)
        state.timerSyncClient = nil
        states[id] = state
        cancelRTSPSessionKeepalive(id: id, reason: reason)
    }

    private func noteFirstVideoFrameRendered(id: UUID) {
        guard var state = states[id], state.mediaSender != nil, !state.sentFirstRenderVideo else {
            return
        }
        state.sentFirstRenderVideo = true
        states[id] = state
        sendFirstRender(id: id, isVideo: true)
        if state.pendingFirstRenderAudio, !state.sentFirstRenderAudio {
            state.pendingFirstRenderAudio = false
            noteFirstAudioFrameRendered(id: id)
        }
    }

    private func noteFirstAudioFrameRendered(id: UUID) {
        guard var state = states[id], state.mediaSender != nil, !state.sentFirstRenderAudio else {
            return
        }
        guard state.sentFirstRenderVideo else {
            state.pendingFirstRenderAudio = true
            states[id] = state
            return
        }
        state.sentFirstRenderAudio = true
        states[id] = state
        sendFirstRender(id: id, isVideo: false)
    }

    private func sendFirstRender(id: UUID, isVideo: Bool) {
        guard var state = states[id], let connection = connections[id] else {
            return
        }
        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.pendingRequests[cseq] = "FIRST_RENDER"
        let durationMs: Int
        if let started = state.mediaStartUptimeNanoseconds {
            durationMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        } else {
            durationMs = 0
        }
        states[id] = state
        var headers = [
            "FIRST_RENDER rtsp://localhost/wfd1.0 RTSP/1.0",
            "CSeq: \(cseq)",
            "User-Agent: stagefright/1.1 (Linux;Android 4.1)"
        ]
        if let session = state.session {
            headers.append("Session: \(sessionHeaderValue(for: session))")
        }
        headers.append("Content-Type: text/parameters")
        headers.append("isVideo:\(isVideo ? 1 : 0)")
        headers.append("durationMs:\(durationMs)")
        headers.append("Content-Length: 0")
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n"
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.first_render_sent id=\(id.uuidString) isVideo=\(isVideo) " +
                "durationMs=\(durationMs) cseq=\(cseq) session=\(state.session ?? "none")"
        )
        send(message, id: id, connection: connection)
    }

    private func startTimerSyncIfNeeded(id: UUID) {
        guard var state = states[id], state.timerSyncClient == nil else {
            return
        }
        guard let advertised = state.peerTimerServer,
              let endpoint = XiaomiMirrorTimerSyncClient.parseEndpoint(advertised) else {
            DiagnosticsLog.info(
                "xiaomi.mirror.timesync.start_skipped id=\(id.uuidString) reason=missing_timer_server_advertisement"
            )
            return
        }
        let client = XiaomiMirrorTimerSyncClient(sessionID: id, host: endpoint.host, port: endpoint.port)
        state.timerSyncClient = client
        states[id] = state
        client.start()
    }

    private func handleOfficialMPTSinkStalled(_ stall: XiaomiMirrorMPTStallSnapshot) {
        let id = stall.sessionID
        guard var state = states[id] else {
            return
        }
        let retryEndpoint = state.activeClientHost.map { host in
            state.activeClientPort.map { "\(host):\($0)" } ?? "\(host):none"
        } ?? "none"
        DiagnosticsLog.warn(
            "xiaomi.mirror.rtsp.mpt_sink_stalled id=\(id.uuidString) reason=\(stall.reason) " +
                "mode=\(state.mode) retryAttempt=\(state.activeClientRetryAttempt) " +
                "retryEndpoint=\(retryEndpoint) elapsedMediaSeconds=\(Self.formatSeconds(stall.elapsedMediaSeconds)) " +
                "elapsedFrameSeconds=\(Self.formatOptionalSeconds(stall.elapsedFrameSeconds)) " +
                "datagrams=\(stall.datagramsReceived) pushReceived=\(stall.pushReceived) " +
                "inboundRTP=\(stall.inboundRTP) decodedFrames=\(stall.decodedFrames) " +
                "controlRecoveryAttempt=\(state.mptControlRecoveryAttempt) " +
                "officialAction=keep_rtsp_request_source_recovery"
        )

        if let connection = connections[id] {
            let keepSinkAlive = Self.shouldKeepMPTSinkAliveDuringRecovery(stall.reason)
            state.mptControlRecoveryAttempt += 1
            states[id] = state
            sendRecoveryKeepalive(id: id, connection: connection, stall: stall)
            notifyRecoveryRequired(
                id: id,
                state: state,
                stall: stall,
                trigger: "mpt_stall_fast_source_recovery_keep_rtsp"
            )
            if keepSinkAlive {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.rtsp.mpt_sink_kept_alive_for_source_recovery id=\(id.uuidString) " +
                        "reason=\(stall.reason) controlRecoveryAttempt=\(state.mptControlRecoveryAttempt) " +
                        "rtspKeptAlive=true sourceRecovery=immediate"
                )
                return
            }
            state.mediaSender = nil
            state.timerSyncClient?.stop(reason: "mpt_stall_\(stall.reason)")
            state.timerSyncClient = nil
            states[id] = state
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self, weak connection] in
                guard let self,
                      let connection,
                      self.connections[id] != nil else {
                    return
                }
                self.startOfficialMPTSinkIfNeeded(id: id, connection: connection, reason: "mpt_stall_fast_source_recovery_keep_rtsp")
            }
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.mpt_sink_fast_source_recovery_scheduled id=\(id.uuidString) " +
                    "reason=\(stall.reason) controlRecoveryAttempt=\(state.mptControlRecoveryAttempt) " +
                    "delayMs=250 rtspKeptAlive=true sourceRecovery=immediate"
            )
            return
        }
        notifyRecoveryRequired(
            id: id,
            state: state,
            stall: stall,
            trigger: "mpt_control_recovery_exhausted_no_rtsp_connection"
        )
        DiagnosticsLog.warn(
            "xiaomi.mirror.rtsp.mpt_sink_stall_recovery_waiting id=\(id.uuidString) " +
                "reason=no_rtsp_connection rtspKeptAlive=false"
        )
    }

    private func sendRecoveryKeepalive(
        id: UUID,
        connection: NWConnection,
        stall: XiaomiMirrorMPTStallSnapshot
    ) {
        var state = states[id] ?? RTSPConnectionState()
        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.pendingRequests[cseq] = "GET_PARAMETER_RECOVERY"
        let session = state.session
        states[id] = state
        let body = "wfd_video_formats\r\nwfd_current_video_info\r\n"
        let message = makeRequest(
            method: "GET_PARAMETER",
            target: "rtsp://localhost/wfd1.0",
            cseq: cseq,
            body: body,
            extraHeaders: [
                session.map { "Session: \(sessionHeaderValue(for: $0))" },
                "Content-Type: text/parameters"
            ].compactMap { $0 }
        )
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.recovery_keepalive_sent id=\(id.uuidString) cseq=\(cseq) " +
                "reason=\(stall.reason) session=\(session ?? "none")"
        )
        send(message, id: id, connection: connection)
        sendIDRRequest(id: id, connection: connection)
    }

    private func scheduleRTSPSessionKeepaliveIfNeeded(id: UUID, connection: NWConnection, reason: String) {
        guard isOfficialMPTRoute,
              connections[id] != nil,
              states[id] != nil else {
            return
        }
        guard rtspKeepaliveWorkItems[id] == nil else {
            return
        }
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.session_keepalive_scheduled id=\(id.uuidString) " +
                "reason=\(reason) intervalMs=\(Int(rtspSessionKeepaliveInterval * 1000))"
        )
        scheduleRTSPSessionKeepalive(id: id, connection: connection, reason: reason)
    }

    private func scheduleRTSPSessionKeepalive(
        id: UUID,
        connection: NWConnection,
        reason: String,
        delay: TimeInterval? = nil
    ) {
        let workItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self,
                  let connection else {
                return
            }
            self.rtspKeepaliveWorkItems.removeValue(forKey: id)
            guard self.connections[id] != nil,
                  self.states[id] != nil else {
                return
            }
            _ = self.sendRTSPSessionKeepalive(id: id, connection: connection, reason: reason)
            self.scheduleRTSPSessionKeepalive(id: id, connection: connection, reason: "interval")
        }
        rtspKeepaliveWorkItems[id] = workItem
        queue.asyncAfter(deadline: .now() + (delay ?? rtspSessionKeepaliveInterval), execute: workItem)
    }

    @discardableResult
    private func sendRTSPSessionKeepalive(id: UUID, connection: NWConnection, reason: String) -> Bool {
        guard var state = states[id] else {
            return false
        }
        guard let session = state.session else {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.session_keepalive_waiting id=\(id.uuidString) " +
                    "reason=missing_session trigger=\(reason)"
            )
            return true
        }
        if let inFlightCSeq = state.keepaliveInFlightCSeq {
            state.keepaliveMisses += 1
            states[id] = state
            DiagnosticsLog.warn(
                "xiaomi.mirror.rtsp.session_keepalive_missed id=\(id.uuidString) " +
                    "cseq=\(inFlightCSeq) misses=\(state.keepaliveMisses) maxMisses=\(rtspSessionKeepaliveMaxMisses) " +
                    "session=\(session)"
            )
            if state.keepaliveMisses >= rtspSessionKeepaliveMaxMisses {
                let stall = XiaomiMirrorMPTStallSnapshot(
                    sessionID: id,
                    reason: "rtsp_keepalive_missed",
                    elapsedMediaSeconds: 0,
                    elapsedFrameSeconds: nil,
                    datagramsReceived: 0,
                    pushReceived: 0,
                    inboundRTP: 0,
                    decodedFrames: 0
                )
                notifyRecoveryRequired(
                    id: id,
                    state: state,
                    stall: stall,
                    trigger: "rtsp_session_keepalive_missed"
                )
            }
            return true
        }

        let cseq = state.nextCSeq
        state.nextCSeq += 1
        state.keepaliveInFlightCSeq = cseq
        state.keepaliveSentCount += 1
        state.pendingRequests[cseq] = "GET_PARAMETER_KEEPALIVE"
        states[id] = state
        let message = makeRequest(
            method: "GET_PARAMETER",
            target: "rtsp://localhost/wfd1.0",
            cseq: cseq,
            extraHeaders: ["Session: \(sessionHeaderValue(for: session))"]
        )
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.session_keepalive_sent id=\(id.uuidString) cseq=\(cseq) " +
                "sent=\(state.keepaliveSentCount) reason=\(reason) session=\(session)"
        )
        send(message, id: id, connection: connection)
        return true
    }

    private func cancelRTSPSessionKeepalive(id: UUID, reason: String) {
        rtspKeepaliveWorkItems.removeValue(forKey: id)?.cancel()
        guard var state = states[id] else {
            return
        }
        let hadKeepalive = state.keepaliveInFlightCSeq != nil || state.keepaliveSentCount > 0
        state.keepaliveInFlightCSeq = nil
        state.keepaliveMisses = 0
        states[id] = state
        if hadKeepalive {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.session_keepalive_cancelled id=\(id.uuidString) reason=\(reason) " +
                    "sent=\(state.keepaliveSentCount) ack=\(state.keepaliveAckCount)"
            )
        }
        state.keepaliveSentCount = 0
        state.keepaliveAckCount = 0
        states[id] = state
    }

    private static func shouldKeepMPTSinkAliveDuringRecovery(_ reason: String) -> Bool {
        reason == "decoded_frame_stalled_beyond_threshold" ||
            reason.hasPrefix("decoded_frame_stalled") ||
            reason == "no_packets_beyond_6s"
    }

    private func notifyRecoveryRequired(
        id: UUID,
        state: RTSPConnectionState,
        stall: XiaomiMirrorMPTStallSnapshot,
        trigger: String
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedSinceLast = state.lastSessionRecoveryNotificationUptimeNanoseconds > 0
            ? Double(now - state.lastSessionRecoveryNotificationUptimeNanoseconds) / 1_000_000_000
            : nil
        if let elapsedSinceLast,
           elapsedSinceLast < sessionRecoveryNotificationMinInterval {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.session_recovery_duplicate id=\(id.uuidString) " +
                    "trigger=\(trigger) reason=\(stall.reason) " +
                    "elapsedSinceLast=\(Self.formatSeconds(elapsedSinceLast))"
            )
            return
        }
        var nextState = state
        nextState.lastSessionRecoveryNotificationUptimeNanoseconds = now
        if states[id] != nil {
            states[id] = nextState
        }
        let event = XiaomiMirrorRTSPRecoveryEvent(
            sessionID: id,
            trigger: trigger,
            reason: stall.reason,
            retryAttempt: state.activeClientRetryAttempt,
            host: state.activeClientHost,
            port: state.activeClientPort,
            elapsedMediaSeconds: stall.elapsedMediaSeconds,
            elapsedFrameSeconds: stall.elapsedFrameSeconds,
            datagramsReceived: stall.datagramsReceived,
            pushReceived: stall.pushReceived,
            inboundRTP: stall.inboundRTP,
            decodedFrames: stall.decodedFrames
        )
        DiagnosticsLog.warn(
            "xiaomi.mirror.rtsp.session_recovery_required id=\(id.uuidString) " +
                "trigger=\(trigger) reason=\(stall.reason) retryAttempt=\(state.activeClientRetryAttempt) " +
                "host=\(state.activeClientHost ?? "none") port=\(state.activeClientPort.map(String.init) ?? "none") " +
                "elapsedMediaSeconds=\(Self.formatSeconds(stall.elapsedMediaSeconds)) " +
                "elapsedFrameSeconds=\(Self.formatOptionalSeconds(stall.elapsedFrameSeconds))"
        )
        onRecoveryRequired?(event)
    }

    private func scheduleOfficialActiveClientRetry(
        previousID: UUID,
        host: String,
        port: UInt16,
        lifetime: TimeInterval,
        nextAttempt: Int
    ) {
        activeClientRetryWorkItems[previousID]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.activeClientRetryWorkItems.removeValue(forKey: previousID)
            do {
                try self.connectOnQueue(
                    host: host,
                    port: port,
                    advertisedHost: self.advertisedHost,
                    lifetime: lifetime,
                    retryAttempt: nextAttempt
                )
                DiagnosticsLog.info(
                    "xiaomi.mirror.rtsp.active_client_retry_started previousId=\(previousID.uuidString) " +
                        "host=\(host) port=\(port) attempt=\(nextAttempt)"
                )
            } catch {
                DiagnosticsLog.error(
                    "xiaomi.mirror.rtsp.active_client_retry_failed previousId=\(previousID.uuidString) " +
                        "host=\(host) port=\(port) attempt=\(nextAttempt)",
                    error
                )
            }
        }
        activeClientRetryWorkItems[previousID] = workItem
        queue.asyncAfter(deadline: .now() + officialMPTRTSPRetryDelay, execute: workItem)
        DiagnosticsLog.info(
            "xiaomi.mirror.rtsp.active_client_retry_scheduled previousId=\(previousID.uuidString) " +
                "host=\(host) port=\(port) attempt=\(nextAttempt) delayMs=\(Int(officialMPTRTSPRetryDelay * 1000))"
        )
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
            headers.append("Session: \(sessionHeaderValue(for: session))")
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

    private func cleanupConnection(id: UUID, reason: String = "connection_cleanup") {
        cancelRTSPSessionKeepalive(id: id, reason: reason)
        stopMediaIfNeeded(id: id, reason: reason)
        states[id]?.timerSyncClient?.stop(reason: reason)
        states[id]?.timerSyncClient = nil
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        states.removeValue(forKey: id)
        sessionLifecycle.remove(id)
    }

    private func notifyPeerStopIfCurrent(reason: String, id: UUID, generation: UInt64) {
        guard sessionLifecycle.shouldHonorStop(from: generation) else {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.peer_stop_ignored id=\(id.uuidString) reason=\(reason) " +
                    "eventGeneration=\(generation) currentGeneration=\(sessionLifecycle.generation) " +
                    "activeSessions=\(sessionLifecycle.activeSessionCount)"
            )
            return
        }
        onPeerStop?(reason, id, generation)
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
        let activeCloud = cloudflareMirrorReceiver != nil
        guard connections.isEmpty && activeMedia == 0 && !activeCloud else {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtsp.listener_stop_deferred reason=\(reason) " +
                    "connections=\(connections.count) activeMedia=\(activeMedia) activeCloud=\(activeCloud)"
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

    private static let officialRTSPUserAgent = "stagefright/1.1 (Linux;Android 4.1)"
    private static let officialRTSPLibVersion = "miplaycast_os3_release1.7 3.2.6011403"
    private static let officialRTSPAuthKeyType = "3"
    private static let officialRTSPAuthAlgorithmTypes = "7"
    private static let officialRTSPPreferredAuthAlgorithmVal = "4"

    private static func rtspDate(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: TimeZone.current.secondsFromGMT(for: date))
        formatter.dateFormat = "EEE, d MMM yyyy H:mm:ss Z"
        return formatter.string(from: date)
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatOptionalSeconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "none"
    }

    private static func randomHex(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...UInt8.max, using: &generator)) }
            .joined()
    }

    private static func hexData(from raw: String) -> Data? {
        let normalized = raw
            .replacingOccurrences(of: "hex:", with: "", options: [.anchored, .caseInsensitive])
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard normalized.count >= 2, normalized.count.isMultiple(of: 2),
              normalized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        var data = Data()
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func authFingerprint(_ value: String) -> String {
        DiagnosticsLog.fingerprint(Data(value.utf8))
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

    private static func rtspTriggerMethod(in body: String) -> String? {
        guard let value = parameterValue(named: "wfd_trigger_method", in: body) else {
            return nil
        }
        return value.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map { String($0).uppercased() }
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

    private static func isOfficialAlwaysReturnedParameter(_ name: String) -> Bool {
        switch name.lowercased() {
        case "wfd_audio_codecs",
             "wfd_audio_codecs_v2",
             "wfd_video_formats",
             "wfd_current_video_info",
             "wfd_client_rtp_ports",
             "wfd_content_sp_protection",
             "wfd_mirror_control_enable",
             "wfd_support_secure_win",
             "wfd_buffer_capabity":
            return true
        default:
            return false
        }
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

    private static func ipv4Integer(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else {
            return nil
        }
        var result: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else {
                return nil
            }
            result = (result << 8) | UInt32(octet)
        }
        return result
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

    private static func serverPort(fromTransport raw: String?) -> UInt16? {
        guard let raw else {
            return nil
        }
        let components = raw.split(separator: ";", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let serverPortRaw = components.first(where: { $0.lowercased().hasPrefix("server_port=") })?
            .dropFirst("server_port=".count)
            .description else {
            return nil
        }
        return parsePortPair(serverPortRaw).0 ?? UInt16(serverPortRaw)
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

    private static let defaultH264VideoFormats = XiaomiMirrorVideoDefaults.h264VideoFormats
    private static let sourceCurrentVideoInfo = XiaomiMirrorVideoDefaults.currentVideoInfo
}

private struct RTSPConnectionState {
    var buffer = Data()
    var mode = "listener"
    var nextCSeq = 1
    var pendingRequests: [Int: String] = [:]
    var sentOptions = false
    var sentGetParameter = false
    var sentSetParameter = false
    var loggedFirstInbound = false
    var localAuthMsg: String?
    var session: String?
    var sinkCapabilitiesFingerprint: String?
    var sinkVideoFormats: String?
    var sinkVideoEnctype: String?
    var sinkVideoGamutType: String?
    var sinkAudioCodecs: String?
    var sinkClientRTPPorts: String?
    var peerSetParameterFingerprint: String?
    var peerPresentationURL: String?
    var peerClientRTPPorts: String?
    var peerTimerServer: String?
    var setupTransport: RTSPTransportSelection?
    var sentActiveSetup = false
    var sentActivePlay = false
    var activeMPTUserID: String?
    var activeSetupTransportRaw: String?
    var activePeerMPTServerPort: UInt16?
    var activeClientHost: String?
    var activeClientPort: UInt16?
    var activeClientLifetime: TimeInterval = 0
    var activeClientRetryAttempt = 0
    var mptControlRecoveryAttempt = 0
    var lastSessionRecoveryNotificationUptimeNanoseconds: UInt64 = 0
    var mptHEVCParameterSets: XiaomiMirrorHEVCParameterSets?
    var keepaliveInFlightCSeq: Int?
    var keepaliveMisses = 0
    var keepaliveSentCount: UInt64 = 0
    var keepaliveAckCount: UInt64 = 0
    var mediaSender: XiaomiMirrorRTPMediaSender?
    var timerSyncClient: XiaomiMirrorTimerSyncClient?
    var sentFirstRenderVideo = false
    var sentFirstRenderAudio = false
    var pendingFirstRenderAudio = false
    var mediaStartUptimeNanoseconds: UInt64?
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

private final class XiaomiMirrorTimerSyncClient {
    static let wireBytes = 40

    private let queue = DispatchQueue(label: "EdgeLink.XiaomiMirrorTimerSync")
    private let sessionID: UUID
    private let host: String
    private let port: UInt16
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var sendTimer: DispatchSourceTimer?
    private var destinationAddress: sockaddr_in?
    private var tick: UInt32 = 0
    private var requestsSent: UInt64 = 0
    private var repliesReceived: UInt64 = 0
    private var lastRequestT1Us: Int64 = 0
    private var lastOffsetUs: Int64 = 0
    private var started = false

    init(sessionID: UUID, host: String, port: UInt16) {
        self.sessionID = sessionID
        self.host = host
        self.port = port
    }

    static func parseEndpoint(_ advertised: String) -> (host: String, port: UInt16)? {
        let parts = advertised.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let ipValue = UInt32(parts[0]),
              let portValue = UInt16(parts[1]), portValue > 0 else {
            return nil
        }
        let host = "\((ipValue >> 24) & 0xff).\((ipValue >> 16) & 0xff).\((ipValue >> 8) & 0xff).\(ipValue & 0xff)"
        return (host, portValue)
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop(reason: String) {
        queue.async { [weak self] in
            self?.stopOnQueue(reason: reason)
        }
    }

    private func startOnQueue() {
        guard !started else {
            return
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.timesync.start_failed session=\(sessionID.uuidString) reason=invalid_host host=\(host)"
            )
            return
        }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.timesync.start_failed session=\(sessionID.uuidString) reason=socket errno=\(errno)"
            )
            return
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        socketFD = fd
        destinationAddress = address
        started = true
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.drainReplies()
        }
        readSource.setCancelHandler { [weak self] in
            guard let self, self.socketFD >= 0 else {
                return
            }
            close(self.socketFD)
            self.socketFD = -1
        }
        self.readSource = readSource
        readSource.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.sendRequest()
        }
        sendTimer = timer
        timer.resume()
        DiagnosticsLog.info(
            "xiaomi.mirror.timesync.started session=\(sessionID.uuidString) server=\(host):\(port) intervalMs=250"
        )
    }

    private func stopOnQueue(reason: String) {
        guard started else {
            return
        }
        started = false
        sendTimer?.cancel()
        sendTimer = nil
        readSource?.cancel()
        readSource = nil
        DiagnosticsLog.info(
            "xiaomi.mirror.timesync.stopped session=\(sessionID.uuidString) reason=\(reason) " +
                "requests=\(requestsSent) replies=\(repliesReceived) lastOffsetUs=\(lastOffsetUs)"
        )
    }

    private func nowUs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1000)
    }

    private func sendRequest() {
        guard started, socketFD >= 0, var address = destinationAddress else {
            return
        }
        tick &+= 1
        let t1 = nowUs()
        var packet = Data(count: Self.wireBytes)
        packet.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            withUnsafeBytes(of: t1) { t1Bytes in
                base.copyMemory(from: t1Bytes.baseAddress!, byteCount: 8)
            }
            withUnsafeBytes(of: tick) { tickBytes in
                base.advanced(by: 32).copyMemory(from: tickBytes.baseAddress!, byteCount: 4)
            }
        }
        let sent = packet.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &address) { addressPtr in
                addressPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(socketFD, buffer.baseAddress, Self.wireBytes, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent == Self.wireBytes {
            requestsSent += 1
            lastRequestT1Us = t1
        } else if requestsSent == 0 || requestsSent % 40 == 0 {
            DiagnosticsLog.warn(
                "xiaomi.mirror.timesync.send_failed session=\(sessionID.uuidString) errno=\(errno) requests=\(requestsSent)"
            )
        }
    }

    private func drainReplies() {
        guard started, socketFD >= 0 else {
            return
        }
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let received = recv(socketFD, &buffer, buffer.count, 0)
            if received <= 0 {
                break
            }
            guard received >= Self.wireBytes else {
                continue
            }
            repliesReceived += 1
            let t4 = nowUs()
            let t1 = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int64.self) }
            let t3 = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: Int64.self) }
            let t2 = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: Int64.self) }
            let replyTick = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) }
            let offset = ((t2 - t1) + (t3 - t4)) / 2
            lastOffsetUs = offset
            if repliesReceived == 1 || repliesReceived % 120 == 0 {
                DiagnosticsLog.info(
                    "xiaomi.mirror.timesync.sample session=\(sessionID.uuidString) replies=\(repliesReceived) " +
                        "tick=\(replyTick) offsetUs=\(offset) rttUs=\((t4 - t1) - (t3 - t2)) t1MatchesLast=\(t1 == lastRequestT1Us)"
                )
            }
        }
    }
}

private final class XiaomiMirrorRTPMediaSender {
    private let queue = DispatchQueue(label: "EdgeLink.XiaomiMirrorRTPMediaSender")
    private let mptDecodeQueue = DispatchQueue(label: "EdgeLink.XiaomiMirrorMPTDecode")
    private let transportMode: XiaomiMirrorRTSPTransportMode
    private let destinationHost: String
    private let destinationRTPPort: UInt16
    private let destinationRTCPPort: UInt16
    private let localRTPPort: UInt16
    private let localRTCPPort: UInt16
    private let sessionID: UUID
    private let mptSinkOnly: Bool
    private let onDecodedFrame: ((CVPixelBuffer, Int, Int) -> Void)?
    private let onMPTMediaStalled: ((XiaomiMirrorMPTStallSnapshot) -> Void)?
    var onFirstAudioRendered: (() -> Void)?
    private let initialHEVCParameterSets: XiaomiMirrorHEVCParameterSets?
    private let onMPTHEVCParameterSets: ((XiaomiMirrorHEVCParameterSets) -> Void)?
    private let frameRate: Int32 = XiaomiMirrorVideoDefaults.frameRate
    private let rtpPacketsPerPayload = 7
    private var connection: NWConnection?
    private var rtcpConnection: NWConnection?
    private var mptSocketFD: Int32 = -1
    private var mptReadSource: DispatchSourceRead?
    private var mptDestinationAddress: sockaddr_in?
    private var frameTimer: DispatchSourceTimer?
    private var rtcpTimer: DispatchSourceTimer?
    private var mptSinkPacketWatchdogTimer: DispatchSourceTimer?
    private var encoder: XiaomiMirrorH264Encoder
    private var muxer = XiaomiMirrorMPEGTSMuxer()
    private var sequenceNumber = UInt16.random(in: 0...UInt16.max)
    private var ssrc = UInt32.random(in: 1...UInt32.max)
    private var frameIndex: UInt64 = 0
    private var framesSent: UInt64 = 0
    private var rtpPacketsSent: UInt64 = 0
    private var rtpPayloadOctetsSent: UInt64 = 0
    private var rtcpSRSent: UInt64 = 0
    private var lastRTPTimestamp: UInt32 = 0
    private var kcpSendSN: UInt32 = 0
    private var kcpRemoteNextReceiveSN: UInt32 = 0
    private var kcpPacketsSent: UInt64 = 0
    private var kcpBytesSent: UInt64 = 0
    private var kcpACKsReceived: UInt64 = 0
    private var kcpACKSent: UInt64 = 0
    private var kcpWASKReceived: UInt64 = 0
    private var kcpWINSSent: UInt64 = 0
    private var kcpWINSReceived: UInt64 = 0
    private var kcpPUSHReceived: UInt64 = 0
    private var kcpDatagramsReceived: UInt64 = 0
    private var kcpDatagramReceiveErrors: UInt64 = 0
    private var kcpLatestACKSN: UInt32?
    private var kcpLatestRemoteUNA: UInt32?
    private var kcpConversationID: UInt32?
    private var kcpConversationIgnoredCount: UInt64 = 0
    private var kcpReceiveBuffer: [UInt32: KCPIncomingSegment] = [:]
    private var kcpOutOfOrderBufferedCount: UInt64 = 0
    private var kcpDuplicateDroppedCount: UInt64 = 0
    private var kcpReceiveResyncCount: UInt64 = 0
    private var kcpOutOfOrderStartedUptimeNanoseconds: UInt64 = 0
    private var kcpOutOfOrderExpectedSN: UInt32?
    private var mptSinkInterleavedBuffer = Data()
    private var mptSinkInterleavedFramesReceived: UInt64 = 0
    private var mptSinkInterleavedMalformedCount: UInt64 = 0
    private var mptSinkRTPPacketsReceived: UInt64 = 0
    private var mptSinkRTPMalformedCount: UInt64 = 0
    private var mptSinkRTPDuplicateDroppedCount: UInt64 = 0
    private var mptSinkRTPSequenceGapCount: UInt64 = 0
    private var mptSinkLastRTPSequenceNumber: UInt16?
    private var mptSinkTSPacketsReceived: UInt64 = 0
    private var mptSinkTSCaptureHandle: FileHandle?
    private var mptSinkTSCaptureBytes = 0
    private var mptSinkTSCaptureStartLogged = false
    private var mptSinkTSDemuxer: XiaomiMirrorMPEGTSHEVCDemuxer?
    private var mptSinkHEVCDecoder: XiaomiMirrorHEVCDecoder?
    private var mptSinkAudioPlayer: XiaomiMirrorMPTPrivateAudioPlayer?
    private var mptSinkDecodedFrames: UInt64 = 0
    private var mptSinkDecodeFailedFrames: UInt64 = 0
    private var lastMPTMediaPacketUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var lastMPTAnyPushUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var lastMPTDecodedFrameUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var lastMPTFrameStallDecoderResetUptimeNanoseconds: UInt64 = 0
    private var mptSinkFrameStallDecoderResetCount: UInt64 = 0
    private var externalRTPReceiverStarted = false
    private var stopped = false
    var onExternalDatagramSend: ((Data) -> Void)?

    init(
        transportMode: XiaomiMirrorRTSPTransportMode,
        destinationHost: String,
        destinationRTPPort: UInt16,
        destinationRTCPPort: UInt16,
        localRTPPort: UInt16,
        localRTCPPort: UInt16,
        sessionID: UUID,
        mptSinkOnly: Bool,
        onDecodedFrame: ((CVPixelBuffer, Int, Int) -> Void)?,
        onMPTMediaStalled: ((XiaomiMirrorMPTStallSnapshot) -> Void)?,
        initialHEVCParameterSets: XiaomiMirrorHEVCParameterSets?,
        onMPTHEVCParameterSets: ((XiaomiMirrorHEVCParameterSets) -> Void)?
    ) throws {
        self.transportMode = transportMode
        self.destinationHost = destinationHost
        self.destinationRTPPort = destinationRTPPort
        self.destinationRTCPPort = destinationRTCPPort
        self.localRTPPort = localRTPPort
        self.localRTCPPort = localRTCPPort
        self.sessionID = sessionID
        self.mptSinkOnly = mptSinkOnly
        self.onDecodedFrame = onDecodedFrame
        self.onMPTMediaStalled = onMPTMediaStalled
        self.initialHEVCParameterSets = initialHEVCParameterSets
        self.onMPTHEVCParameterSets = onMPTHEVCParameterSets
        self.kcpConversationID = mptSinkOnly ? nil : Self.defaultKCPConversationID
        self.encoder = try XiaomiMirrorH264Encoder(
            width: XiaomiMirrorVideoDefaults.width,
            height: XiaomiMirrorVideoDefaults.height,
            frameRate: frameRate
        )
        if mptSinkOnly {
            let decoder = XiaomiMirrorHEVCDecoder(sessionID: sessionID)
            if let initialHEVCParameterSets {
                decoder.primeParameterSets(initialHEVCParameterSets, reason: "mpt_sink_restart")
            }
            decoder.onParameterSetsChanged = { [weak self] parameterSets in
                self?.onMPTHEVCParameterSets?(parameterSets)
            }
            decoder.onFrame = { [weak self] pixelBuffer, width, height in
                self?.mptDecodeQueue.async {
                    self?.handleDecodedMPTSinkFrame(pixelBuffer, width: width, height: height)
                }
            }
            decoder.onDecodeFailed = { [weak self] in
                self?.mptDecodeQueue.async {
                    self?.mptSinkDecodeFailedFrames += 1
                }
            }
            let audioPlayer = XiaomiMirrorMPTPrivateAudioPlayer(sessionID: sessionID)
            audioPlayer.onFirstAudioRendered = { [weak self] in
                self?.onFirstAudioRendered?()
            }
            self.mptSinkHEVCDecoder = decoder
            self.mptSinkAudioPlayer = audioPlayer
            self.mptSinkTSDemuxer = XiaomiMirrorMPEGTSHEVCDemuxer(
                sessionID: sessionID,
                onAccessUnit: { [weak self, weak decoder] accessUnit, pts90k in
                    self?.mptDecodeQueue.async {
                        decoder?.decode(accessUnit: accessUnit, pts90k: pts90k)
                    }
                },
                onPrivateAudioPES: { [weak self, weak audioPlayer] payload, pts90k in
                    self?.mptDecodeQueue.async {
                        audioPlayer?.pushPESPayload(payload, pts90k: pts90k)
                    }
                }
            )
        }
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

    func stopAndWait(reason: String) {
        queue.sync {
            self.stopOnQueue(reason: reason)
        }
        // Dispatch source cancellation closes the MPT socket on this same queue.
        // A second barrier makes the port reusable before a replacement session starts.
        queue.sync {}
    }

    func startExternalRTPReceiver(reason: String) {
        queue.async {
            self.startExternalRTPReceiverOnQueue(reason: reason)
        }
    }

    func pushExternalRTPPacket(_ packet: Data, sequence: Int?) {
        queue.async {
            guard self.mptSinkOnly, self.externalRTPReceiverStarted, !self.stopped else {
                return
            }
            self.kcpDatagramsReceived += 1
            self.recordMPTMediaPacketActivity(reason: "cloudflare_datagram")
            self.handleKCPDatagram(packet)
        }
    }

    private func startExternalRTPReceiverOnQueue(reason: String) {
        guard mptSinkOnly, !stopped else {
            return
        }
        guard !externalRTPReceiverStarted else {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.external_receiver_reuse session=\(sessionID.uuidString) reason=\(reason)"
            )
            return
        }
        externalRTPReceiverStarted = true
        startMPTSinkPacketWatchdog()
        DiagnosticsLog.info(
            "xiaomi.mirror.mpt.external_receiver_start session=\(sessionID.uuidString) " +
                "reason=\(reason) payload=RTP/PT33/MP2T/HEVC"
        )
    }

    private func startOnQueue() {
        guard connection == nil, !stopped else {
            return
        }
        if transportMode == .mpt {
            startMPTSocketOnQueue()
            return
        }
        guard let remotePort = NWEndpoint.Port(rawValue: destinationRTPPort),
              let localPort = NWEndpoint.Port(rawValue: localRTPPort) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.media.start_skipped session=\(sessionID.uuidString) reason=invalid_port " +
                    "destinationPort=\(destinationRTPPort) destinationRTCPPort=\(destinationRTCPPort) " +
                    "localPort=\(localRTPPort) localRTCPPort=\(self.localRTCPPort)"
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
        if transportMode == .udp {
            guard let remoteRTCPPort = NWEndpoint.Port(rawValue: destinationRTCPPort),
                  let localRTCPPort = NWEndpoint.Port(rawValue: localRTCPPort) else {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.rtp.start_skipped session=\(sessionID.uuidString) reason=invalid_rtcp_port " +
                        "destinationRTCPPort=\(destinationRTCPPort) localRTCPPort=\(self.localRTCPPort)"
                )
                return
            }
            let rtcpParameters = NWParameters.udp
            rtcpParameters.allowLocalEndpointReuse = true
            rtcpParameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: localRTCPPort)
            let rtcpConnection = NWConnection(host: NWEndpoint.Host(destinationHost), port: remoteRTCPPort, using: rtcpParameters)
            self.rtcpConnection = rtcpConnection
            rtcpConnection.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    self?.handleRTCPConnectionState(state)
                }
            }
            rtcpConnection.start(queue: queue)
            receiveRTCP()
            startRTCPTimer()
        }
        connection.start(queue: queue)
        startFrameTimer()
        DiagnosticsLog.info(
            "xiaomi.mirror.rtp.start session=\(sessionID.uuidString) destination=\(destinationHost):\(destinationRTPPort) " +
                "remoteRTCPPort=\(destinationRTCPPort) localRTPPort=\(localRTPPort) localRTCPPort=\(self.localRTCPPort) " +
                "payload=RTP/PT33/MP2T/H264AnnexB video=\(XiaomiMirrorVideoDefaults.width)x\(XiaomiMirrorVideoDefaults.height)@\(frameRate)"
        )
    }

    private func startMPTSocketOnQueue() {
        guard mptSocketFD < 0, !stopped else {
            return
        }
        guard let destinationAddress = Self.makeIPv4SocketAddress(host: destinationHost, port: destinationRTPPort) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.start_skipped session=\(sessionID.uuidString) reason=invalid_destination " +
                    "destination=\(destinationHost):\(destinationRTPPort)"
            )
            return
        }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.start_skipped session=\(sessionID.uuidString) reason=socket_failed errno=\(errno)"
            )
            return
        }

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) { pointer in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
        applyOfficialMPTSocketBufferOptions(fd: fd)
        _ = Darwin.fcntl(fd, F_SETFL, Darwin.fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        var localAddress = Self.anyIPv4SocketAddress(port: localRTPPort)
        let bindResult = withUnsafePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let bindErrno = errno
            Darwin.close(fd)
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.start_skipped session=\(sessionID.uuidString) reason=bind_failed " +
                    "localPort=\(localRTPPort) errno=\(bindErrno)"
            )
            return
        }

        mptSocketFD = fd
        mptDestinationAddress = destinationAddress
        if !mptSinkOnly {
            encoder.onFrame = { [weak self] frame in
                self?.queue.async {
                    self?.send(frame)
                }
            }
            startFrameTimer()
        } else {
            startMPTSinkPacketWatchdog()
        }
        startMPTReceiveSource(fd: fd)
        let convDescription = kcpConversationID.map { Self.hex32($0) } ?? "pending_peer_first_segment"
        DiagnosticsLog.info(
            "xiaomi.mirror.mpt.start session=\(sessionID.uuidString) destination=\(destinationHost):\(destinationRTPPort) " +
                "localPort=\(localRTPPort) socket=raw_udp_recvfrom conv=\(convDescription) " +
                "role=\(mptSinkOnly ? "sink_receiver" : "sender") " +
                "payload=\(mptSinkOnly ? "KCP_PUSH_RECEIVE_ACK_ONLY" : "KCP_PUSH_RTP/PT33/MP2T/H264AnnexB") " +
                "video=\(XiaomiMirrorVideoDefaults.width)x\(XiaomiMirrorVideoDefaults.height)@\(frameRate)"
        )
    }

    private func applyOfficialMPTSocketBufferOptions(fd: Int32) {
        var sendBufferBytes: Int32 = Self.officialMPTSocketBufferBytes
        var receiveBufferBytes: Int32 = Self.officialMPTSocketBufferBytes
        let sendResult = withUnsafePointer(to: &sendBufferBytes) { pointer in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDBUF, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
        let sendErrno = sendResult == 0 ? 0 : errno
        let receiveResult = withUnsafePointer(to: &receiveBufferBytes) { pointer in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVBUF, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
        let receiveErrno = receiveResult == 0 ? 0 : errno
        DiagnosticsLog.info(
            "xiaomi.mirror.mpt.socket_options session=\(sessionID.uuidString) " +
                "sendBufferTarget=\(Self.officialMPTSocketBufferBytes) sendResult=\(sendResult) sendErrno=\(sendErrno) " +
                "receiveBufferTarget=\(Self.officialMPTSocketBufferBytes) receiveResult=\(receiveResult) receiveErrno=\(receiveErrno)"
        )
    }

    private func startMPTSinkPacketWatchdog() {
        guard mptSinkOnly, mptSinkPacketWatchdogTimer == nil else {
            return
        }
        lastMPTMediaPacketUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        lastMPTAnyPushUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.checkMPTSinkPacketWatchdog()
        }
        mptSinkPacketWatchdogTimer = timer
        timer.resume()
        DiagnosticsLog.info(
            "xiaomi.mirror.mpt.no_packet_watchdog_start session=\(sessionID.uuidString) " +
                "thresholdSeconds=\(Self.mptSinkNoPacketTimeoutSeconds) officialBehavior=stop_wifi_display_sink"
        )
    }

    private static func elapsedSeconds(since timestamp: UInt64, now: UInt64) -> Double {
        // Timestamps are also written from mptDecodeQueue (decoded-frame
        // callbacks), so a concurrently-written value can be newer than the
        // watchdog's `now`; clamp instead of trapping on UInt64 underflow.
        Double(now >= timestamp ? now - timestamp : 0) / 1_000_000_000
    }

    private func checkMPTSinkPacketWatchdog() {
        guard mptSinkOnly, !stopped else {
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        // Judge source liveness by any arriving push, not only in-order
        // delivered ones: a lost KCP segment blocks delivery while the
        // source keeps sending, and must go through resync instead of
        // source recovery.
        let elapsedMediaSeconds = Self.elapsedSeconds(since: lastMPTAnyPushUptimeNanoseconds, now: now)
        let elapsedFrameSeconds = mptSinkDecodedFrames > 0 || mptSinkRTPPacketsReceived > 20
            ? Self.elapsedSeconds(since: lastMPTDecodedFrameUptimeNanoseconds, now: now)
            : nil
        if elapsedMediaSeconds >= Self.mptSinkNoPacketTimeoutSeconds {
            let stall = mptStallSnapshot(
                reason: "no_packets_beyond_6s",
                elapsedMediaSeconds: elapsedMediaSeconds,
                elapsedFrameSeconds: elapsedFrameSeconds
            )
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.no_packets_timeout session=\(sessionID.uuidString) " +
                    "elapsedSeconds=\(String(format: "%.2f", elapsedMediaSeconds)) thresholdSeconds=\(Self.mptSinkNoPacketTimeoutSeconds) " +
                    "datagrams=\(kcpDatagramsReceived) pushReceived=\(kcpPUSHReceived) inboundRTP=\(mptSinkRTPPacketsReceived) " +
                    "decodedFrames=\(mptSinkDecodedFrames) officialAction=keep_sink_request_source_recovery"
            )
            onMPTMediaStalled?(stall)
            return
        }
        if let elapsedFrameSeconds,
           elapsedFrameSeconds >= Self.mptSinkNoFrameTimeoutSeconds,
           elapsedMediaSeconds < 2 {
            let stall = mptStallSnapshot(
                reason: "decoded_frame_stalled_beyond_threshold",
                elapsedMediaSeconds: elapsedMediaSeconds,
                elapsedFrameSeconds: elapsedFrameSeconds
            )
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.no_frame_timeout session=\(sessionID.uuidString) " +
                    "elapsedFrameSeconds=\(String(format: "%.2f", elapsedFrameSeconds)) " +
                    "thresholdSeconds=\(Self.mptSinkNoFrameTimeoutSeconds) " +
                    "elapsedMediaSeconds=\(String(format: "%.2f", elapsedMediaSeconds)) " +
                    "datagrams=\(kcpDatagramsReceived) pushReceived=\(kcpPUSHReceived) inboundRTP=\(mptSinkRTPPacketsReceived) " +
                    "decodedFrames=\(mptSinkDecodedFrames) officialAction=fast_source_recovery_keep_rtsp"
            )
            resetMPTSinkDecoderAfterFrameStallIfNeeded(
                elapsedFrameSeconds: elapsedFrameSeconds,
                elapsedMediaSeconds: elapsedMediaSeconds,
                now: now
            )
            onMPTMediaStalled?(stall)
        }
    }

    private func mptStallSnapshot(
        reason: String,
        elapsedMediaSeconds: Double,
        elapsedFrameSeconds: Double?
    ) -> XiaomiMirrorMPTStallSnapshot {
        XiaomiMirrorMPTStallSnapshot(
            sessionID: sessionID,
            reason: reason,
            elapsedMediaSeconds: elapsedMediaSeconds,
            elapsedFrameSeconds: elapsedFrameSeconds,
            datagramsReceived: kcpDatagramsReceived,
            pushReceived: kcpPUSHReceived,
            inboundRTP: mptSinkRTPPacketsReceived,
            decodedFrames: mptSinkDecodedFrames
        )
    }

    private func recordMPTMediaPacketActivity(reason: String) {
        guard mptSinkOnly else {
            return
        }
        lastMPTMediaPacketUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        if kcpPUSHReceived <= 5 || kcpPUSHReceived % 100 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.media_packet_activity session=\(sessionID.uuidString) " +
                    "reason=\(reason) pushReceived=\(kcpPUSHReceived) rtpReceived=\(mptSinkRTPPacketsReceived) " +
                    "decodedFrames=\(mptSinkDecodedFrames)"
            )
        }
    }

    private func startMPTReceiveSource(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.receiveMPTDatagrams()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        mptReadSource = source
        source.resume()
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if transportMode == .mpt {
                DiagnosticsLog.info(
                    "xiaomi.mirror.mpt.ready session=\(sessionID.uuidString) destination=\(destinationHost):\(destinationRTPPort)"
                )
            } else {
                DiagnosticsLog.info(
                    "xiaomi.mirror.rtp.ready session=\(sessionID.uuidString) destination=\(destinationHost):\(destinationRTPPort)"
                )
            }
        case .failed(let error):
            DiagnosticsLog.error("xiaomi.mirror.\(transportMode == .mpt ? "mpt" : "rtp").failed session=\(sessionID.uuidString)", error)
            stopOnQueue(reason: "udp_failed")
        case .cancelled:
            DiagnosticsLog.info("xiaomi.mirror.\(transportMode == .mpt ? "mpt" : "rtp").cancelled session=\(sessionID.uuidString)")
        default:
            break
        }
    }

    private func handleRTCPConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            DiagnosticsLog.info(
                "xiaomi.mirror.rtcp.ready session=\(sessionID.uuidString) destination=\(destinationHost):\(destinationRTCPPort)"
            )
        case .failed(let error):
            DiagnosticsLog.error("xiaomi.mirror.rtcp.failed session=\(sessionID.uuidString)", error)
        case .cancelled:
            DiagnosticsLog.info("xiaomi.mirror.rtcp.cancelled session=\(sessionID.uuidString)")
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

    private func startRTCPTimer() {
        rtcpTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.sendRTCPSenderReport()
        }
        rtcpTimer = timer
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
        guard !stopped, transportMode == .mpt || connection != nil else {
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
                marker: end == tsPackets.count
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

    private func sendRTPPayload(_ payload: Data, timestamp: UInt32, marker: Bool) {
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
        rtpPayloadOctetsSent += UInt64(payload.count)
        lastRTPTimestamp = timestamp
        if transportMode == .mpt {
            sendKCPPush(payload: packet, rtpSequence: currentSequence)
        } else {
            connection?.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    DiagnosticsLog.error(
                        "xiaomi.mirror.rtp.send_failed session=\(self.sessionID.uuidString) seq=\(currentSequence)",
                        error
                    )
                }
            })
        }
    }

    private func sendKCPPush(payload: Data, rtpSequence: UInt16) {
        let sn = kcpSendSN
        kcpSendSN &+= 1
        guard let packet = makeKCPSegment(
            cmd: Self.kcpCommandPush,
            ts: Self.monotonicMilliseconds(),
            sn: sn,
            una: kcpRemoteNextReceiveSN,
            payload: payload
        ) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.kcp_push_skipped session=\(sessionID.uuidString) reason=missing_conv sn=\(sn) rtpSeq=\(rtpSequence)"
            )
            return
        }
        guard sendMPTDatagram(packet) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.kcp_push_failed session=\(sessionID.uuidString) sn=\(sn) rtpSeq=\(rtpSequence) errno=\(errno)"
            )
            return
        }
        kcpPacketsSent += 1
        kcpBytesSent += UInt64(packet.count)
        if kcpPacketsSent <= 5 || kcpPacketsSent % 300 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.kcp_push_sent session=\(sessionID.uuidString) sn=\(sn) rtpSeq=\(rtpSequence) " +
                    "bytes=\(packet.count) payloadBytes=\(payload.count) una=\(kcpRemoteNextReceiveSN) " +
                    "packetsSent=\(kcpPacketsSent) bytesSent=\(kcpBytesSent)"
            )
        }
    }

    private func sendRTCPSenderReport() {
        guard !stopped, let rtcpConnection else {
            return
        }
        var packet = Data(capacity: 28)
        packet.append(0x80)
        packet.append(200)
        packet.appendUInt16(6)
        packet.appendUInt32(ssrc)
        let ntp = Self.currentNTPTimestamp()
        packet.appendUInt32(ntp.seconds)
        packet.appendUInt32(ntp.fraction)
        packet.appendUInt32(lastRTPTimestamp)
        packet.appendUInt32(UInt32(truncatingIfNeeded: rtpPacketsSent))
        packet.appendUInt32(UInt32(truncatingIfNeeded: rtpPayloadOctetsSent))
        let reportIndex = rtcpSRSent + 1
        rtcpConnection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.error(
                    "xiaomi.mirror.rtcp.sr_failed session=\(self.sessionID.uuidString) count=\(reportIndex)",
                    error
                )
            }
        })
        rtcpSRSent = reportIndex
        if rtcpSRSent <= 3 || rtcpSRSent % 5 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtcp.sr_sent session=\(sessionID.uuidString) count=\(rtcpSRSent) " +
                    "rtpPackets=\(rtpPacketsSent) octets=\(rtpPayloadOctetsSent) rtpTimestamp=\(lastRTPTimestamp)"
            )
        }
    }

    private func receiveRTCP() {
        guard !stopped, let rtcpConnection else {
            return
        }
        rtcpConnection.receiveMessage { [weak self] content, _, _, error in
            guard let self else {
                return
            }
            self.queue.async {
                if let error {
                    DiagnosticsLog.error("xiaomi.mirror.rtcp.receive_failed session=\(self.sessionID.uuidString)", error)
                    return
                }
                if let content, !content.isEmpty {
                    let packetType = content.count > 1 ? Int(content[1]) : -1
                    DiagnosticsLog.info(
                        "xiaomi.mirror.rtcp.received session=\(self.sessionID.uuidString) bytes=\(content.count) " +
                            "type=\(packetType) firstBytes=\(Self.hexPreview(content, limit: 12))"
                    )
                }
                self.receiveRTCP()
            }
        }
    }

    private func receiveMPTDatagrams() {
        guard !stopped, mptSocketFD >= 0 else {
            return
        }
        while true {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var sourceAddress = sockaddr_storage()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let byteCount = withUnsafeMutablePointer(to: &sourceAddress) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.recvfrom(mptSocketFD, &buffer, buffer.count, 0, sockaddrPointer, &sourceLength)
                }
            }
            if byteCount > 0 {
                kcpDatagramsReceived += 1
                let data = Data(buffer.prefix(byteCount))
                if let responseAddress = Self.ipv4SocketAddress(from: sourceAddress) {
                    mptDestinationAddress = responseAddress
                }
                if kcpDatagramsReceived <= 5 || kcpDatagramsReceived % 50 == 0 {
                    DiagnosticsLog.info(
                        "xiaomi.mirror.mpt.datagram_received session=\(sessionID.uuidString) bytes=\(byteCount) " +
                            "source=\(Self.describeSocketAddress(sourceAddress)) datagrams=\(kcpDatagramsReceived) " +
                            "firstBytes=\(Self.hexPreview(data, limit: 12))"
                    )
                }
                handleKCPDatagram(data)
                continue
            }
            if byteCount == 0 {
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            kcpDatagramReceiveErrors += 1
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.recvfrom_failed session=\(sessionID.uuidString) errno=\(errno) " +
                    "errors=\(kcpDatagramReceiveErrors)"
            )
            return
        }
    }

    private func handleKCPDatagram(_ data: Data) {
        var offset = 0
        var parsedSegments = 0
        while offset + Self.kcpHeaderLength <= data.count {
            guard let segment = KCPIncomingSegment(data: data, offset: offset) else {
                break
            }
            let segmentLength = Self.kcpHeaderLength + Int(segment.length)
            guard offset + segmentLength <= data.count else {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.kcp_malformed session=\(sessionID.uuidString) bytes=\(data.count) " +
                        "offset=\(offset) declaredLength=\(segment.length)"
                )
                break
            }
            handleKCPSegment(segment)
            offset += segmentLength
            parsedSegments += 1
        }
        if parsedSegments == 0 {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.kcp_malformed session=\(sessionID.uuidString) bytes=\(data.count) " +
                    "firstBytes=\(Self.hexPreview(data, limit: 16))"
            )
        }
    }

    private func handleKCPSegment(_ segment: KCPIncomingSegment) {
        guard establishKCPConversationIfNeeded(from: segment) else {
            logIgnoredKCPConversation(segment)
            return
        }
        guard segment.conv == kcpConversationID else {
            logIgnoredKCPConversation(segment)
            return
        }
        switch segment.command {
        case Self.kcpCommandACK:
            kcpACKsReceived += 1
            kcpLatestACKSN = segment.sn
            kcpLatestRemoteUNA = segment.una
            if kcpACKsReceived <= 5 || kcpACKsReceived % 100 == 0 {
                DiagnosticsLog.info(
                    "xiaomi.mirror.mpt.kcp_ack_received session=\(sessionID.uuidString) sn=\(segment.sn) " +
                        "una=\(segment.una) ts=\(segment.ts) acks=\(kcpACKsReceived) packetsSent=\(kcpPacketsSent)"
                )
            }
        case Self.kcpCommandWASK:
            kcpWASKReceived += 1
            sendKCPWINS(responseTo: segment)
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.kcp_wask_received session=\(sessionID.uuidString) count=\(kcpWASKReceived) " +
                    "sn=\(segment.sn) una=\(segment.una)"
            )
        case Self.kcpCommandWINS:
            kcpWINSReceived += 1
            if kcpWINSReceived <= 5 || kcpWINSReceived % 20 == 0 {
                DiagnosticsLog.info(
                    "xiaomi.mirror.mpt.kcp_wins_received session=\(sessionID.uuidString) count=\(kcpWINSReceived) " +
                        "sn=\(segment.sn) una=\(segment.una)"
                )
            }
        case Self.kcpCommandPush:
            kcpPUSHReceived += 1
            handleKCPPush(segment)
        default:
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.kcp_unknown_received session=\(sessionID.uuidString) " +
                    "cmd=0x\(String(segment.command, radix: 16)) sn=\(segment.sn) len=\(segment.length)"
            )
        }
    }

    private func handleKCPPush(_ segment: KCPIncomingSegment) {
        // Any arriving push — even out-of-order or buffered — proves the
        // source is still sending. Head-of-line blocking behind a lost
        // segment must not read as "no packets from source".
        lastMPTAnyPushUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        if mptSinkOnly,
           mptSinkRTPPacketsReceived == 0,
           kcpReceiveBuffer.isEmpty,
           kcpRemoteNextReceiveSN == 0,
           segment.sn != 0 {
            kcpRemoteNextReceiveSN = segment.sn
            resetMPTSinkAfterTransportLoss(
                reason: "kcp_first_push_resync",
                detail: "sn=\(segment.sn)"
            )
        }
        let delta = Self.sequenceDelta(segment.sn, from: kcpRemoteNextReceiveSN)
        if delta == 0 {
            deliverKCPPush(segment)
            kcpRemoteNextReceiveSN &+= 1
            drainKCPReceiveBuffer()
            sendKCPACK(responseTo: segment)
            return
        }
        if delta < 0 {
            kcpDuplicateDroppedCount += 1
            sendKCPACK(responseTo: segment)
            if kcpDuplicateDroppedCount <= 5 || kcpDuplicateDroppedCount % 50 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.kcp_duplicate_dropped session=\(sessionID.uuidString) " +
                        "sn=\(segment.sn) expected=\(kcpRemoteNextReceiveSN) duplicates=\(kcpDuplicateDroppedCount)"
                )
            }
            return
        }

        if kcpReceiveBuffer.count >= Self.kcpReceiveBufferLimit || delta > Int64(Self.kcpReceiveMaxGap) {
            kcpReceiveResyncCount += 1
            kcpReceiveBuffer.removeAll(keepingCapacity: true)
            resetKCPOutOfOrderTracking()
            resetMPTSinkAfterTransportLoss(
                reason: "kcp_receive_resync",
                detail: "sn=\(segment.sn) expected=\(kcpRemoteNextReceiveSN) gap=\(delta)"
            )
            kcpRemoteNextReceiveSN = segment.sn
            deliverKCPPush(segment)
            kcpRemoteNextReceiveSN &+= 1
            sendKCPACK(responseTo: segment)
            return
        }

        noteKCPOutOfOrderBufferingIfNeeded()
        if kcpReceiveBuffer[segment.sn] == nil {
            kcpReceiveBuffer[segment.sn] = segment
            kcpOutOfOrderBufferedCount += 1
        }
        if shouldResyncStalledKCPReceiveBuffer(delta: delta) {
            resyncStalledKCPReceiveBuffer(responseTo: segment, delta: delta)
            return
        }
        sendKCPACK(responseTo: segment)
        if kcpOutOfOrderBufferedCount <= 5 || kcpOutOfOrderBufferedCount % 50 == 0 {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.kcp_out_of_order_buffered session=\(sessionID.uuidString) " +
                    "sn=\(segment.sn) expected=\(kcpRemoteNextReceiveSN) gap=\(delta) " +
                    "buffered=\(kcpReceiveBuffer.count) total=\(kcpOutOfOrderBufferedCount)"
            )
        }
    }

    private func drainKCPReceiveBuffer() {
        while let segment = kcpReceiveBuffer.removeValue(forKey: kcpRemoteNextReceiveSN) {
            deliverKCPPush(segment)
            kcpRemoteNextReceiveSN &+= 1
        }
        if kcpReceiveBuffer.isEmpty {
            resetKCPOutOfOrderTracking()
        }
    }

    private func noteKCPOutOfOrderBufferingIfNeeded() {
        guard kcpReceiveBuffer.isEmpty,
              kcpOutOfOrderStartedUptimeNanoseconds == 0 else {
            return
        }
        kcpOutOfOrderStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        kcpOutOfOrderExpectedSN = kcpRemoteNextReceiveSN
    }

    private func shouldResyncStalledKCPReceiveBuffer(delta: Int64) -> Bool {
        guard mptSinkOnly,
              !kcpReceiveBuffer.isEmpty,
              kcpOutOfOrderStartedUptimeNanoseconds > 0 else {
            return false
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - kcpOutOfOrderStartedUptimeNanoseconds >= Self.kcpReceiveStallResyncDelayNanoseconds else {
            return false
        }
        // At low packet rates (static screen) the count/gap thresholds below
        // can take longer than the 6s stall watchdog, so bound any
        // head-of-line stall by time as well.
        if !kcpReceiveBuffer.isEmpty,
           now - kcpOutOfOrderStartedUptimeNanoseconds >= Self.kcpReceiveStallResyncMaxStallNanoseconds {
            return true
        }
        return delta >= Self.kcpReceiveStallResyncMinGap ||
            kcpReceiveBuffer.count >= Self.kcpReceiveStallResyncMinBuffered
    }

    private func resyncStalledKCPReceiveBuffer(responseTo segment: KCPIncomingSegment, delta: Int64) {
        guard let targetSN = kcpReceiveBuffer.keys.min() else {
            return
        }
        let previousExpected = kcpOutOfOrderExpectedSN ?? kcpRemoteNextReceiveSN
        let buffered = kcpReceiveBuffer.count
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - kcpOutOfOrderStartedUptimeNanoseconds) / 1_000_000
        kcpReceiveResyncCount += 1
        resetMPTSinkAfterTransportLoss(
            reason: "kcp_out_of_order_stalled_resync",
            detail: "target=\(targetSN) expected=\(previousExpected) gap=\(delta) buffered=\(buffered) elapsedMs=\(String(format: "%.0f", elapsedMs))"
        )
        kcpRemoteNextReceiveSN = targetSN
        drainKCPReceiveBuffer()
        sendKCPACK(responseTo: segment)
        DiagnosticsLog.warn(
            "xiaomi.mirror.mpt.kcp_out_of_order_stalled_resync session=\(sessionID.uuidString) " +
                "target=\(targetSN) previousExpected=\(previousExpected) gap=\(delta) " +
                "buffered=\(buffered) elapsedMs=\(String(format: "%.0f", elapsedMs)) " +
                "resyncs=\(kcpReceiveResyncCount)"
        )
    }

    private func resetKCPOutOfOrderTracking() {
        kcpOutOfOrderStartedUptimeNanoseconds = 0
        kcpOutOfOrderExpectedSN = nil
    }

    private func deliverKCPPush(_ segment: KCPIncomingSegment) {
        recordMPTMediaPacketActivity(reason: "kcp_push")
        if kcpPUSHReceived <= 5 || kcpPUSHReceived % 20 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.kcp_push_received session=\(sessionID.uuidString) sn=\(segment.sn) " +
                    "payloadBytes=\(segment.length) remoteNext=\(kcpRemoteNextReceiveSN) " +
                    "pushReceived=\(kcpPUSHReceived) payloadFirstBytes=\(Self.hexPreview(segment.payload, limit: 12))"
            )
        }
        handleMPTSinkKCPPayload(segment.payload, sn: segment.sn)
    }

    private func handleMPTSinkKCPPayload(_ payload: Data, sn: UInt32) {
        guard mptSinkOnly, !payload.isEmpty else {
            return
        }
        mptSinkInterleavedBuffer.append(payload)
        while !mptSinkInterleavedBuffer.isEmpty {
            if mptSinkInterleavedBuffer[0] != Self.rtspInterleavedMagic {
                if looksLikeRTPPacket(mptSinkInterleavedBuffer) {
                    handleMPTSinkRTPPacket(mptSinkInterleavedBuffer, channel: nil, sn: sn)
                    mptSinkInterleavedBuffer.removeAll(keepingCapacity: true)
                    return
                }
                guard let nextFrame = mptSinkInterleavedBuffer.firstIndex(of: Self.rtspInterleavedMagic) else {
                    mptSinkInterleavedMalformedCount += 1
                    if mptSinkInterleavedMalformedCount <= 5 || mptSinkInterleavedMalformedCount % 20 == 0 {
                        DiagnosticsLog.warn(
                            "xiaomi.mirror.mpt.rtsp_interleaved_resync_failed session=\(sessionID.uuidString) " +
                                "sn=\(sn) bufferedBytes=\(mptSinkInterleavedBuffer.count) " +
                                "firstBytes=\(Self.hexPreview(mptSinkInterleavedBuffer, limit: 16)) " +
                                "malformed=\(mptSinkInterleavedMalformedCount)"
                        )
                    }
                    mptSinkInterleavedBuffer.removeAll(keepingCapacity: true)
                    return
                }
                mptSinkInterleavedMalformedCount += 1
                if mptSinkInterleavedMalformedCount <= 5 || mptSinkInterleavedMalformedCount % 20 == 0 {
                    DiagnosticsLog.warn(
                        "xiaomi.mirror.mpt.rtsp_interleaved_resync session=\(sessionID.uuidString) " +
                            "sn=\(sn) discardedBytes=\(nextFrame) malformed=\(mptSinkInterleavedMalformedCount)"
                    )
                }
                mptSinkInterleavedBuffer.removeSubrange(0..<nextFrame)
            }

            guard mptSinkInterleavedBuffer.count >= Self.rtspInterleavedHeaderLength,
                  let rtpLength = mptSinkInterleavedBuffer.readUInt16BE(at: 2) else {
                return
            }
            let frameLength = Self.rtspInterleavedHeaderLength + Int(rtpLength)
            guard mptSinkInterleavedBuffer.count >= frameLength else {
                return
            }
            let channel = mptSinkInterleavedBuffer[1]
            let rtpPacket = mptSinkInterleavedBuffer.subdata(in: Self.rtspInterleavedHeaderLength..<frameLength)
            mptSinkInterleavedBuffer.removeSubrange(0..<frameLength)
            mptSinkInterleavedFramesReceived += 1
            handleMPTSinkRTPPacket(rtpPacket, channel: channel, sn: sn)
        }
    }

    private func handleMPTSinkRTPPacket(_ data: Data, channel: UInt8?, sn: UInt32) {
        guard let packet = RTPIncomingPacket(data: data) else {
            mptSinkRTPMalformedCount += 1
            if mptSinkRTPMalformedCount <= 5 || mptSinkRTPMalformedCount % 20 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.rtp_malformed session=\(sessionID.uuidString) " +
                        "sn=\(sn) channel=\(channel.map(String.init) ?? "raw") bytes=\(data.count) " +
                        "firstBytes=\(Self.hexPreview(data, limit: 16)) malformed=\(mptSinkRTPMalformedCount)"
                )
            }
            return
        }
        guard packet.payloadType == Self.mpegTSPayloadType else {
            mptSinkRTPMalformedCount += 1
            if mptSinkRTPMalformedCount <= 5 || mptSinkRTPMalformedCount % 20 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.rtp_payload_ignored session=\(sessionID.uuidString) " +
                        "pt=\(packet.payloadType) expected=\(Self.mpegTSPayloadType) seq=\(packet.sequenceNumber) " +
                        "sn=\(sn) ignored=\(mptSinkRTPMalformedCount)"
                )
            }
            return
        }
        guard acceptMPTSinkRTPSequence(packet) else {
            return
        }
        mptSinkRTPPacketsReceived += 1
        let tsInfo = Self.inspectMPEGTS(packet.payload)
        mptSinkTSPacketsReceived += UInt64(tsInfo.packetCount)
        if tsInfo.sync {
            captureMPTSinkTS(packet.payload)
            mptSinkTSDemuxer?.pushTSPayload(packet.payload, rtpTimestamp: packet.timestamp)
        }
        if mptSinkRTPPacketsReceived <= 10 || mptSinkRTPPacketsReceived % 100 == 0 || !tsInfo.sync {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.rtp_received session=\(sessionID.uuidString) " +
                    "pt=\(packet.payloadType) tsPackets=\(tsInfo.packetCount) sync=\(tsInfo.sync) " +
                    "seq=\(packet.sequenceNumber) marker=\(packet.marker) timestamp=\(packet.timestamp) " +
                    "ssrc=\(Self.hex32(packet.ssrc)) channel=\(channel.map(String.init) ?? "raw") " +
                    "sn=\(sn) rtpBytes=\(data.count) payloadBytes=\(packet.payload.count) " +
                    "firstPID=\(tsInfo.firstPacket.map { Self.hexPID($0.pid) } ?? "none") " +
                    "firstPUSI=\(tsInfo.firstPacket.map { String($0.payloadUnitStart) } ?? "none") " +
                    "firstAFC=\(tsInfo.firstPacket.map { String($0.adaptationFieldControl) } ?? "none") " +
                    "firstCC=\(tsInfo.firstPacket.map { String($0.continuityCounter) } ?? "none") " +
                    "interleavedFrames=\(mptSinkInterleavedFramesReceived) rtpReceived=\(mptSinkRTPPacketsReceived) " +
                    "tsReceived=\(mptSinkTSPacketsReceived) tsCapturePath=\(Self.mptSinkTSCapturePath) " +
                    "tsCaptureBytes=\(mptSinkTSCaptureBytes)"
            )
        }
    }

    private func acceptMPTSinkRTPSequence(_ packet: RTPIncomingPacket) -> Bool {
        guard let lastSequence = mptSinkLastRTPSequenceNumber else {
            mptSinkLastRTPSequenceNumber = packet.sequenceNumber
            return true
        }
        let delta = Self.sequenceDelta(packet.sequenceNumber, from: lastSequence)
        if delta == 0 || delta < 0 {
            mptSinkRTPDuplicateDroppedCount += 1
            if mptSinkRTPDuplicateDroppedCount <= 5 || mptSinkRTPDuplicateDroppedCount % 50 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.rtp_duplicate_dropped session=\(sessionID.uuidString) " +
                        "seq=\(packet.sequenceNumber) last=\(lastSequence) delta=\(delta) " +
                        "duplicates=\(mptSinkRTPDuplicateDroppedCount)"
                )
            }
            return false
        }
        if delta > 1 {
            mptSinkRTPSequenceGapCount += 1
            resetMPTSinkAfterTransportLoss(
                reason: "rtp_sequence_gap",
                detail: "seq=\(packet.sequenceNumber) expected=\(lastSequence &+ 1) gap=\(delta - 1)"
            )
        }
        mptSinkLastRTPSequenceNumber = packet.sequenceNumber
        return true
    }

    private func resetMPTSinkAfterTransportLoss(reason: String, detail: String) {
        mptSinkInterleavedBuffer.removeAll(keepingCapacity: true)
        mptSinkTSDemuxer?.noteTransportDiscontinuity(reason: reason)
        if let decoder = mptSinkHEVCDecoder {
            mptDecodeQueue.async {
                decoder.requireRandomAccess(reason: reason)
            }
        }
        DiagnosticsLog.warn(
            "xiaomi.mirror.mpt.transport_discontinuity session=\(sessionID.uuidString) " +
                "reason=\(reason) \(detail) kcpResync=\(kcpReceiveResyncCount) " +
                "rtpGaps=\(mptSinkRTPSequenceGapCount)"
        )
    }

    private func resetMPTSinkDecoderAfterFrameStallIfNeeded(
        elapsedFrameSeconds: Double,
        elapsedMediaSeconds: Double,
        now: UInt64
    ) {
        if lastMPTFrameStallDecoderResetUptimeNanoseconds > 0 {
            let elapsedSinceReset = Double(now - lastMPTFrameStallDecoderResetUptimeNanoseconds) / 1_000_000_000
            guard elapsedSinceReset >= Self.mptSinkFrameStallDecoderResetMinIntervalSeconds else {
                DiagnosticsLog.info(
                    "xiaomi.mirror.mpt.decoder_reset_for_frame_stall_skipped session=\(sessionID.uuidString) " +
                        "elapsedSinceReset=\(String(format: "%.2f", elapsedSinceReset)) " +
                        "minIntervalSeconds=\(Self.mptSinkFrameStallDecoderResetMinIntervalSeconds) " +
                        "decodedFrames=\(mptSinkDecodedFrames) inboundRTP=\(mptSinkRTPPacketsReceived)"
                )
                return
            }
        }
        lastMPTFrameStallDecoderResetUptimeNanoseconds = now
        mptSinkFrameStallDecoderResetCount += 1
        let resetCount = mptSinkFrameStallDecoderResetCount
        if let decoder = mptSinkHEVCDecoder {
            mptDecodeQueue.async {
                decoder.resetOnNextRandomAccess(reason: "decoded_frame_stall_decoder_reset_\(resetCount)")
            }
        }
        DiagnosticsLog.warn(
            "xiaomi.mirror.mpt.decoder_reset_deferred_for_frame_stall session=\(sessionID.uuidString) " +
                "count=\(resetCount) elapsedFrameSeconds=\(String(format: "%.2f", elapsedFrameSeconds)) " +
                "elapsedMediaSeconds=\(String(format: "%.2f", elapsedMediaSeconds)) " +
                "datagrams=\(kcpDatagramsReceived) pushReceived=\(kcpPUSHReceived) " +
                "inboundRTP=\(mptSinkRTPPacketsReceived) decodedFrames=\(mptSinkDecodedFrames)"
        )
    }

    private func captureMPTSinkTS(_ payload: Data) {
        guard mptSinkTSCaptureBytes < Self.mptSinkTSCaptureLimitBytes else {
            return
        }
        let remaining = Self.mptSinkTSCaptureLimitBytes - mptSinkTSCaptureBytes
        let writeCount = min(remaining, payload.count)
        guard writeCount > 0 else {
            return
        }
        if mptSinkTSCaptureHandle == nil {
            if !FileManager.default.fileExists(atPath: Self.mptSinkTSCapturePath) {
                FileManager.default.createFile(atPath: Self.mptSinkTSCapturePath, contents: nil)
            }
            mptSinkTSCaptureHandle = FileHandle(forWritingAtPath: Self.mptSinkTSCapturePath)
            mptSinkTSCaptureHandle?.truncateFile(atOffset: 0)
            if !mptSinkTSCaptureStartLogged {
                mptSinkTSCaptureStartLogged = true
                DiagnosticsLog.info(
                    "xiaomi.mirror.mpt.ts_capture_start session=\(sessionID.uuidString) " +
                        "path=\(Self.mptSinkTSCapturePath) limitBytes=\(Self.mptSinkTSCaptureLimitBytes)"
                )
            }
        }
        guard let handle = mptSinkTSCaptureHandle else {
            return
        }
        handle.seekToEndOfFile()
        handle.write(payload.prefix(writeCount))
        mptSinkTSCaptureBytes += writeCount
        if mptSinkTSCaptureBytes == Self.mptSinkTSCaptureLimitBytes {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.ts_capture_limit_reached session=\(sessionID.uuidString) " +
                    "path=\(Self.mptSinkTSCapturePath) bytes=\(mptSinkTSCaptureBytes)"
            )
        }
    }

    private func handleDecodedMPTSinkFrame(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        mptSinkDecodedFrames += 1
        lastMPTDecodedFrameUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        if mptSinkDecodedFrames <= 5 || mptSinkDecodedFrames % 60 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.hevc_frame_decoded session=\(sessionID.uuidString) " +
                    "frames=\(mptSinkDecodedFrames) size=\(width)x\(height)"
            )
        }
        onDecodedFrame?(pixelBuffer, width, height)
    }

    private func looksLikeRTPPacket(_ data: Data) -> Bool {
        guard data.count >= Self.rtpMinimumHeaderLength else {
            return false
        }
        return (data[0] >> 6) == 2
    }

    private func sendKCPACK(responseTo segment: KCPIncomingSegment) {
        guard let packet = makeKCPSegment(
            cmd: Self.kcpCommandACK,
            ts: segment.ts,
            sn: segment.sn,
            una: kcpRemoteNextReceiveSN,
            payload: Data()
        ) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.kcp_ack_send_skipped session=\(sessionID.uuidString) reason=missing_conv " +
                    "peerConv=\(Self.hex32(segment.conv)) sn=\(segment.sn)"
            )
            return
        }
        if sendMPTDatagram(packet) {
            kcpACKSent += 1
            if kcpACKSent <= 5 || kcpACKSent % 50 == 0 {
                DiagnosticsLog.info(
                    "xiaomi.mirror.mpt.kcp_ack_sent session=\(sessionID.uuidString) sn=\(segment.sn) " +
                        "una=\(kcpRemoteNextReceiveSN) conv=\(Self.hex32(segment.conv)) ackSent=\(kcpACKSent)"
                )
            }
        } else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.kcp_ack_send_failed session=\(sessionID.uuidString) sn=\(segment.sn) errno=\(errno)"
            )
        }
    }

    private func sendKCPWINS(responseTo segment: KCPIncomingSegment) {
        guard let packet = makeKCPSegment(
            cmd: Self.kcpCommandWINS,
            ts: segment.ts,
            sn: segment.sn,
            una: kcpRemoteNextReceiveSN,
            payload: Data()
        ) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.kcp_wins_send_skipped session=\(sessionID.uuidString) reason=missing_conv " +
                    "peerConv=\(Self.hex32(segment.conv)) sn=\(segment.sn)"
            )
            return
        }
        if sendMPTDatagram(packet) {
            kcpWINSSent += 1
        } else {
            DiagnosticsLog.warn("xiaomi.mirror.mpt.kcp_wins_send_failed session=\(sessionID.uuidString) errno=\(errno)")
        }
    }

    private func sendMPTDatagram(_ packet: Data) -> Bool {
        if let onExternalDatagramSend {
            onExternalDatagramSend(packet)
            return true
        }
        guard mptSocketFD >= 0, var destination = mptDestinationAddress else {
            return false
        }
        let sent = packet.withUnsafeBytes { rawBuffer -> ssize_t in
            guard let baseAddress = rawBuffer.baseAddress else {
                return -1
            }
            return withUnsafePointer(to: &destination) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.sendto(
                        mptSocketFD,
                        baseAddress,
                        packet.count,
                        0,
                        sockaddrPointer,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        return sent == packet.count
    }

    private func makeKCPSegment(cmd: UInt8, ts: UInt32, sn: UInt32, una: UInt32, payload: Data) -> Data? {
        guard let conv = kcpConversationID else {
            return nil
        }
        var packet = Data(capacity: Self.kcpHeaderLength + payload.count)
        packet.appendUInt32LE(conv)
        packet.append(cmd)
        packet.append(0)
        packet.appendUInt16LE(Self.kcpReceiveWindow)
        packet.appendUInt32LE(ts)
        packet.appendUInt32LE(sn)
        packet.appendUInt32LE(una)
        packet.appendUInt32LE(UInt32(truncatingIfNeeded: payload.count))
        packet.append(payload)
        return packet
    }

    private func establishKCPConversationIfNeeded(from segment: KCPIncomingSegment) -> Bool {
        if kcpConversationID != nil {
            return true
        }
        guard mptSinkOnly else {
            kcpConversationID = Self.defaultKCPConversationID
            return true
        }
        guard Self.isKnownKCPCommand(segment.command), segment.conv != 0 else {
            return false
        }
        kcpConversationID = segment.conv
        if segment.command == Self.kcpCommandPush {
            kcpRemoteNextReceiveSN = segment.sn
        }
        DiagnosticsLog.info(
            "xiaomi.mirror.mpt.kcp_conv_initialized session=\(sessionID.uuidString) " +
                "role=sink_receiver conv=\(Self.hex32(segment.conv)) cmd=0x\(String(segment.command, radix: 16)) " +
                "sn=\(segment.sn) una=\(segment.una) len=\(segment.length)"
        )
        return true
    }

    private func logIgnoredKCPConversation(_ segment: KCPIncomingSegment) {
        kcpConversationIgnoredCount += 1
        if kcpConversationIgnoredCount <= 5 || kcpConversationIgnoredCount % 50 == 0 {
            let expected = kcpConversationID.map { Self.hex32($0) } ?? "uninitialized"
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.kcp_conv_ignored session=\(sessionID.uuidString) " +
                    "expected=\(expected) actual=\(Self.hex32(segment.conv)) " +
                    "cmd=0x\(String(segment.command, radix: 16)) sn=\(segment.sn) count=\(kcpConversationIgnoredCount)"
            )
        }
    }

    private static func currentNTPTimestamp() -> (seconds: UInt32, fraction: UInt32) {
        let ntpEpochOffset: TimeInterval = 2_208_988_800
        let timestamp = Date().timeIntervalSince1970 + ntpEpochOffset
        let seconds = UInt32(timestamp)
        let fraction = UInt32((timestamp - floor(timestamp)) * 4_294_967_296)
        return (seconds, fraction)
    }

    private static func monotonicMilliseconds() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private static func hexPreview(_ data: Data, limit: Int) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func hex32(_ value: UInt32) -> String {
        String(format: "0x%08x", value)
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatOptionalSeconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "none"
    }

    private func stopOnQueue(reason: String) {
        guard !stopped || connection != nil || rtcpConnection != nil || frameTimer != nil ||
            rtcpTimer != nil || mptSinkPacketWatchdogTimer != nil || externalRTPReceiverStarted else {
            return
        }
        stopped = true
        externalRTPReceiverStarted = false
        frameTimer?.cancel()
        frameTimer = nil
        rtcpTimer?.cancel()
        rtcpTimer = nil
        mptSinkPacketWatchdogTimer?.cancel()
        mptSinkPacketWatchdogTimer = nil
        encoder.invalidate()
        mptReadSource?.cancel()
        mptReadSource = nil
        mptSocketFD = -1
        mptDestinationAddress = nil
        connection?.cancel()
        connection = nil
        rtcpConnection?.cancel()
        rtcpConnection = nil
        mptSinkTSCaptureHandle?.closeFile()
        mptSinkTSCaptureHandle = nil
        mptSinkTSDemuxer?.flush()
        let audioPlayer = mptSinkAudioPlayer
        let decoder = mptSinkHEVCDecoder
        mptDecodeQueue.async {
            audioPlayer?.stop(reason: reason)
            decoder?.invalidate()
        }
        if transportMode == .mpt {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.stop session=\(sessionID.uuidString) reason=\(reason) " +
                    "frames=\(framesSent) rtpPackets=\(rtpPacketsSent) kcpPackets=\(kcpPacketsSent) " +
                    "bytesSent=\(kcpBytesSent) acks=\(kcpACKsReceived) ackSent=\(kcpACKSent) " +
                    "wask=\(kcpWASKReceived) winsReceived=\(kcpWINSReceived) winsSent=\(kcpWINSSent) " +
                    "pushReceived=\(kcpPUSHReceived) datagrams=\(kcpDatagramsReceived) recvErrors=\(kcpDatagramReceiveErrors) " +
                    "interleavedFrames=\(mptSinkInterleavedFramesReceived) inboundRTP=\(mptSinkRTPPacketsReceived) " +
                    "inboundTS=\(mptSinkTSPacketsReceived) rtpMalformed=\(mptSinkRTPMalformedCount) " +
                    "interleavedMalformed=\(mptSinkInterleavedMalformedCount) tsCaptureBytes=\(mptSinkTSCaptureBytes) " +
                    "decodedFrames=\(mptSinkDecodedFrames) decodeFailed=\(mptSinkDecodeFailedFrames) " +
                    "tsCapturePath=\(Self.mptSinkTSCapturePath) " +
                    "latestAck=\(kcpLatestACKSN.map(String.init) ?? "none") " +
                    "latestRemoteUna=\(kcpLatestRemoteUNA.map(String.init) ?? "none") " +
                    "conv=\(kcpConversationID.map { Self.hex32($0) } ?? "none") convIgnored=\(kcpConversationIgnoredCount)"
            )
        } else {
            DiagnosticsLog.info(
                "xiaomi.mirror.rtp.stop session=\(sessionID.uuidString) reason=\(reason) " +
                    "frames=\(framesSent) rtpPackets=\(rtpPacketsSent) rtcpSR=\(rtcpSRSent)"
            )
        }
    }

    private static let defaultKCPConversationID: UInt32 = 0x1234_5678
    private static let kcpCommandPush: UInt8 = 0x51
    private static let kcpCommandACK: UInt8 = 0x52
    private static let kcpCommandWASK: UInt8 = 0x53
    private static let kcpCommandWINS: UInt8 = 0x54
    private static let kcpHeaderLength = 24
    private static let kcpReceiveWindow: UInt16 = 600
    private static let kcpReceiveBufferLimit = 600
    private static let kcpReceiveMaxGap: UInt32 = 1_200
    private static let kcpReceiveStallResyncDelayNanoseconds: UInt64 = 250_000_000
    private static let kcpReceiveStallResyncMaxStallNanoseconds: UInt64 = 1_500_000_000
    private static let kcpReceiveStallResyncMinGap: Int64 = 128
    private static let kcpReceiveStallResyncMinBuffered = 48
    private static let officialMPTSocketBufferBytes: Int32 = 6_291_456
    private static let mptSinkNoPacketTimeoutSeconds: Double = 6
    private static let mptSinkNoFrameTimeoutSeconds: Double = 2
    private static let mptSinkFrameStallDecoderResetMinIntervalSeconds: Double = 1.5
    private static let rtspInterleavedMagic: UInt8 = 0x24
    private static let rtspInterleavedHeaderLength = 4
    private static let rtpMinimumHeaderLength = 12
    private static let mpegTSPayloadType: UInt8 = 33
    private static let mpegTSPacketLength = 188
    private static let mptSinkTSCapturePath = "/private/tmp/edgelink-xiaomi-mirror.ts"
    private static let mptSinkTSCaptureLimitBytes = 8 * 1024 * 1024

    private static func isKnownKCPCommand(_ command: UInt8) -> Bool {
        command == kcpCommandPush || command == kcpCommandACK || command == kcpCommandWASK || command == kcpCommandWINS
    }

    private static func inspectMPEGTS(_ payload: Data) -> MPEGTSInspection {
        let packetCount = payload.count / mpegTSPacketLength
        let sync = packetCount > 0 &&
            payload.count % mpegTSPacketLength == 0 &&
            (0..<packetCount).allSatisfy { payload[$0 * mpegTSPacketLength] == 0x47 }
        let firstPacket: MPEGTSFirstPacket?
        if sync,
           payload.count >= mpegTSPacketLength {
            let pid = (UInt16(payload[1] & 0x1f) << 8) | UInt16(payload[2])
            firstPacket = MPEGTSFirstPacket(
                pid: pid,
                payloadUnitStart: (payload[1] & 0x40) != 0,
                adaptationFieldControl: (payload[3] >> 4) & 0x03,
                continuityCounter: payload[3] & 0x0f
            )
        } else {
            firstPacket = nil
        }
        return MPEGTSInspection(packetCount: packetCount, sync: sync, firstPacket: firstPacket)
    }

    private static func hexPID(_ value: UInt16) -> String {
        String(format: "0x%04x", value)
    }

    private static func sequenceDelta(_ current: UInt32, from previous: UInt32) -> Int64 {
        Int64(Int32(bitPattern: current &- previous))
    }

    private static func sequenceDelta(_ current: UInt16, from previous: UInt16) -> Int {
        Int(Int16(bitPattern: current &- previous))
    }

    private static func anyIPv4SocketAddress(port: UInt16) -> sockaddr_in {
        sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: INADDR_ANY.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
    }

    private static func makeIPv4SocketAddress(host: String, port: UInt16) -> sockaddr_in? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else {
            return nil
        }
        return sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: address,
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
    }

    private static func ipv4SocketAddress(from storage: sockaddr_storage) -> sockaddr_in? {
        guard Int32(storage.ss_family) == AF_INET else {
            return nil
        }
        var copy = storage
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addressPointer in
                addressPointer.pointee
            }
        }
    }

    private static func describeSocketAddress(_ storage: sockaddr_storage) -> String {
        guard Int32(storage.ss_family) == AF_INET else {
            return "family:\(storage.ss_family)"
        }
        var copy = storage
        var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let port = withUnsafePointer(to: &copy) { pointer -> UInt16 in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addressPointer in
                let address = addressPointer.pointee
                var addr = address.sin_addr
                inet_ntop(AF_INET, &addr, &hostBuffer, socklen_t(hostBuffer.count))
                return UInt16(bigEndian: address.sin_port)
            }
        }
        let host = String(cString: hostBuffer)
        return "\(host):\(port)"
    }
}

private struct KCPIncomingSegment {
    let conv: UInt32
    let command: UInt8
    let fragment: UInt8
    let window: UInt16
    let ts: UInt32
    let sn: UInt32
    let una: UInt32
    let length: UInt32
    let payload: Data

    init?(data: Data, offset: Int) {
        guard offset + 24 <= data.count,
              let conv = data.readUInt32LE(at: offset),
              let window = data.readUInt16LE(at: offset + 6),
              let ts = data.readUInt32LE(at: offset + 8),
              let sn = data.readUInt32LE(at: offset + 12),
              let una = data.readUInt32LE(at: offset + 16),
              let length = data.readUInt32LE(at: offset + 20) else {
            return nil
        }
        self.conv = conv
        self.command = data[offset + 4]
        self.fragment = data[offset + 5]
        self.window = window
        self.ts = ts
        self.sn = sn
        self.una = una
        self.length = length
        let payloadStart = offset + 24
        let payloadEnd = payloadStart + Int(length)
        self.payload = payloadEnd <= data.count ? data[payloadStart..<payloadEnd] : Data()
    }
}

private struct RTPIncomingPacket {
    let marker: Bool
    let payloadType: UInt8
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payload: Data

    init?(data: Data) {
        guard data.count >= 12,
              (data[0] >> 6) == 2,
              let sequenceNumber = data.readUInt16BE(at: 2),
              let timestamp = data.readUInt32BE(at: 4),
              let ssrc = data.readUInt32BE(at: 8) else {
            return nil
        }
        let csrcCount = Int(data[0] & 0x0f)
        var headerLength = 12 + csrcCount * 4
        guard data.count >= headerLength else {
            return nil
        }
        if (data[0] & 0x10) != 0 {
            guard data.count >= headerLength + 4,
                  let extensionLengthWords = data.readUInt16BE(at: headerLength + 2) else {
                return nil
            }
            headerLength += 4 + Int(extensionLengthWords) * 4
            guard data.count >= headerLength else {
                return nil
            }
        }
        var payloadEnd = data.count
        if (data[0] & 0x20) != 0 {
            guard let paddingLength = data.last,
                  paddingLength > 0,
                  Int(paddingLength) <= data.count - headerLength else {
                return nil
            }
            payloadEnd -= Int(paddingLength)
        }
        guard payloadEnd >= headerLength else {
            return nil
        }
        self.marker = (data[1] & 0x80) != 0
        self.payloadType = data[1] & 0x7f
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = data.subdata(in: headerLength..<payloadEnd)
    }
}

private struct MPEGTSInspection {
    let packetCount: Int
    let sync: Bool
    let firstPacket: MPEGTSFirstPacket?
}

private struct MPEGTSFirstPacket {
    let pid: UInt16
    let payloadUnitStart: Bool
    let adaptationFieldControl: UInt8
    let continuityCounter: UInt8
}

private struct XiaomiMirrorMPTPrivateAudioFormat: Equatable {
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let bitsPerSample: Int

    var bytesPerFrame: Int {
        Int(channels) * max(1, bitsPerSample / 8)
    }

    static let fallback = XiaomiMirrorMPTPrivateAudioFormat(
        sampleRate: 48_000,
        channels: 2,
        bitsPerSample: 16
    )
}

private struct XiaomiMirrorMPTPrivateAudioPayload {
    let kind: String
    let format: XiaomiMirrorMPTPrivateAudioFormat
    let declaredFrames: Int?
    let declaredPayloadBytes: Int
    let privatePTS90k: UInt64?
    let pcmPayload: Data
}

private final class XiaomiMirrorMPTPrivateAudioPlayer {
    var onFirstAudioRendered: (() -> Void)?
    private let sessionID: UUID
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var activeFormat = XiaomiMirrorMPTPrivateAudioFormat.fallback
    private var privateCaptureHandle: FileHandle?
    private var pcmCaptureHandle: FileHandle?
    private var privateCaptureBytes = 0
    private var pcmCaptureBytes = 0
    private var pesReceived: UInt64 = 0
    private var pcmBytesScheduled: UInt64 = 0
    private var validPCMReported = false
    private var firstRenderedReported = false
    private var unsupportedFormatLogged = false
    private var privateAudioFormatPrimed = false
    private var ff02SelfPrimeStreak = 0
    private var parseFailureCount: UInt64 = 0
    private var scheduleFailureCount: UInt64 = 0
    private var suspiciousPCMDropCount: UInt64 = 0

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    func pushPESPayload(_ payload: Data, pts90k: UInt64?) {
        pesReceived += 1
        writePrivateCapture(payload)
        guard let parsed = parsePrivatePayload(payload) else {
            parseFailureCount += 1
            if parseFailureCount <= 5 || parseFailureCount % 50 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.audio_private_parse_failed session=\(sessionID.uuidString) " +
                        "pes=\(pesReceived) bytes=\(payload.count) pts90k=\(pts90k.map(String.init) ?? "none") " +
                        "firstBytes=\(Self.hexPreview(payload, limit: 24)) failures=\(parseFailureCount)"
                )
            }
            return
        }

        if parsed.format.bitsPerSample != 16 {
            if !unsupportedFormatLogged {
                unsupportedFormatLogged = true
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.audio_private_unsupported session=\(sessionID.uuidString) " +
                        "bits=\(parsed.format.bitsPerSample) sampleRate=\(Int(parsed.format.sampleRate)) " +
                        "channels=\(parsed.format.channels)"
                )
            }
            return
        }

        let pcmPayload = parsed.pcmPayload
        let stats = pcmS16LEStats(pcmPayload)
        let needsSelfPrime = parsed.kind == "ff02" && !privateAudioFormatPrimed
        guard isPrivateAudioPayloadSafe(parsed, stats: stats, allowUnprimedFF02: needsSelfPrime) else {
            if needsSelfPrime {
                ff02SelfPrimeStreak = 0
            }
            suspiciousPCMDropCount += 1
            if suspiciousPCMDropCount <= 5 || suspiciousPCMDropCount % 50 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.audio_private_suspicious_drop session=\(sessionID.uuidString) " +
                        "pes=\(pesReceived) drops=\(suspiciousPCMDropCount) kind=\(parsed.kind) " +
                        "sampleRate=\(Int(parsed.format.sampleRate)) channels=\(parsed.format.channels) " +
                        "bits=\(parsed.format.bitsPerSample) frames=\(parsed.declaredFrames.map(String.init) ?? "none") " +
                        "declaredBytes=\(parsed.declaredPayloadBytes) pcmBytes=\(pcmPayload.count) " +
                        "nonzero=\(stats.nonzeroSamples) maxAbs=\(stats.maxAbs) avgAbs=\(stats.averageAbs) " +
                        "primed=\(privateAudioFormatPrimed) fp=\(DiagnosticsLog.fingerprint(pcmPayload))"
                )
            }
            return
        }
        if parsed.kind == "ff03" {
            privateAudioFormatPrimed = true
        }
        if needsSelfPrime {
            ff02SelfPrimeStreak += 1
            guard ff02SelfPrimeStreak >= Self.ff02SelfPrimePacketCount else {
                return
            }
            privateAudioFormatPrimed = true
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.audio_private_self_primed session=\(sessionID.uuidString) " +
                    "pes=\(pesReceived) streak=\(ff02SelfPrimeStreak) pcmBytes=\(pcmPayload.count) " +
                    "sampleRate=\(Int(parsed.format.sampleRate)) channels=\(parsed.format.channels)"
            )
        }
        activeFormat = parsed.format
        writePCMCapture(pcmPayload)
        let shouldLog = pesReceived <= 5 || pesReceived % 100 == 0 || (stats.nonzeroSamples > 0 && !validPCMReported)
        if stats.nonzeroSamples > 0 && !validPCMReported {
            validPCMReported = true
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.audio_pcm_valid session=\(sessionID.uuidString) " +
                    "pcmTotal=\(pcmBytesScheduled + UInt64(pcmPayload.count)) maxAbs=\(stats.maxAbs) " +
                    "avgAbs=\(stats.averageAbs)"
            )
        }
        if shouldLog {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.audio_private_payload session=\(sessionID.uuidString) " +
                    "pes=\(pesReceived) kind=\(parsed.kind) sampleRate=\(Int(parsed.format.sampleRate)) " +
                    "channels=\(parsed.format.channels) bits=\(parsed.format.bitsPerSample) " +
                    "frames=\(parsed.declaredFrames.map(String.init) ?? "none") " +
                    "declaredBytes=\(parsed.declaredPayloadBytes) pcmBytes=\(pcmPayload.count) " +
                    "pts90k=\(pts90k.map(String.init) ?? "none") privatePTS90k=\(parsed.privatePTS90k.map(String.init) ?? "none") " +
                    "nonzero=\(stats.nonzeroSamples) maxAbs=\(stats.maxAbs) avgAbs=\(stats.averageAbs) " +
                    "fp=\(DiagnosticsLog.fingerprint(pcmPayload))"
            )
        }
        schedulePCM(pcmPayload, format: parsed.format)
    }

    private func isPrivateAudioPayloadSafe(
        _ parsed: XiaomiMirrorMPTPrivateAudioPayload,
        stats: (samples: Int, nonzeroSamples: Int, maxAbs: Int, averageAbs: Int),
        allowUnprimedFF02: Bool = false
    ) -> Bool {
        guard parsed.format.sampleRate >= 8_000,
              parsed.format.sampleRate <= 192_000,
              parsed.format.channels >= 1,
              parsed.format.channels <= 8,
              parsed.format.bitsPerSample == 16 else {
            return false
        }
        let bytesPerFrame = parsed.format.bytesPerFrame
        guard bytesPerFrame > 0,
              parsed.pcmPayload.count <= Self.maxPrivateAudioPayloadBytes,
              parsed.pcmPayload.count % bytesPerFrame == 0 else {
            return false
        }
        if parsed.kind == "ff03",
           (parsed.declaredPayloadBytes < 0 || parsed.declaredPayloadBytes > Self.maxPrivateAudioPayloadBytes) {
            return false
        }
        if parsed.kind == "ff02", !privateAudioFormatPrimed, !allowUnprimedFF02 {
            return false
        }
        if let declaredFrames = parsed.declaredFrames, declaredFrames > 0 {
            let actualFrames = parsed.pcmPayload.count / bytesPerFrame
            let toleratedDrift = max(2, declaredFrames / 4)
            if abs(actualFrames - declaredFrames) > toleratedDrift {
                return false
            }
        }
        guard stats.samples > 0 else {
            return true
        }
        let nonzeroRatio = Double(stats.nonzeroSamples) / Double(stats.samples)
        if stats.maxAbs >= Self.suspiciousPCMMaxAbsThreshold,
           stats.averageAbs >= Self.suspiciousPCMAverageAbsThreshold,
           nonzeroRatio >= Self.suspiciousPCMNonzeroRatioThreshold {
            return false
        }
        return true
    }

    func stop(reason: String) {
        let hadAudio = audioEngine != nil || privateCaptureHandle != nil || pcmCaptureHandle != nil || pesReceived > 0
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        playerFormat = nil
        privateCaptureHandle?.closeFile()
        privateCaptureHandle = nil
        pcmCaptureHandle?.closeFile()
        pcmCaptureHandle = nil
        if hadAudio {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.audio_stop session=\(sessionID.uuidString) reason=\(reason) " +
                    "pes=\(pesReceived) pcmScheduled=\(pcmBytesScheduled) privateCaptureBytes=\(privateCaptureBytes) " +
                    "pcmCaptureBytes=\(pcmCaptureBytes) privatePath=\(Self.privateCapturePath) pcmPath=\(Self.pcmCapturePath)"
            )
        }
    }

    private func parsePrivatePayload(_ payload: Data) -> XiaomiMirrorMPTPrivateAudioPayload? {
        guard payload.count >= 18,
              payload[0] == 0xff else {
            return nil
        }
        switch payload[1] {
        case 0x03:
            guard payload.count >= 32,
                  let packedFormat = payload.readUInt16BE(at: 6),
                  let sampleRate = payload.readUInt32BE(at: 8),
                  let declaredFrames = payload.readUInt32BE(at: 12),
                  let bitsPerSample = payload.readUInt32BE(at: 16),
                  let declaredPayloadBytes = payload.readUInt32BE(at: 20) else {
                return nil
            }
            let packedChannels = AVAudioChannelCount(max(1, Int((packedFormat >> 8) & 0xff)))
            let packedBits = Int(packedFormat & 0xff)
            let format = XiaomiMirrorMPTPrivateAudioFormat(
                sampleRate: sampleRate > 0 ? Double(sampleRate) : activeFormat.sampleRate,
                channels: packedChannels > 0 ? packedChannels : activeFormat.channels,
                bitsPerSample: bitsPerSample > 0 ? Int(bitsPerSample) : (packedBits > 0 ? packedBits : activeFormat.bitsPerSample)
            )
            let pcmPayload = trimmedAudioPayload(payload, headerLength: 32, declaredPayloadBytes: Int(declaredPayloadBytes))
            return XiaomiMirrorMPTPrivateAudioPayload(
                kind: "ff03",
                format: format,
                declaredFrames: Int(declaredFrames),
                declaredPayloadBytes: Int(declaredPayloadBytes),
                privatePTS90k: payload.readUInt32BE(at: 28).map(UInt64.init),
                pcmPayload: pcmPayload
            )

        case 0x02:
            guard let rawDeclaredBytes = payload.readUInt32BE(at: 8) else {
                return nil
            }
            let declaredPayloadBytes: UInt32
            if rawDeclaredBytes > UInt32(Self.maxPrivateAudioPayloadBytes),
               let narrow = payload.readUInt16BE(at: 8),
               narrow > 0 {
                declaredPayloadBytes = UInt32(narrow)
            } else {
                declaredPayloadBytes = rawDeclaredBytes
            }
            let format = activeFormat
            let pcmPayload = trimmedAudioPayload(payload, headerLength: 18, declaredPayloadBytes: Int(declaredPayloadBytes))
            let frames = format.bytesPerFrame > 0 ? pcmPayload.count / format.bytesPerFrame : nil
            return XiaomiMirrorMPTPrivateAudioPayload(
                kind: "ff02",
                format: format,
                declaredFrames: frames,
                declaredPayloadBytes: Int(declaredPayloadBytes),
                privatePTS90k: payload.readUInt32BE(at: 14).map(UInt64.init),
                pcmPayload: pcmPayload
            )

        default:
            return nil
        }
    }

    private func trimmedAudioPayload(_ payload: Data, headerLength: Int, declaredPayloadBytes: Int) -> Data {
        guard payload.count > headerLength else {
            return Data()
        }
        let payloadEnd = min(payload.count, headerLength + max(0, declaredPayloadBytes))
        guard payloadEnd > headerLength else {
            return Data()
        }
        return payload.subdata(in: headerLength..<payloadEnd)
    }

    private func schedulePCM(_ pcmPayload: Data, format: XiaomiMirrorMPTPrivateAudioFormat) {
        guard !pcmPayload.isEmpty else {
            return
        }
        guard ensureAudioEngine(format: format),
              let playerNode,
              let playerFormat else {
            return
        }
        if !firstRenderedReported {
            firstRenderedReported = true
            onFirstAudioRendered?()
        }
        let bytesPerFrame = format.bytesPerFrame
        let frameCount = pcmPayload.count / bytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playerFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return
        }
        let byteCount = frameCount * bytesPerFrame
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let destination = buffer.int16ChannelData?[0] else {
            scheduleFailureCount += 1
            if scheduleFailureCount <= 5 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.audio_schedule_failed session=\(sessionID.uuidString) " +
                        "reason=missing_int16_channel_data failures=\(scheduleFailureCount)"
                )
            }
            return
        }
        pcmPayload.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(destination, baseAddress, byteCount)
            }
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        pcmBytesScheduled += UInt64(byteCount)
    }

    private func ensureAudioEngine(format: XiaomiMirrorMPTPrivateAudioFormat) -> Bool {
        if audioEngine != nil, playerNode != nil, playerFormat != nil, activeFormat == format {
            if playerNode?.isPlaying == false {
                playerNode?.play()
            }
            return true
        }
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        playerFormat = nil
        activeFormat = format

        guard let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: format.sampleRate,
            channels: format.channels,
            interleaved: true
        ) else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.audio_engine_unavailable session=\(sessionID.uuidString) reason=bad_format " +
                    "sampleRate=\(Int(format.sampleRate)) channels=\(format.channels) bits=\(format.bitsPerSample)"
            )
            return false
        }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: avFormat)
        do {
            try engine.start()
            node.play()
            audioEngine = engine
            playerNode = node
            playerFormat = avFormat
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.audio_engine_start session=\(sessionID.uuidString) " +
                    "sampleRate=\(Int(format.sampleRate)) channels=\(format.channels) bits=\(format.bitsPerSample)"
            )
            return true
        } catch {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.audio_engine_start_failed session=\(sessionID.uuidString) error=\(error)"
            )
            return false
        }
    }

    private func writePrivateCapture(_ payload: Data) {
        writeCapture(
            payload,
            path: Self.privateCapturePath,
            startEvent: "xiaomi.mirror.mpt.audio_private_capture_start",
            handle: &privateCaptureHandle,
            bytesWritten: &privateCaptureBytes
        )
    }

    private func writePCMCapture(_ payload: Data) {
        writeCapture(
            payload,
            path: Self.pcmCapturePath,
            startEvent: "xiaomi.mirror.mpt.audio_pcm_capture_start",
            handle: &pcmCaptureHandle,
            bytesWritten: &pcmCaptureBytes
        )
    }

    private func writeCapture(
        _ payload: Data,
        path: String,
        startEvent: String,
        handle: inout FileHandle?,
        bytesWritten: inout Int
    ) {
        guard bytesWritten < Self.captureLimitBytes, !payload.isEmpty else {
            return
        }
        if handle == nil {
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
            bytesWritten = 0
            DiagnosticsLog.info("\(startEvent) session=\(sessionID.uuidString) path=\(path) limitBytes=\(Self.captureLimitBytes)")
        }
        guard let handle else {
            return
        }
        let remaining = Self.captureLimitBytes - bytesWritten
        let chunk = payload.prefix(max(0, min(remaining, payload.count)))
        guard !chunk.isEmpty else {
            return
        }
        do {
            handle.seekToEndOfFile()
            try handle.write(contentsOf: chunk)
            bytesWritten += chunk.count
        } catch {
            DiagnosticsLog.warn("xiaomi.mirror.mpt.audio_capture_write_failed session=\(sessionID.uuidString) path=\(path) error=\(error)")
        }
    }

    private func pcmS16LEStats(_ data: Data) -> (samples: Int, nonzeroSamples: Int, maxAbs: Int, averageAbs: Int) {
        var samples = 0
        var nonzeroSamples = 0
        var maxAbs = 0
        var absTotal = 0
        var offset = 0
        while offset + 1 < data.count {
            let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            let value = Int(Int16(bitPattern: raw))
            let magnitude = abs(value)
            samples += 1
            if value != 0 {
                nonzeroSamples += 1
            }
            maxAbs = max(maxAbs, magnitude)
            absTotal += magnitude
            offset += 2
        }
        return (
            samples: samples,
            nonzeroSamples: nonzeroSamples,
            maxAbs: maxAbs,
            averageAbs: samples > 0 ? absTotal / samples : 0
        )
    }

    private static func hexPreview(_ data: Data, limit: Int) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static let privateCapturePath = "/private/tmp/edgelink-xiaomi-mirror-audio-private.bin"
    private static let pcmCapturePath = "/private/tmp/edgelink-xiaomi-mirror-audio.pcm"
    private static let captureLimitBytes = 4 * 1024 * 1024
    private static let maxPrivateAudioPayloadBytes = 64 * 1024
    private static let ff02SelfPrimePacketCount = 5
    private static let suspiciousPCMMaxAbsThreshold = 30_000
    private static let suspiciousPCMAverageAbsThreshold = 12_000
    private static let suspiciousPCMNonzeroRatioThreshold = 0.95
}

private final class XiaomiMirrorMPEGTSHEVCDemuxer {
    private let sessionID: UUID
    private let onAccessUnit: ([Data], UInt64?) -> Void
    private let onPrivateAudioPES: ((Data, UInt64?) -> Void)?
    private var pmtPID: UInt16?
    private var videoPID: UInt16?
    private var privateAudioPID: UInt16?
    private var currentPES = Data()
    private var currentPESPTS90k: UInt64?
    private var currentAudioPES = Data()
    private var currentAudioPESPTS90k: UInt64?
    private var accessUnitAssembler: XiaomiMirrorHEVCAccessUnitAssembler
    private var continuityCounters: [UInt16: UInt8] = [:]
    private var packetsParsed: UInt64 = 0
    private var pesParsed: UInt64 = 0
    private var audioPESParsed: UInt64 = 0
    private var continuityDiscontinuities: UInt64 = 0
    private var duplicateTSPackets: UInt64 = 0
    private var didLogPAT = false
    private var didLogPMT = false
    private var didLogPrivateAudioPMT = false

    init(
        sessionID: UUID,
        onAccessUnit: @escaping ([Data], UInt64?) -> Void,
        onPrivateAudioPES: ((Data, UInt64?) -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.onAccessUnit = onAccessUnit
        self.onPrivateAudioPES = onPrivateAudioPES
        self.accessUnitAssembler = XiaomiMirrorHEVCAccessUnitAssembler(sessionID: sessionID, onAccessUnit: onAccessUnit)
    }

    func pushTSPayload(_ payload: Data, rtpTimestamp: UInt32) {
        guard payload.count >= Self.packetLength, payload.count % Self.packetLength == 0 else {
            return
        }
        var offset = 0
        while offset + Self.packetLength <= payload.count {
            parseTSPacket(payload.subdata(in: offset..<(offset + Self.packetLength)), rtpTimestamp: rtpTimestamp)
            offset += Self.packetLength
        }
    }

    func flush() {
        flushCurrentPES()
        flushCurrentAudioPES()
        accessUnitAssembler.flush()
    }

    func noteTransportDiscontinuity(reason: String) {
        currentPES.removeAll(keepingCapacity: true)
        currentPESPTS90k = nil
        currentAudioPES.removeAll(keepingCapacity: true)
        currentAudioPESPTS90k = nil
        continuityCounters.removeAll(keepingCapacity: true)
        accessUnitAssembler.resetAfterLoss(reason: reason)
        DiagnosticsLog.warn(
            "xiaomi.mirror.mpt.ts_discontinuity session=\(sessionID.uuidString) " +
                "reason=\(reason) pes=\(pesParsed) audioPES=\(audioPESParsed) packets=\(packetsParsed)"
        )
    }

    private func parseTSPacket(_ packet: Data, rtpTimestamp: UInt32) {
        guard packet.count == Self.packetLength, packet[0] == Self.syncByte else {
            return
        }
        packetsParsed += 1
        let payloadUnitStart = (packet[1] & 0x40) != 0
        let pid = (UInt16(packet[1] & 0x1f) << 8) | UInt16(packet[2])
        let adaptationFieldControl = (packet[3] >> 4) & 0x03
        let continuityCounter = packet[3] & 0x0f
        guard adaptationFieldControl == 1 || adaptationFieldControl == 3 else {
            return
        }
        var payloadOffset = 4
        var discontinuityIndicator = false
        if adaptationFieldControl == 3 {
            guard payloadOffset < packet.count else {
                return
            }
            let adaptationLength = Int(packet[payloadOffset])
            if adaptationLength > 0, payloadOffset + 1 < packet.count {
                discontinuityIndicator = (packet[payloadOffset + 1] & 0x80) != 0
            }
            payloadOffset += 1 + adaptationLength
        }
        guard payloadOffset < packet.count else {
            return
        }
        let payload = packet.subdata(in: payloadOffset..<packet.count)
        if pid == 0 {
            parsePAT(payload, payloadUnitStart: payloadUnitStart)
            return
        }
        if let pmtPID, pid == pmtPID {
            parsePMT(payload, payloadUnitStart: payloadUnitStart)
            return
        }
        if let videoPID, pid == videoPID {
            guard acceptVideoContinuity(
                pid: pid,
                continuityCounter: continuityCounter,
                payloadUnitStart: payloadUnitStart,
                discontinuityIndicator: discontinuityIndicator
            ) else {
                return
            }
            parseVideoPayload(payload, payloadUnitStart: payloadUnitStart, rtpTimestamp: rtpTimestamp)
            return
        }
        if let privateAudioPID, pid == privateAudioPID {
            parsePrivateAudioPayload(payload, payloadUnitStart: payloadUnitStart, rtpTimestamp: rtpTimestamp)
        }
    }

    private func parsePAT(_ payload: Data, payloadUnitStart: Bool) {
        guard let section = sectionPayload(payload, payloadUnitStart: payloadUnitStart),
              section.count >= 12,
              section[0] == 0x00 else {
            return
        }
        guard let sectionLength = sectionLength(section), section.count >= 3 + sectionLength else {
            return
        }
        let entriesEnd = 3 + sectionLength - 4
        var offset = 8
        while offset + 4 <= entriesEnd {
            guard let programNumber = section.readUInt16BE(at: offset) else {
                return
            }
            let pid = (UInt16(section[offset + 2] & 0x1f) << 8) | UInt16(section[offset + 3])
            if programNumber != 0 {
                pmtPID = pid
                if !didLogPAT {
                    didLogPAT = true
                    DiagnosticsLog.info(
                        "xiaomi.mirror.mpt.ts_pat session=\(sessionID.uuidString) pmtPID=\(Self.hexPID(pid))"
                    )
                }
                return
            }
            offset += 4
        }
    }

    private func parsePMT(_ payload: Data, payloadUnitStart: Bool) {
        guard let section = sectionPayload(payload, payloadUnitStart: payloadUnitStart),
              section.count >= 16,
              section[0] == 0x02 else {
            return
        }
        guard let sectionLength = sectionLength(section), section.count >= 3 + sectionLength else {
            return
        }
        guard let programInfoLength = section.readUInt16BE(at: 10).map({ Int($0 & 0x0fff) }) else {
            return
        }
        var offset = 12 + programInfoLength
        let entriesEnd = 3 + sectionLength - 4
        while offset + 5 <= entriesEnd {
            let streamType = section[offset]
            let elementaryPID = (UInt16(section[offset + 1] & 0x1f) << 8) | UInt16(section[offset + 2])
            let esInfoLength = Int(((UInt16(section[offset + 3] & 0x0f) << 8) | UInt16(section[offset + 4])))
            if streamType == Self.hevcStreamType {
                if videoPID != elementaryPID {
                    continuityCounters.removeValue(forKey: videoPID ?? elementaryPID)
                }
                videoPID = elementaryPID
                if !didLogPMT {
                    didLogPMT = true
                    DiagnosticsLog.info(
                        "xiaomi.mirror.mpt.ts_pmt session=\(sessionID.uuidString) " +
                            "videoPID=\(Self.hexPID(elementaryPID)) streamType=0x24"
                    )
                }
            } else if streamType == Self.xiaomiPrivateAudioStreamType {
                if privateAudioPID != elementaryPID {
                    continuityCounters.removeValue(forKey: privateAudioPID ?? elementaryPID)
                }
                privateAudioPID = elementaryPID
                if !didLogPrivateAudioPMT {
                    didLogPrivateAudioPMT = true
                    DiagnosticsLog.info(
                        "xiaomi.mirror.mpt.ts_pmt_audio session=\(sessionID.uuidString) " +
                            "audioPID=\(Self.hexPID(elementaryPID)) streamType=0x83"
                    )
                }
            }
            offset += 5 + esInfoLength
        }
    }

    private func acceptVideoContinuity(
        pid: UInt16,
        continuityCounter: UInt8,
        payloadUnitStart: Bool,
        discontinuityIndicator: Bool
    ) -> Bool {
        if discontinuityIndicator {
            noteTransportDiscontinuity(reason: "ts_adaptation_discontinuity")
            continuityCounters[pid] = continuityCounter
            return payloadUnitStart
        }
        guard let previous = continuityCounters[pid] else {
            continuityCounters[pid] = continuityCounter
            return true
        }
        let expected = (previous + 1) & 0x0f
        if continuityCounter == expected {
            continuityCounters[pid] = continuityCounter
            return true
        }
        if continuityCounter == previous {
            duplicateTSPackets += 1
            if duplicateTSPackets <= 5 || duplicateTSPackets % 50 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.ts_duplicate_dropped session=\(sessionID.uuidString) " +
                        "pid=\(Self.hexPID(pid)) cc=\(continuityCounter) duplicates=\(duplicateTSPackets)"
                )
            }
            return false
        }
        continuityDiscontinuities += 1
        noteTransportDiscontinuity(reason: "ts_continuity_gap")
        continuityCounters[pid] = continuityCounter
        if continuityDiscontinuities <= 5 || continuityDiscontinuities % 20 == 0 {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.ts_continuity_gap session=\(sessionID.uuidString) " +
                    "pid=\(Self.hexPID(pid)) previous=\(previous) expected=\(expected) actual=\(continuityCounter) " +
                    "pusi=\(payloadUnitStart) gaps=\(continuityDiscontinuities)"
            )
        }
        return true
    }

    private func parseVideoPayload(_ payload: Data, payloadUnitStart: Bool, rtpTimestamp: UInt32) {
        if payloadUnitStart {
            flushCurrentPES()
            guard let pes = parsePESStart(payload, fallbackPTS90k: UInt64(rtpTimestamp)) else {
                return
            }
            currentPES = pes.payload
            currentPESPTS90k = pes.pts90k
        } else if !currentPES.isEmpty {
            currentPES.append(payload)
        }
    }

    private func parsePrivateAudioPayload(_ payload: Data, payloadUnitStart: Bool, rtpTimestamp: UInt32) {
        if payloadUnitStart {
            flushCurrentAudioPES()
            guard let pes = parsePESStart(payload, fallbackPTS90k: UInt64(rtpTimestamp)) else {
                return
            }
            currentAudioPES = pes.payload
            currentAudioPESPTS90k = pes.pts90k
        } else if !currentAudioPES.isEmpty {
            currentAudioPES.append(payload)
        }
    }

    private func flushCurrentPES() {
        guard !currentPES.isEmpty else {
            return
        }
        pesParsed += 1
        accessUnitAssembler.pushPESPayload(currentPES, pts90k: currentPESPTS90k)
        if pesParsed <= 5 || pesParsed % 100 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.ts_pes session=\(sessionID.uuidString) pes=\(pesParsed) " +
                    "bytes=\(currentPES.count) pts90k=\(currentPESPTS90k.map(String.init) ?? "none")"
            )
        }
        currentPES.removeAll(keepingCapacity: true)
        currentPESPTS90k = nil
    }

    private func flushCurrentAudioPES() {
        guard !currentAudioPES.isEmpty else {
            return
        }
        audioPESParsed += 1
        onPrivateAudioPES?(currentAudioPES, currentAudioPESPTS90k)
        if audioPESParsed <= 5 || audioPESParsed % 100 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.ts_audio_pes session=\(sessionID.uuidString) pes=\(audioPESParsed) " +
                    "bytes=\(currentAudioPES.count) pts90k=\(currentAudioPESPTS90k.map(String.init) ?? "none") " +
                    "firstBytes=\(Self.hexPreview(currentAudioPES, limit: 16))"
            )
        }
        currentAudioPES.removeAll(keepingCapacity: true)
        currentAudioPESPTS90k = nil
    }

    private func parsePESStart(_ payload: Data, fallbackPTS90k: UInt64?) -> (payload: Data, pts90k: UInt64?)? {
        guard payload.count >= 9,
              payload[0] == 0x00,
              payload[1] == 0x00,
              payload[2] == 0x01 else {
            return nil
        }
        let ptsDTSFlags = (payload[7] >> 6) & 0x03
        let headerLength = Int(payload[8])
        let payloadOffset = 9 + headerLength
        guard payloadOffset <= payload.count else {
            return nil
        }
        let pts90k = ptsDTSFlags == 0x02 || ptsDTSFlags == 0x03
            ? parsePTS(payload, offset: 9)
            : fallbackPTS90k
        return (payload.subdata(in: payloadOffset..<payload.count), pts90k)
    }

    private func parsePTS(_ data: Data, offset: Int) -> UInt64? {
        guard offset + 4 < data.count else {
            return nil
        }
        let p0 = UInt64((data[offset] >> 1) & 0x07) << 30
        let p1 = UInt64(data[offset + 1]) << 22
        let p2 = UInt64((data[offset + 2] >> 1) & 0x7f) << 15
        let p3 = UInt64(data[offset + 3]) << 7
        let p4 = UInt64((data[offset + 4] >> 1) & 0x7f)
        return p0 | p1 | p2 | p3 | p4
    }

    private func sectionPayload(_ payload: Data, payloadUnitStart: Bool) -> Data? {
        if payloadUnitStart {
            guard let pointer = payload.first, Int(pointer) + 1 < payload.count else {
                return nil
            }
            return payload.subdata(in: (1 + Int(pointer))..<payload.count)
        }
        return payload
    }

    private func sectionLength(_ section: Data) -> Int? {
        guard section.count >= 3 else {
            return nil
        }
        return Int(((UInt16(section[1] & 0x0f) << 8) | UInt16(section[2])))
    }

    private static func hexPID(_ value: UInt16) -> String {
        String(format: "0x%04x", value)
    }

    private static func hexPreview(_ data: Data, limit: Int) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static let packetLength = 188
    private static let syncByte: UInt8 = 0x47
    private static let hevcStreamType: UInt8 = 0x24
    private static let xiaomiPrivateAudioStreamType: UInt8 = 0x83
}

private final class XiaomiMirrorHEVCAccessUnitAssembler {
    private let sessionID: UUID
    private let onAccessUnit: ([Data], UInt64?) -> Void
    private var pendingNALUnits: [Data] = []
    private var pendingHasVCL = false
    private var pendingHasRandomAccess = false
    private var pendingPTS90k: UInt64?
    private var accessUnits = 0
    private var waitingForRandomAccess = false
    private var droppedUntilRandomAccess: UInt64 = 0

    init(sessionID: UUID, onAccessUnit: @escaping ([Data], UInt64?) -> Void) {
        self.sessionID = sessionID
        self.onAccessUnit = onAccessUnit
    }

    func pushPESPayload(_ payload: Data, pts90k: UInt64?) {
        for nalUnit in Self.annexBNALUnits(in: payload) {
            pushNALUnit(nalUnit, pts90k: pts90k)
        }
    }

    func flush() {
        flushPending()
    }

    func resetAfterLoss(reason: String) {
        clearPending()
        waitingForRandomAccess = true
        DiagnosticsLog.warn(
            "xiaomi.mirror.mpt.hevc_au_wait_random_access session=\(sessionID.uuidString) reason=\(reason)"
        )
    }

    private func pushNALUnit(_ nalUnit: Data, pts90k: UInt64?) {
        guard nalUnit.count >= 2 else {
            return
        }
        let nalType = Self.nalType(nalUnit)
        let vcl = Self.isVCLNALType(nalType)
        let firstSlice = vcl && nalUnit.count > 2 && (nalUnit[2] & 0x80) != 0
        if firstSlice && pendingHasVCL {
            flushPending()
        }
        if pendingNALUnits.isEmpty {
            pendingPTS90k = pts90k
        }
        pendingNALUnits.append(nalUnit)
        if vcl {
            pendingHasVCL = true
        }
        if Self.isRandomAccessNALType(nalType) {
            pendingHasRandomAccess = true
        }
    }

    private func flushPending() {
        guard pendingHasVCL, !pendingNALUnits.isEmpty else {
            clearPending()
            return
        }
        if waitingForRandomAccess && !pendingHasRandomAccess {
            droppedUntilRandomAccess += 1
            if droppedUntilRandomAccess <= 5 || droppedUntilRandomAccess % 30 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.hevc_au_dropped_until_random_access session=\(sessionID.uuidString) " +
                        "dropped=\(droppedUntilRandomAccess) nals=\(pendingNALUnits.count) " +
                        "pts90k=\(pendingPTS90k.map(String.init) ?? "none")"
                )
            }
            clearPending()
            return
        }
        if waitingForRandomAccess {
            waitingForRandomAccess = false
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.hevc_au_random_access_resynced session=\(sessionID.uuidString) " +
                    "dropped=\(droppedUntilRandomAccess)"
            )
        }
        accessUnits += 1
        if accessUnits <= 5 || accessUnits % 60 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.hevc_access_unit session=\(sessionID.uuidString) " +
                    "au=\(accessUnits) nals=\(pendingNALUnits.count) " +
                    "randomAccess=\(pendingHasRandomAccess) " +
                    "types=\(Self.nalTypesSummary(pendingNALUnits)) " +
                    "pts90k=\(pendingPTS90k.map(String.init) ?? "none")"
            )
        }
        onAccessUnit(pendingNALUnits, pendingPTS90k)
        clearPending()
    }

    private func clearPending() {
        pendingNALUnits.removeAll(keepingCapacity: true)
        pendingPTS90k = nil
        pendingHasVCL = false
        pendingHasRandomAccess = false
    }

    private static func annexBNALUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(startCode: Int, nalStart: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, index + 3))
                    index += 3
                    continue
                }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, index + 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }
        guard !starts.isEmpty else {
            return []
        }
        var result: [Data] = []
        for startIndex in starts.indices {
            let nalStart = starts[startIndex].nalStart
            let nalEnd = startIndex + 1 < starts.count ? starts[startIndex + 1].startCode : bytes.count
            if nalEnd > nalStart {
                result.append(Data(bytes[nalStart..<nalEnd]))
            }
        }
        return result
    }

    fileprivate static func nalType(_ nalUnit: Data) -> UInt8 {
        guard let first = nalUnit.first else {
            return 0xff
        }
        return (first & 0x7e) >> 1
    }

    private static func nalTypesSummary(_ accessUnit: [Data]) -> String {
        "[" + accessUnit.map { String(nalType($0)) }.joined(separator: ",") + "]"
    }

    fileprivate static func isVCLNALType(_ nalType: UInt8) -> Bool {
        nalType <= 31
    }

    fileprivate static func isRandomAccessNALType(_ nalType: UInt8) -> Bool {
        (16...21).contains(nalType)
    }
}

private final class XiaomiMirrorHEVCDecoder {
    var onFrame: ((CVPixelBuffer, Int, Int) -> Void)?
    var onDecodeFailed: (() -> Void)?
    var onParameterSetsChanged: ((XiaomiMirrorHEVCParameterSets) -> Void)?

    private let sessionID: UUID
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var decodedFrames: UInt64 = 0
    private var decodeRequests: UInt64 = 0
    private var droppedUntilFormat: UInt64 = 0
    private var needsRandomAccess = false
    private var droppedUntilRandomAccess: UInt64 = 0
    private var resetOnNextRandomAccessReason: String?

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    func primeParameterSets(_ parameterSets: XiaomiMirrorHEVCParameterSets, reason: String) {
        let changed = vps != parameterSets.vps || sps != parameterSets.sps || pps != parameterSets.pps
        vps = parameterSets.vps
        sps = parameterSets.sps
        pps = parameterSets.pps
        droppedUntilFormat = 0
        if changed {
            invalidate()
        }
        DiagnosticsLog.info(
            "xiaomi.mirror.mpt.hevc_parameter_sets_primed session=\(sessionID.uuidString) " +
                "reason=\(reason) vps=\(parameterSets.vps.count) sps=\(parameterSets.sps.count) " +
                "pps=\(parameterSets.pps.count) changed=\(changed)"
        )
    }

    func requireRandomAccess(reason: String) {
        needsRandomAccess = true
        resetOnNextRandomAccessReason = nil
        invalidate()
        DiagnosticsLog.warn(
            "xiaomi.mirror.mpt.hevc_decoder_wait_random_access session=\(sessionID.uuidString) reason=\(reason)"
        )
    }

    func resetOnNextRandomAccess(reason: String) {
        if resetOnNextRandomAccessReason == nil {
            resetOnNextRandomAccessReason = reason
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.hevc_decoder_reset_deferred session=\(sessionID.uuidString) reason=\(reason)"
            )
        }
    }

    func decode(accessUnit: [Data], pts90k: UInt64?) {
        guard !accessUnit.isEmpty else {
            return
        }
        updateParameterSets(from: accessUnit)
        guard accessUnit.contains(where: { XiaomiMirrorHEVCAccessUnitAssembler.isVCLNALType(Self.nalType($0)) }) else {
            return
        }
        let hasRandomAccess = accessUnit.contains {
            XiaomiMirrorHEVCAccessUnitAssembler.isRandomAccessNALType(Self.nalType($0))
        }
        if let resetReason = resetOnNextRandomAccessReason, hasRandomAccess {
            resetOnNextRandomAccessReason = nil
            needsRandomAccess = false
            droppedUntilRandomAccess = 0
            invalidate()
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.hevc_decoder_reset_on_random_access session=\(sessionID.uuidString) " +
                    "reason=\(resetReason) nals=\(Self.nalTypesSummary(accessUnit)) " +
                    "pts90k=\(pts90k.map(String.init) ?? "none")"
            )
        }
        if needsRandomAccess && !hasRandomAccess {
            droppedUntilRandomAccess += 1
            if droppedUntilRandomAccess <= 5 || droppedUntilRandomAccess % 30 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.hevc_decode_dropped_until_random_access session=\(sessionID.uuidString) " +
                        "dropped=\(droppedUntilRandomAccess) nals=\(accessUnit.count) " +
                        "pts90k=\(pts90k.map(String.init) ?? "none")"
                )
            }
            return
        }
        if needsRandomAccess {
            needsRandomAccess = false
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.hevc_decode_random_access_resynced session=\(sessionID.uuidString) " +
                    "dropped=\(droppedUntilRandomAccess)"
            )
        }
        guard ensureSession() else {
            droppedUntilFormat += 1
            if droppedUntilFormat <= 5 || droppedUntilFormat % 30 == 0 {
                DiagnosticsLog.warn(
                    "xiaomi.mirror.mpt.hevc_decode_wait_format session=\(sessionID.uuidString) " +
                        "dropped=\(droppedUntilFormat) hasVPS=\(vps != nil) hasSPS=\(sps != nil) hasPPS=\(pps != nil)"
                )
            }
            return
        }
        guard let formatDescription,
              let sampleBuffer = makeSampleBuffer(
                accessUnit: accessUnit,
                formatDescription: formatDescription,
                pts90k: pts90k,
                isRandomAccess: hasRandomAccess
              ) else {
            onDecodeFailed?()
            return
        }
        decodeRequests += 1
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession!,
            sampleBuffer: sampleBuffer,
            flags: Self.asynchronousDecodeFrameFlags,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if status != noErr {
            onDecodeFailed?()
            requireRandomAccess(reason: "decode_failed_status_\(status)")
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.hevc_decode_failed session=\(sessionID.uuidString) " +
                    "status=\(status) requests=\(decodeRequests) nals=\(accessUnit.count)"
            )
        } else if decodeRequests <= 5 || decodeRequests % 60 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.hevc_decode_submitted session=\(sessionID.uuidString) " +
                    "requests=\(decodeRequests) nals=\(accessUnit.count) randomAccess=\(hasRandomAccess) " +
                    "pts90k=\(pts90k.map(String.init) ?? "none")"
            )
        }
    }

    func invalidate() {
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        formatDescription = nil
    }

    private func updateParameterSets(from accessUnit: [Data]) {
        var changed = false
        for nalUnit in accessUnit {
            switch Self.nalType(nalUnit) {
            case 32:
                changed = replaceIfChanged(&vps, nalUnit)
            case 33:
                changed = replaceIfChanged(&sps, nalUnit) || changed
            case 34:
                changed = replaceIfChanged(&pps, nalUnit) || changed
            default:
                break
            }
        }
        if changed {
            invalidate()
            if let vps, let sps, let pps {
                let parameterSets = XiaomiMirrorHEVCParameterSets(vps: vps, sps: sps, pps: pps)
                onParameterSetsChanged?(parameterSets)
                DiagnosticsLog.info(
                    "xiaomi.mirror.mpt.hevc_parameter_sets_updated session=\(sessionID.uuidString) " +
                        "vps=\(vps.count) sps=\(sps.count) pps=\(pps.count)"
                )
            }
        }
    }

    private func replaceIfChanged(_ target: inout Data?, _ value: Data) -> Bool {
        guard target != value else {
            return false
        }
        target = value
        return true
    }

    private func ensureSession() -> Bool {
        if decompressionSession != nil {
            return true
        }
        guard let vps, let sps, let pps else {
            return false
        }
        guard let description = makeFormatDescription(vps: vps, sps: sps, pps: pps) else {
            return false
        }
        formatDescription = description
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.hevc_decoder_create_failed session=\(sessionID.uuidString) status=\(status)"
            )
            return false
        }
        decompressionSession = session
        DiagnosticsLog.info(
            "xiaomi.mirror.mpt.hevc_decoder_ready session=\(sessionID.uuidString) " +
                "vps=\(vps.count) sps=\(sps.count) pps=\(pps.count)"
        )
        return true
    }

    private func makeFormatDescription(vps: Data, sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        vps.withUnsafeBytes { vpsRaw in
            sps.withUnsafeBytes { spsRaw in
                pps.withUnsafeBytes { ppsRaw in
                    guard let vpsBase = vpsRaw.bindMemory(to: UInt8.self).baseAddress,
                          let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                          let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }
                    var parameterSetPointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                    var parameterSetSizes = [vps.count, sps.count, pps.count]
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSetPointers.count,
                        parameterSetPointers: &parameterSetPointers,
                        parameterSetSizes: &parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                    if status != noErr {
                        DiagnosticsLog.warn(
                            "xiaomi.mirror.mpt.hevc_format_create_failed session=\(sessionID.uuidString) status=\(status)"
                        )
                    }
                }
            }
        }
        return description
    }

    private func makeSampleBuffer(
        accessUnit: [Data],
        formatDescription: CMVideoFormatDescription,
        pts90k: UInt64?,
        isRandomAccess: Bool
    ) -> CMSampleBuffer? {
        let sampleNALUnits = accessUnit.filter { !Self.isParameterSetNALType(Self.nalType($0)) }
        guard !sampleNALUnits.isEmpty else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.hevc_sample_skipped_no_payload session=\(sessionID.uuidString) " +
                    "types=\(Self.nalTypesSummary(accessUnit)) pts90k=\(pts90k.map(String.init) ?? "none")"
            )
            return nil
        }
        if sampleNALUnits.count != accessUnit.count,
           decodeRequests <= 5 || decodeRequests % 60 == 59 || isRandomAccess {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.hevc_sample_parameter_sets_stripped session=\(sessionID.uuidString) " +
                    "sourceTypes=\(Self.nalTypesSummary(accessUnit)) " +
                    "sampleTypes=\(Self.nalTypesSummary(sampleNALUnits)) " +
                    "pts90k=\(pts90k.map(String.init) ?? "none")"
            )
        }
        var sampleData = Data()
        for nalUnit in sampleNALUnits {
            sampleData.appendUInt32BE(UInt32(nalUnit.count))
            sampleData.append(nalUnit)
        }
        guard !sampleData.isEmpty else {
            return nil
        }
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }
        let replaceStatus = sampleData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return OSStatus(kCMBlockBufferBadPointerParameterErr)
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts90k.map { CMTime(value: CMTimeValue($0), timescale: 90_000) } ?? .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.hevc_sample_create_failed session=\(sessionID.uuidString) status=\(sampleStatus)"
            )
            return nil
        }
        applySampleAttachments(sampleBuffer, isRandomAccess: isRandomAccess)
        return sampleBuffer
    }

    private func applySampleAttachments(_ sampleBuffer: CMSampleBuffer, isRandomAccess: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else {
            return
        }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let dependencyValue: CFBoolean = isRandomAccess ? kCFBooleanFalse! : kCFBooleanTrue!
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(dependencyValue).toOpaque()
        )
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
            Unmanaged.passUnretained(dependencyValue).toOpaque()
        )
    }

    private func handleDecoded(pixelBuffer: CVPixelBuffer) {
        decodedFrames += 1
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if decodedFrames <= 5 || decodedFrames % 60 == 0 {
            DiagnosticsLog.info(
                "xiaomi.mirror.mpt.hevc_decoder_output session=\(sessionID.uuidString) " +
                    "frames=\(decodedFrames) size=\(width)x\(height)"
            )
        }
        onFrame?(pixelBuffer, width, height)
    }

    private static func nalType(_ nalUnit: Data) -> UInt8 {
        XiaomiMirrorHEVCAccessUnitAssembler.nalType(nalUnit)
    }

    private static func nalTypesSummary(_ accessUnit: [Data]) -> String {
        "[" + accessUnit.map { String(nalType($0)) }.joined(separator: ",") + "]"
    }

    private static func isParameterSetNALType(_ nalType: UInt8) -> Bool {
        switch nalType {
        case 32, 33, 34:
            return true
        default:
            return false
        }
    }

    private static let asynchronousDecodeFrameFlags = VTDecodeFrameFlags(rawValue: 1 << 0)

    private static let outputCallback: VTDecompressionOutputCallback = { refCon, _, status, _, imageBuffer, _, _ in
        guard let refCon else {
            return
        }
        let decoder = Unmanaged<XiaomiMirrorHEVCDecoder>.fromOpaque(refCon).takeUnretainedValue()
        guard status == noErr, let imageBuffer else {
            decoder.onDecodeFailed?()
            decoder.requireRandomAccess(reason: "decoder_output_status_\(status)")
            DiagnosticsLog.warn(
                "xiaomi.mirror.mpt.hevc_decoder_output_failed session=\(decoder.sessionID.uuidString) status=\(status)"
            )
            return
        }
        decoder.handleDecoded(pixelBuffer: imageBuffer)
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

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    func readUInt16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < count else {
            return nil
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < count else {
            return nil
        }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }

    func readUInt16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < count else {
            return nil
        }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < count else {
            return nil
        }
        return (UInt32(self[offset]) << 24) |
            (UInt32(self[offset + 1]) << 16) |
            (UInt32(self[offset + 2]) << 8) |
            UInt32(self[offset + 3])
    }

    mutating func appendUInt32BE(_ value: UInt32) {
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

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private enum XiaomiMirrorRTSPDiagnosticSourceError: Error {
    case invalidHost(String)
    case invalidPort(UInt16)
    case pixelBufferCreateFailed(CVReturn)
    case videoToolboxCreateFailed(OSStatus)
    case videoToolboxEncodeFailed(OSStatus)
    case videoToolboxSessionMissing
}
