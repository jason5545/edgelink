import EdgeLinkKit
import Foundation
import WebRTC

final class MacMirrorTurnSession: NSObject, @unchecked Sendable {
    static let dataChannelLabel = "edgelink-mirror-media"
    static let openTimeoutSeconds: TimeInterval = 8
    static let statsIntervalSeconds: TimeInterval = 5

    enum State: String {
        case idle
        case starting
        case waitingDataChannel
        case active
        case failed
        case closed
    }

    private(set) var sessionId = ""
    private(set) var state: State = .idle

    var onDatagram: ((Data, String) -> Void)?
    var onOpenTimeout: ((String) -> Void)?
    var onFailed: ((String, String) -> Void)?

    private let queue = DispatchQueue(label: "EdgeLink.MacMirrorTurnSession", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private let encoder = JSONEncoder()
    private var sendPlaintext: ((Data) -> Void)?
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var didInitializeSSL = false
    private var startedAt: Date?
    private var openTimeoutWorkItem: DispatchWorkItem?
    private var iceDisconnectedWorkItem: DispatchWorkItem?
    private var statsTimer: DispatchSourceTimer?
    private var datagramsSent: UInt64 = 0
    private var datagramsReceived: UInt64 = 0

    override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        openTimeoutWorkItem?.cancel()
        statsTimer?.cancel()
    }

    var isActive: Bool {
        performOnQueue { state == .active }
    }

    func isActive(for sessionId: String) -> Bool {
        performOnQueue { self.sessionId == sessionId && state == .active }
    }

    func start(
        sessionId: String,
        iceServers: [ScreenIceServerConfig],
        sendPlaintext: @escaping (Data) -> Void
    ) {
        queue.async {
            self.stopOnQueue(reason: "replace", notify: false)
            self.sessionId = sessionId
            self.state = .starting
            self.sendPlaintext = sendPlaintext
            self.startedAt = Date()
            self.datagramsSent = 0
            self.datagramsReceived = 0

            let turnUrls = iceServers.compactMap { config -> ScreenIceServerConfig? in
                let udpUrls = config.urls.filter { $0.contains("transport=udp") }
                guard !udpUrls.isEmpty else {
                    return nil
                }
                return ScreenIceServerConfig(urls: udpUrls, username: config.username, credential: config.credential)
            }
            guard !turnUrls.isEmpty else {
                self.failOnQueue(reason: "no_udp_turn_urls")
                return
            }
            DiagnosticsLog.info(
                "mirror.turn.start sessionId=\(sessionId) servers=\(turnUrls.count) " +
                    "urls=\(turnUrls.flatMap(\.urls).joined(separator: ","))"
            )

            if !self.didInitializeSSL {
                RTCInitializeSSL()
                self.didInitializeSSL = true
            }
            let factory = RTCPeerConnectionFactory()
            self.factory = factory

            let config = RTCConfiguration()
            config.iceServers = turnUrls.map { server in
                if let username = server.username, let credential = server.credential {
                    return RTCIceServer(urlStrings: server.urls, username: username, credential: credential)
                }
                return RTCIceServer(urlStrings: server.urls)
            }
            config.sdpSemantics = .unifiedPlan
            config.iceTransportPolicy = .all

            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let peerConnection = factory.peerConnection(
                with: config,
                constraints: constraints,
                delegate: self
            ) else {
                self.failOnQueue(reason: "peer_connection_create_failed")
                return
            }
            self.peerConnection = peerConnection

            let channelConfig = RTCDataChannelConfiguration()
            // UDP semantics for the KCP tunnel: 5 Mbps video + PCM audio was
            // verified to flow loss-free over this channel at the paced rate;
            // KCP retransmits the rare drop end to end. A reliable channel
            // instead buffered retransmits, inflated RTT to 250ms, and
            // starved the stream (live 2026-08-09).
            channelConfig.isOrdered = false
            channelConfig.maxRetransmits = 0
            guard let dataChannel = peerConnection.dataChannel(
                forLabel: Self.dataChannelLabel,
                configuration: channelConfig
            ) else {
                self.failOnQueue(reason: "data_channel_create_failed")
                return
            }
            dataChannel.delegate = self
            self.dataChannel = dataChannel

            peerConnection.offer(for: constraints) { [weak self, weak peerConnection] offer, error in
                self?.queue.async {
                    guard let self, let peerConnection, self.peerConnection === peerConnection else {
                        return
                    }
                    guard self.state == .starting else {
                        return
                    }
                    if let error {
                        self.failOnQueue(reason: "offer_create_failed:\(error.localizedDescription)")
                        return
                    }
                    guard let offer else {
                        self.failOnQueue(reason: "offer_create_empty")
                        return
                    }
                    peerConnection.setLocalDescription(offer) { [weak self, weak peerConnection] error in
                        self?.queue.async {
                            guard let self, let peerConnection, self.peerConnection === peerConnection else {
                                return
                            }
                            guard self.state == .starting else {
                                return
                            }
                            if let error {
                                self.failOnQueue(reason: "set_local_offer_failed:\(error.localizedDescription)")
                                return
                            }
                            self.state = .waitingDataChannel
                            self.sendEnvelope(
                                type: EnvelopeType.miLinkMirrorRtcOffer,
                                body: MiLinkMirrorRtcOfferBody(sessionId: self.sessionId, sdp: offer.sdp)
                            )
                            DiagnosticsLog.info(
                                "mirror.turn.offer_out sessionId=\(self.sessionId) bytes=\(offer.sdp.count)"
                            )
                            self.scheduleOpenTimeoutOnQueue()
                            self.startStatsLoggingOnQueue(on: peerConnection)
                        }
                    }
                }
            }
        }
    }

    func handleAnswer(_ body: MiLinkMirrorRtcAnswerBody) {
        queue.async {
            guard body.sessionId == self.sessionId, let peerConnection = self.peerConnection else {
                DiagnosticsLog.info(
                    "mirror.turn.answer_ignored sessionId=\(body.sessionId) active=\(self.sessionId)"
                )
                return
            }
            DiagnosticsLog.info("mirror.turn.answer_in sessionId=\(self.sessionId) bytes=\(body.sdp.count)")
            let description = RTCSessionDescription(type: .answer, sdp: body.sdp)
            peerConnection.setRemoteDescription(description) { [weak self] error in
                self?.queue.async {
                    if let error {
                        self?.failOnQueue(reason: "set_remote_answer_failed:\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func handleIce(_ body: MiLinkMirrorRtcIceBody) {
        queue.async {
            guard body.sessionId == self.sessionId, let peerConnection = self.peerConnection else {
                return
            }
            let candidate = RTCIceCandidate(
                sdp: body.candidate,
                sdpMLineIndex: Int32(body.index),
                sdpMid: body.mid
            )
            peerConnection.add(candidate) { error in
                if let error {
                    DiagnosticsLog.warn(
                        "mirror.turn.ice_add_failed sessionId=\(body.sessionId) error=\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func send(_ datagram: Data) {
        queue.async {
            guard self.state == .active, let channel = self.dataChannel,
                  channel.readyState == .open else {
                return
            }
            channel.sendData(RTCDataBuffer(data: datagram, isBinary: true))
            self.datagramsSent += 1
            if self.datagramsSent == 1 || self.datagramsSent % 100 == 0 {
                DiagnosticsLog.info(
                    "mirror.turn.ack_out sessionId=\(self.sessionId) datagrams=\(self.datagramsSent) bytes=\(datagram.count)"
                )
            }
        }
    }

    func stop(reason: String) {
        queue.async {
            self.stopOnQueue(reason: reason, notify: false)
        }
    }

    private func performOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return work()
        }
        return queue.sync(execute: work)
    }

    private func scheduleOpenTimeoutOnQueue() {
        openTimeoutWorkItem?.cancel()
        let sessionId = self.sessionId
        let workItem = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard let self, self.sessionId == sessionId, self.state == .waitingDataChannel else {
                    return
                }
                let elapsedMs = Int(Date().timeIntervalSince(self.startedAt ?? Date()) * 1_000)
                DiagnosticsLog.warn(
                    "mirror.turn.dc_failed sessionId=\(sessionId) reason=open_timeout elapsedMs=\(elapsedMs)"
                )
                self.state = .failed
                let onOpenTimeout = self.onOpenTimeout
                self.teardownPeerConnectionOnQueue()
                DispatchQueue.main.async {
                    onOpenTimeout?(sessionId)
                }
            }
        }
        openTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.openTimeoutSeconds, execute: workItem)
    }

    private func startStatsLoggingOnQueue(on peerConnection: RTCPeerConnection) {
        statsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.statsIntervalSeconds,
            repeating: Self.statsIntervalSeconds
        )
        timer.setEventHandler { [weak self, weak peerConnection] in
            guard let self, let peerConnection, self.peerConnection === peerConnection else {
                return
            }
            peerConnection.statistics { [weak self] report in
                self?.queue.async {
                    self?.logStats(report)
                }
            }
        }
        statsTimer = timer
        timer.resume()
    }

    private func logStats(_ report: RTCStatisticsReport) {
        guard state == .active || state == .waitingDataChannel else {
            return
        }
        let statsById = report.statistics.reduce(into: [String: NSObject]()) { partial, item in
            partial[item.key] = item.value
        }
        guard let pair = statsById.values.first(where: { stat in
            stat.turnStatType == "candidate-pair" &&
                stat.turnStatValues.turnString("state") == "succeeded" &&
                (stat.turnStatValues.turnBool("nominated") == true || stat.turnStatValues.turnBool("selected") == true)
        }) else {
            return
        }
        let values = pair.turnStatValues
        let localType = values.turnString("localCandidateId").flatMap { statsById[$0]?.turnStatValues.turnString("candidateType") }
        let remoteType = values.turnString("remoteCandidateId").flatMap { statsById[$0]?.turnStatValues.turnString("candidateType") }
        let rttMs = values.turnDouble("currentRoundTripTime").map { $0 * 1_000.0 }
        let bitrate = values.turnDouble("availableOutgoingBitrate") ?? values.turnDouble("availableIncomingBitrate")
        DiagnosticsLog.info(
            "mirror.turn.stats sessionId=\(sessionId) state=\(state.rawValue) " +
                "rttMs=\(formatTurn1(rttMs)) abwKbps=\(formatTurnKbps(bitrate)) " +
                "path=\(localType ?? "-")>\(remoteType ?? "-") " +
                "dcIn=\(datagramsReceived) dcOut=\(datagramsSent)"
        )
    }

    private func sendEnvelope<Body: Codable & Sendable>(type: String, body: Body) {
        guard let data = try? encoder.encode(Envelope(t: type, b: body)) else {
            return
        }
        sendPlaintext?(data)
    }

    private func failOnQueue(reason: String) {
        let sessionId = self.sessionId
        DiagnosticsLog.warn("mirror.turn.dc_failed sessionId=\(sessionId) reason=\(reason)")
        state = .failed
        let onFailed = self.onFailed
        teardownPeerConnectionOnQueue()
        DispatchQueue.main.async {
            onFailed?(sessionId, reason)
        }
    }

    private func stopOnQueue(reason: String, notify: Bool) {
        guard state != .idle else {
            return
        }
        DiagnosticsLog.info("mirror.turn.stop sessionId=\(sessionId) reason=\(reason) state=\(state.rawValue)")
        state = .closed
        teardownPeerConnectionOnQueue()
        sendPlaintext = nil
    }

    private func teardownPeerConnectionOnQueue() {
        openTimeoutWorkItem?.cancel()
        openTimeoutWorkItem = nil
        iceDisconnectedWorkItem?.cancel()
        iceDisconnectedWorkItem = nil
        statsTimer?.cancel()
        statsTimer = nil
        if let channel = dataChannel {
            channel.delegate = nil
            channel.close()
            dataChannel = nil
        }
        if let peerConnection {
            peerConnection.delegate = nil
            peerConnection.close()
            self.peerConnection = nil
        }
        factory = nil
    }
}

extension MacMirrorTurnSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        queue.async {
            guard self.peerConnection === peerConnection else {
                return
            }
            DiagnosticsLog.info(
                "mirror.turn.ice_state sessionId=\(self.sessionId) state=\(Self.describe(newState))"
            )
            switch newState {
            case .failed:
                self.failOnQueue(reason: "ice_failed")
            case .disconnected:
                if self.state == .waitingDataChannel {
                    DiagnosticsLog.info("mirror.turn.ice_disconnected sessionId=\(self.sessionId)")
                } else if self.state == .active {
                    // Frequently transient (Wi-Fi jitter); only fail over to
                    // the WebSocket leg when it persists.
                    guard self.iceDisconnectedWorkItem == nil else {
                        break
                    }
                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self else {
                            return
                        }
                        self.iceDisconnectedWorkItem = nil
                        DiagnosticsLog.warn("mirror.turn.ice_disconnected_sustained sessionId=\(self.sessionId)")
                        self.failOnQueue(reason: "ice_disconnected_sustained")
                    }
                    self.iceDisconnectedWorkItem = workItem
                    self.queue.asyncAfter(deadline: .now() + 4, execute: workItem)
                }
            case .connected, .completed:
                self.iceDisconnectedWorkItem?.cancel()
                self.iceDisconnectedWorkItem = nil
            case .closed:
                if self.state != .closed && self.state != .idle {
                    self.failOnQueue(reason: "ice_closed")
                }
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        queue.async {
            guard self.peerConnection === peerConnection else {
                return
            }
            self.sendEnvelope(
                type: EnvelopeType.miLinkMirrorRtcIce,
                body: MiLinkMirrorRtcIceBody(
                    sessionId: self.sessionId,
                    mid: candidate.sdpMid ?? "",
                    index: Int(candidate.sdpMLineIndex),
                    candidate: candidate.sdp
                )
            )
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    private static func describe(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown"
        }
    }
}

extension MacMirrorTurnSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        queue.async {
            guard self.dataChannel === dataChannel else {
                return
            }
            if dataChannel.readyState == .open, self.state == .waitingDataChannel {
                self.state = .active
                self.openTimeoutWorkItem?.cancel()
                self.openTimeoutWorkItem = nil
                let elapsedMs = Int(Date().timeIntervalSince(self.startedAt ?? Date()) * 1_000)
                DiagnosticsLog.info(
                    "mirror.turn.dc_open sessionId=\(self.sessionId) elapsedMs=\(elapsedMs)"
                )
            } else if dataChannel.readyState == .closed || dataChannel.readyState == .closing {
                if self.state == .active {
                    DiagnosticsLog.warn("mirror.turn.dc_closed sessionId=\(self.sessionId)")
                    self.failOnQueue(reason: "dc_closed")
                }
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        queue.async {
            guard self.dataChannel === dataChannel else {
                return
            }
            self.datagramsReceived += 1
            self.onDatagram?(data, self.sessionId)
        }
    }
}

private extension NSObject {
    var turnStatType: String {
        value(forKey: "type") as? String ?? ""
    }

    var turnStatValues: [String: NSObject] {
        value(forKey: "values") as? [String: NSObject] ?? [:]
    }
}

private extension Dictionary where Key == String, Value == NSObject {
    func turnString(_ key: String) -> String? {
        self[key] as? String ?? self[key]?.description
    }

    func turnDouble(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber {
            return number.doubleValue
        }
        if let string = self[key] as? String {
            return Double(string)
        }
        return nil
    }

    func turnBool(_ key: String) -> Bool? {
        if let number = self[key] as? NSNumber {
            return number.boolValue
        }
        if let string = self[key] as? String {
            return Bool(string)
        }
        return nil
    }
}

private func formatTurn1(_ value: Double?) -> String {
    guard let value else {
        return "-"
    }
    return String(format: "%.1f", value)
}

private func formatTurnKbps(_ value: Double?) -> String {
    guard let value else {
        return "-"
    }
    return String(format: "%.0f", value / 1_000.0)
}
