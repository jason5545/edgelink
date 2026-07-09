import AppKit
import CoreImage
import EdgeLinkKit
import SwiftUI
import WebRTC

final class MacScreenSession: NSObject, ObservableObject {
    @Published private(set) var status = "Idle"
    @Published private(set) var screenMeta: ScreenMetaBody?
    @Published private(set) var hasRemoteVideo = false

    let videoView = PhoneVideoRendererView()

    private let encoder = JSONEncoder()
    private var sendPlaintext: ((Data) -> Void)?
    private var window: NSWindow?
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var remoteVideoTrack: RTCVideoTrack?
    private var didInitializeSSL = false
    private var isClosingWindow = false
    private var forwardedKeyCodes = Set<UInt16>()
    private var lastPointerMoveSentAt: TimeInterval = 0
    private var pendingPointerMove: CtrlPointerBody?
    private var pointerMoveFlushWorkItem: DispatchWorkItem?
    private let statsQueue = DispatchQueue(label: "EdgeLinkMac.ScreenStats")
    private var statsTimer: DispatchSourceTimer?
    private let statsLogger = MacScreenStatsLogger()

    override init() {
        super.init()
        videoView.pointerHandler = { [weak self] action, event, wheelDy in
            self?.sendPointer(action: action, event: event, wheelDy: wheelDy)
        }
        videoView.keyHandler = { [weak self] event, isDown in
            self?.handleKey(event, isDown: isDown) ?? false
        }
    }

    func setSender(_ sender: @escaping (Data) -> Void) {
        sendPlaintext = sender
    }

    func clearSender() {
        sendPlaintext = nil
    }

    func openAndStart() {
        showWindow()
        if peerConnection != nil {
            status = hasRemoteVideo ? "Connected" : status
            DiagnosticsLog.info("screen.mac.window_shown_existing_session")
            return
        }
        status = "Starting"
        sendEnvelope(type: EnvelopeType.screenStart, body: EmptyBody())
    }

    func handleMeta(_ body: ScreenMetaBody) {
        screenMeta = body
        status = "Connecting"
        showWindow()
        DiagnosticsLog.info("screen.mac.meta w=\(body.w) h=\(body.h) scale=\(body.scale) dpi=\(body.dpi)")
    }

    func handleOffer(_ body: RtcSdpBody) {
        showWindow()
        status = "Answering"
        let pc = ensurePeerConnection()
        let offer = RTCSessionDescription(type: .offer, sdp: body.sdp)
        DiagnosticsLog.info("screen.mac.offer_in bytes=\(body.sdp.count)")
        pc.setRemoteDescription(offer) { [weak self] error in
            if let error {
                DiagnosticsLog.error("screen.mac.set_remote_offer_failed", error)
                DispatchQueue.main.async { self?.status = "Offer failed" }
                return
            }
            self?.createAnswer(on: pc)
        }
    }

    func handleAnswer(_ body: RtcSdpBody) {
        guard let peerConnection else {
            DiagnosticsLog.warn("screen.mac.answer_ignored no_peer_connection")
            return
        }
        status = "Connecting"
        let answer = RTCSessionDescription(type: .answer, sdp: body.sdp)
        DiagnosticsLog.info("screen.mac.answer_in bytes=\(body.sdp.count)")
        peerConnection.setRemoteDescription(answer) { [weak self] error in
            if let error {
                DiagnosticsLog.error("screen.mac.set_remote_answer_failed", error)
                DispatchQueue.main.async { self?.status = "Answer failed" }
                return
            }
            DispatchQueue.main.async { self?.status = "Connected" }
        }
    }

    func handleIce(_ body: RtcIceBody) {
        guard let peerConnection else {
            DiagnosticsLog.warn("screen.mac.ice_ignored no_peer_connection")
            return
        }
        DiagnosticsLog.info("screen.mac.ice_in mid=\(body.mid) index=\(body.index)")
        let candidate = RTCIceCandidate(
            sdp: body.candidate,
            sdpMLineIndex: Int32(body.index),
            sdpMid: body.mid
        )
        peerConnection.add(candidate) { error in
            if let error {
                DiagnosticsLog.error("screen.mac.add_ice_failed", error)
            }
        }
    }

    func stop(sendRemoteStop: Bool = true) {
        status = "Stopped"
        screenMeta = nil
        hasRemoteVideo = false
        cancelPendingPointerMove()
        if sendRemoteStop {
            sendEnvelope(type: EnvelopeType.screenStop, body: EmptyBody())
        }
        remoteVideoTrack?.remove(videoView)
        stopStatsLogging()
        videoView.clear()
        remoteVideoTrack = nil
        peerConnection?.close()
        peerConnection = nil
        factory = nil
        if didInitializeSSL {
            RTCCleanupSSL()
            didInitializeSSL = false
        }
    }

    func closeWindow(sendRemoteStop: Bool = true) {
        stop(sendRemoteStop: sendRemoteStop)
        guard let window else {
            return
        }
        isClosingWindow = true
        window.close()
        isClosingWindow = false
        self.window = nil
    }

    func sendGlobal(_ action: String) {
        DiagnosticsLog.info("screen.mac.global_out action=\(action)")
        sendEnvelope(type: EnvelopeType.ctrlGlobal, body: CtrlGlobalBody(action: action))
    }

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(videoView)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = PhoneScreenView(session: self)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Phone"
        window.minSize = NSSize(width: 260, height: 360)
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func ensurePeerConnection() -> RTCPeerConnection {
        if let peerConnection {
            return peerConnection
        }

        if !didInitializeSSL {
            RTCInitializeSSL()
            didInitializeSSL = true
        }
        let factory = RTCPeerConnectionFactory()
        self.factory = factory

        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        ) else {
            fatalError("Unable to create RTCPeerConnection.")
        }
        self.peerConnection = peerConnection
        startStatsLogging(on: peerConnection)
        return peerConnection
    }

    private func createAnswer(on peerConnection: RTCPeerConnection) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection.answer(for: constraints) { [weak self] answer, error in
            if let error {
                DiagnosticsLog.error("screen.mac.answer_create_failed", error)
                DispatchQueue.main.async { self?.status = "Answer failed" }
                return
            }
            guard let answer else {
                DiagnosticsLog.warn("screen.mac.answer_create_empty")
                DispatchQueue.main.async { self?.status = "Answer failed" }
                return
            }
            peerConnection.setLocalDescription(answer) { error in
                if let error {
                    DiagnosticsLog.error("screen.mac.set_local_answer_failed", error)
                    DispatchQueue.main.async { self?.status = "Answer failed" }
                    return
                }
                DiagnosticsLog.info("screen.mac.answer_out bytes=\(answer.sdp.count)")
                DispatchQueue.main.async {
                    self?.status = "Connected"
                    self?.sendEnvelope(type: EnvelopeType.rtcAnswer, body: RtcSdpBody(sdp: answer.sdp))
                }
            }
        }
    }

    private func attachRemoteVideoTrack(_ track: RTCVideoTrack) {
        if remoteVideoTrack === track {
            return
        }
        remoteVideoTrack?.remove(videoView)
        remoteVideoTrack = track
        track.add(videoView)
        hasRemoteVideo = true
        status = "Connected"
        DiagnosticsLog.info("screen.mac.remote_video_attached")
    }

    private func sendPointer(action: String, event: NSEvent, wheelDy: Int? = nil) {
        guard let coordinate = screenCoordinate(for: event) else {
            DiagnosticsLog.warn("screen.mac.pointer_ignored no_screen_meta action=\(action)")
            return
        }
        let body = CtrlPointerBody(x: coordinate.x, y: coordinate.y, action: action, wheelDy: wheelDy)
        if action == "move" {
            sendCoalescedPointerMove(body)
            return
        }
        flushPendingPointerMove()
        sendEnvelope(type: EnvelopeType.ctrlPointer, body: body)
    }

    private func handleKey(_ event: NSEvent, isDown: Bool) -> Bool {
        if let specialKey = specialKeyName(for: event) {
            sendKey(specialKey, down: isDown, modifiers: modifiers(from: event))
            return true
        }

        if isDown, shouldSendText(for: event), let text = event.characters, !text.isEmpty {
            sendEnvelope(type: EnvelopeType.ctrlText, body: CtrlTextBody(text: text))
            return true
        }

        if isDown, let key = printableKeyName(for: event) {
            forwardedKeyCodes.insert(event.keyCode)
            sendKey(key, down: true, modifiers: modifiers(from: event))
            return true
        }

        if !isDown, forwardedKeyCodes.remove(event.keyCode) != nil, let key = printableKeyName(for: event) {
            sendKey(key, down: false, modifiers: modifiers(from: event))
            return true
        }

        return false
    }

    private func sendKey(_ key: String, down: Bool, modifiers: [String]) {
        sendEnvelope(type: EnvelopeType.ctrlKey, body: CtrlKeyBody(key: key, down: down, mods: modifiers))
    }

    private func sendCoalescedPointerMove(_ body: CtrlPointerBody) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastPointerMoveSentAt
        if elapsed >= Self.pointerMoveIntervalSeconds, pendingPointerMove == nil {
            sendPointerMoveNow(body, now: now)
            return
        }

        pendingPointerMove = body
        schedulePointerMoveFlush(after: max(0, Self.pointerMoveIntervalSeconds - elapsed))
    }

    private func schedulePointerMoveFlush(after delay: TimeInterval) {
        guard pointerMoveFlushWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingPointerMove()
        }
        pointerMoveFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushPendingPointerMove() {
        pointerMoveFlushWorkItem?.cancel()
        pointerMoveFlushWorkItem = nil
        guard let body = pendingPointerMove else {
            return
        }
        pendingPointerMove = nil
        sendPointerMoveNow(body, now: ProcessInfo.processInfo.systemUptime)
    }

    private func cancelPendingPointerMove() {
        pointerMoveFlushWorkItem?.cancel()
        pointerMoveFlushWorkItem = nil
        pendingPointerMove = nil
    }

    private func sendPointerMoveNow(_ body: CtrlPointerBody, now: TimeInterval) {
        lastPointerMoveSentAt = now
        sendEnvelope(type: EnvelopeType.ctrlPointer, body: body)
    }

    private func screenCoordinate(for event: NSEvent) -> (x: Int, y: Int)? {
        guard let meta = screenMeta else {
            return nil
        }
        let bounds = videoView.bounds
        guard bounds.width > 0, bounds.height > 0, meta.w > 0, meta.h > 0 else {
            return nil
        }
        let point = videoView.convert(event.locationInWindow, from: nil)
        let x = clamped(point.x, lower: 0, upper: bounds.width)
        let y = clamped(bounds.height - point.y, lower: 0, upper: bounds.height)
        let deviceX = clampedInt((x / bounds.width * CGFloat(meta.w)).rounded(), lower: 0, upper: meta.w - 1)
        let deviceY = clampedInt((y / bounds.height * CGFloat(meta.h)).rounded(), lower: 0, upper: meta.h - 1)
        return (deviceX, deviceY)
    }

    private func shouldSendText(for event: NSEvent) -> Bool {
        let commandLikeFlags: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(commandLikeFlags).isEmpty else {
            return false
        }
        guard let characters = event.characters, !characters.isEmpty else {
            return false
        }
        return characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private func printableKeyName(for event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else {
            return nil
        }
        return characters
    }

    private func specialKeyName(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76:
            return "return"
        case 48:
            return "tab"
        case 49:
            return "space"
        case 51:
            return "delete"
        case 53:
            return "escape"
        case 117:
            return "forwardDelete"
        case 123:
            return "left"
        case 124:
            return "right"
        case 125:
            return "down"
        case 126:
            return "up"
        default:
            return nil
        }
    }

    private func modifiers(from event: NSEvent) -> [String] {
        var mods: [String] = []
        if event.modifierFlags.contains(.shift) {
            mods.append("shift")
        }
        if event.modifierFlags.contains(.control) {
            mods.append("ctrl")
        }
        if event.modifierFlags.contains(.option) {
            mods.append("alt")
        }
        if event.modifierFlags.contains(.command) {
            mods.append("cmd")
        }
        return mods
    }

    private func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private func clampedInt(_ value: CGFloat, lower: Int, upper: Int) -> Int {
        min(max(Int(value), lower), upper)
    }

    private func sendEnvelope<Body: Codable & Sendable>(type: String, body: Body) {
        guard let sendPlaintext else {
            DiagnosticsLog.warn("screen.mac.send_ignored no_secure_session type=\(type)")
            return
        }
        do {
            let data = try encoder.encode(Envelope(t: type, b: body))
            sendPlaintext(data)
        } catch {
            DiagnosticsLog.error("screen.mac.encode_failed type=\(type)", error)
        }
    }

    private func startStatsLogging(on peerConnection: RTCPeerConnection) {
        stopStatsLogging()
        statsQueue.sync {
            statsLogger.reset()
        }
        videoView.resetStats()

        let timer = DispatchSource.makeTimerSource(queue: statsQueue)
        timer.schedule(deadline: .now() + Self.statsIntervalSeconds, repeating: Self.statsIntervalSeconds)
        let statsWorkItem = DispatchWorkItem { [weak self, weak peerConnection] in
            guard let self, let peerConnection, self.peerConnection === peerConnection else {
                return
            }
            peerConnection.stats(for: nil, statsOutputLevel: .standard) { [weak self, weak peerConnection] reports in
                guard let self, let peerConnection, self.peerConnection === peerConnection else {
                    return
                }
                let renderer = self.videoView.statsSnapshot()
                self.statsQueue.async { [weak self, weak peerConnection] in
                    guard let self, let peerConnection, self.peerConnection === peerConnection else {
                        return
                    }
                    self.statsLogger.logLegacy(reports: reports as [AnyObject], renderer: renderer)
                }
            }
        }
        timer.setEventHandler(handler: statsWorkItem)
        statsTimer = timer
        timer.resume()
    }

    private func stopStatsLogging() {
        statsTimer?.setEventHandler {}
        statsTimer?.cancel()
        statsTimer = nil
        statsQueue.sync {
            statsLogger.reset()
        }
        videoView.resetStats()
    }

    private static let pointerMoveIntervalSeconds: TimeInterval = 1.0 / 30.0
    private static let statsIntervalSeconds: TimeInterval = 2.0
}

extension MacScreenSession: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingWindow else {
            return true
        }
        sender.orderOut(nil)
        DiagnosticsLog.info("screen.mac.window_hidden keep_projection=true")
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosingWindow else {
            window = nil
            return
        }
        stop(sendRemoteStop: true)
        window = nil
    }
}

extension MacScreenSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        DiagnosticsLog.info("screen.mac.signaling state=\(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.videoTracks.first else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.attachRemoteVideoTrack(track)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        DispatchQueue.main.async { [weak self] in
            self?.hasRemoteVideo = false
        }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        DiagnosticsLog.info("screen.mac.should_negotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DiagnosticsLog.info("screen.mac.ice_connection state=\(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        DiagnosticsLog.info("screen.mac.ice_gathering state=\(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let body = RtcIceBody(
            mid: candidate.sdpMid ?? "",
            index: Int(candidate.sdpMLineIndex),
            candidate: candidate.sdp
        )
        DispatchQueue.main.async { [weak self] in
            self?.sendEnvelope(type: EnvelopeType.rtcIce, body: body)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.attachRemoteVideoTrack(track)
        }
    }
}

struct PhoneScreenView: View {
    @ObservedObject var session: MacScreenSession

    var body: some View {
        ZStack {
            Color.black
            PhoneVideoView(videoView: session.videoView)
                .aspectRatio(aspectRatio, contentMode: .fit)
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    globalButton(systemName: "chevron.backward", action: "back", help: "Back")
                    globalButton(systemName: "circle", action: "home", help: "Home")
                    globalButton(systemName: "rectangle.stack", action: "recents", help: "Recents")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 14)
            }
            if !session.hasRemoteVideo {
                Text(session.status)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .frame(minWidth: 260, minHeight: 360)
    }

    private var aspectRatio: CGFloat? {
        guard let meta = session.screenMeta, meta.h > 0 else {
            return nil
        }
        return CGFloat(meta.w) / CGFloat(meta.h)
    }

    private func globalButton(systemName: String, action: String, help: String) -> some View {
        Button {
            session.sendGlobal(action)
        } label: {
            Image(systemName: systemName)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct PhoneVideoView: NSViewRepresentable {
    let videoView: PhoneVideoRendererView

    func makeNSView(context: Context) -> PhoneVideoRendererView {
        videoView
    }

    func updateNSView(_ nsView: PhoneVideoRendererView, context: Context) {}
}

private struct RendererStatsSnapshot {
    let timestamp: TimeInterval
    let receivedFrames: Int
    let drawnFrames: Int
    let unsupportedFrames: Int
    let convertedFrames: Int
    let totalConvertMs: Double
    let pendingMainFrames: Int
    let maxPendingMainFrames: Int
}

private final class MacScreenStatsLogger {
    private var previousInbound = [String: InboundSnapshot]()
    private var previousRenderer: RendererStatsSnapshot?

    func reset() {
        previousInbound.removeAll()
        previousRenderer = nil
    }

    func logLegacy(reports: [AnyObject], renderer: RendererStatsSnapshot) {
        let reports = reports.compactMap { $0 as? NSObject }
        let inbound = reports.first { report in
            let values = report.rtcLegacyValues
            return values.isVideo() ||
                values.string("googFrameRateDecoded") != nil ||
                values.string("googFrameWidthReceived") != nil ||
                report.rtcLegacyId.localizedCaseInsensitiveContains("video")
        }
        let pair = reports.first { report in
            let values = report.rtcLegacyValues
            return (report.rtcLegacyType == "googCandidatePair" || report.rtcLegacyType == "candidate-pair") &&
                (values.bool("googActiveConnection") == true ||
                    values.bool("selected") == true ||
                    values.bool("nominated") == true)
        }

        let line = NSMutableString(string: "screen.mac.stats")
        if let inbound {
            appendLegacyInbound(line, inbound)
        }
        if let pair {
            appendLegacyCandidatePair(line, pair)
        }
        appendRenderer(line, renderer)
        DiagnosticsLog.info(line as String)
    }

    func log(report: AnyObject, renderer: RendererStatsSnapshot) {
        guard
            let report = report as? NSObject,
            let statsById = report.value(forKey: "statistics") as? [String: NSObject]
        else {
            let line = NSMutableString(string: "screen.mac.stats")
            appendRenderer(line, renderer)
            line.append(" stats=unavailable")
            DiagnosticsLog.warn(line as String)
            return
        }
        let inbound = statsById.values.first { stat in
            stat.rtcStatType == "inbound-rtp" && stat.rtcStatValues.isVideo()
        }
        let pair = statsById.values.first { stat in
            stat.rtcStatType == "candidate-pair" &&
                stat.rtcStatValues.string("state") == "succeeded" &&
                (stat.rtcStatValues.bool("nominated") == true || stat.rtcStatValues.bool("selected") == true)
        }

        let line = NSMutableString(string: "screen.mac.stats")
        if let inbound {
            appendInbound(line, inbound)
        }
        if let pair {
            appendCandidatePair(line, pair, statsById: statsById)
        }
        appendRenderer(line, renderer)
        DiagnosticsLog.info(line as String)
    }

    private func appendLegacyInbound(_ line: NSMutableString, _ report: NSObject) {
        let values = report.rtcLegacyValues
        let framesDecoded = values.int("framesDecoded")
        let totalDecodeTime = values.double("totalDecodeTime")
        let jitterBufferDelay = values.double("jitterBufferDelay")
        let previous = previousInbound[report.rtcLegacyId]
        let deltaFrames = framesDecoded.flatMap { current in
            previous?.framesDecoded.map { current - $0 }
        }
        let deltaSeconds = previous.map { previousStat in
            (report.rtcLegacyTimestampMs * 1000.0 - previousStat.timestampUs) / 1_000_000.0
        }.flatMap { $0 > 0 ? $0 : nil }
        let measuredFps = deltaFrames.flatMap { frames in
            deltaSeconds.map { Double(frames) / $0 }
        }
        let avgDecodeMs: Double?
        if
            let previous,
            let deltaFrames,
            deltaFrames > 0,
            let totalDecodeTime,
            let previousTotalDecodeTime = previous.totalDecodeTime {
            avgDecodeMs = (totalDecodeTime - previousTotalDecodeTime) * 1000.0 / Double(deltaFrames)
        } else {
            avgDecodeMs = values.double("googDecodeMs")
        }
        let jitterMs = values.double("jitterBufferDelay").map { $0 * 1000.0 } ??
            values.double("googJitterBufferMs") ??
            values.double("googCurrentDelayMs")

        if framesDecoded != nil || totalDecodeTime != nil || jitterBufferDelay != nil {
            previousInbound[report.rtcLegacyId] = InboundSnapshot(
                timestampUs: report.rtcLegacyTimestampMs * 1000.0,
                framesDecoded: framesDecoded ?? previous?.framesDecoded,
                totalDecodeTime: totalDecodeTime ?? previous?.totalDecodeTime,
                jitterBufferDelay: jitterBufferDelay ?? previous?.jitterBufferDelay,
                jitterBufferEmittedCount: values.int("jitterBufferEmittedCount") ?? previous?.jitterBufferEmittedCount
            )
        }

        line.append(" fps=\(format1(values.double("framesPerSecond") ?? values.double("googFrameRateDecoded") ?? values.double("googFrameRateOutput") ?? measuredFps))")
        line.append(" dec=\(framesDecoded.map(String.init) ?? "-")")
        line.append(" drop=\(values.int("framesDropped").map(String.init) ?? "-")")
        line.append(" w=\((values.int("frameWidth") ?? values.int("googFrameWidthReceived")).map(String.init) ?? "-")")
        line.append(" h=\((values.int("frameHeight") ?? values.int("googFrameHeightReceived")).map(String.init) ?? "-")")
        line.append(" decMs=\(format1(avgDecodeMs))")
        line.append(" jitterMs=\(format1(jitterMs))")
        line.append(" impl=\(values.string("decoderImplementation") ?? "-")")
    }

    private func appendLegacyCandidatePair(_ line: NSMutableString, _ report: NSObject) {
        let values = report.rtcLegacyValues
        let rttMs = values.double("currentRoundTripTime").map { $0 * 1000.0 } ?? values.double("googRtt")
        let availableBitrate = values.double("availableIncomingBitrate") ??
            values.double("availableOutgoingBitrate") ??
            values.double("googAvailableReceiveBandwidth") ??
            values.double("googAvailableSendBandwidth")
        line.append(" rttMs=\(format1(rttMs))")
        line.append(" abwKbps=\(formatKbps(availableBitrate))")
        line.append(" path=\(values.string("localCandidateType") ?? values.string("googLocalCandidateType") ?? "-")>\(values.string("remoteCandidateType") ?? values.string("googRemoteCandidateType") ?? "-")")
    }

    private func appendInbound(_ line: NSMutableString, _ stat: NSObject) {
        let values = stat.rtcStatValues
        let framesDecoded = values.int("framesDecoded")
        let jitterBufferEmittedCount = values.int("jitterBufferEmittedCount")
        let totalDecodeTime = values.double("totalDecodeTime")
        let jitterBufferDelay = values.double("jitterBufferDelay")
        let previous = previousInbound[stat.rtcStatId]
        let deltaFrames = framesDecoded.flatMap { current in
            previous?.framesDecoded.map { current - $0 }
        }
        let deltaSeconds = previous.map { previousStat in
            (stat.rtcStatTimestampUs - previousStat.timestampUs) / 1_000_000.0
        }.flatMap { $0 > 0 ? $0 : nil }
        let measuredFps = deltaFrames.flatMap { frames in
            deltaSeconds.map { Double(frames) / $0 }
        }
        let avgDecodeMs: Double?
        if
            let previous,
            let deltaFrames,
            deltaFrames > 0,
            let totalDecodeTime,
            let previousTotalDecodeTime = previous.totalDecodeTime {
            avgDecodeMs = (totalDecodeTime - previousTotalDecodeTime) * 1000.0 / Double(deltaFrames)
        } else {
            avgDecodeMs = nil
        }
        let jitterMs: Double?
        if
            let previous,
            let jitterBufferEmittedCount,
            let previousCount = previous.jitterBufferEmittedCount,
            let jitterBufferDelay,
            let previousDelay = previous.jitterBufferDelay {
            let deltaCount = jitterBufferEmittedCount - previousCount
            jitterMs = deltaCount > 0 ? (jitterBufferDelay - previousDelay) * 1000.0 / Double(deltaCount) : nil
        } else {
            jitterMs = nil
        }

        if framesDecoded != nil || totalDecodeTime != nil || jitterBufferDelay != nil {
            previousInbound[stat.rtcStatId] = InboundSnapshot(
                timestampUs: stat.rtcStatTimestampUs,
                framesDecoded: framesDecoded ?? previous?.framesDecoded,
                totalDecodeTime: totalDecodeTime ?? previous?.totalDecodeTime,
                jitterBufferDelay: jitterBufferDelay ?? previous?.jitterBufferDelay,
                jitterBufferEmittedCount: jitterBufferEmittedCount ?? previous?.jitterBufferEmittedCount
            )
        }

        line.append(" fps=\(format1(values.double("framesPerSecond") ?? measuredFps))")
        line.append(" dec=\(framesDecoded.map(String.init) ?? "-")")
        line.append(" drop=\(values.int("framesDropped").map(String.init) ?? "-")")
        line.append(" w=\(values.int("frameWidth").map(String.init) ?? "-")")
        line.append(" h=\(values.int("frameHeight").map(String.init) ?? "-")")
        line.append(" decMs=\(format1(avgDecodeMs))")
        line.append(" jitterMs=\(format1(jitterMs))")
        line.append(" impl=\(values.string("decoderImplementation") ?? "-")")
    }

    private func appendCandidatePair(
        _ line: NSMutableString,
        _ pair: NSObject,
        statsById: [String: NSObject]
    ) {
        let values = pair.rtcStatValues
        let localType = candidateType(statsById: statsById, id: values.string("localCandidateId"))
        let remoteType = candidateType(statsById: statsById, id: values.string("remoteCandidateId"))
        let availableBitrate = values.double("availableIncomingBitrate") ?? values.double("availableOutgoingBitrate")
        line.append(" rttMs=\(format1(values.double("currentRoundTripTime").map { $0 * 1000.0 }))")
        line.append(" abwKbps=\(formatKbps(availableBitrate))")
        line.append(" path=\(localType ?? "-")>\(remoteType ?? "-")")
    }

    private func appendRenderer(_ line: NSMutableString, _ renderer: RendererStatsSnapshot) {
        let previous = previousRenderer
        let deltaSeconds = previous.map { renderer.timestamp - $0.timestamp }.flatMap { $0 > 0 ? $0 : nil }
        let receivedFps = previous.flatMap { previous in
            deltaSeconds.map { Double(renderer.receivedFrames - previous.receivedFrames) / $0 }
        }
        let drawnFps = previous.flatMap { previous in
            deltaSeconds.map { Double(renderer.drawnFrames - previous.drawnFrames) / $0 }
        }
        let convertMs: Double?
        if let previous {
            let convertedDelta = renderer.convertedFrames - previous.convertedFrames
            convertMs = convertedDelta > 0
                ? (renderer.totalConvertMs - previous.totalConvertMs) / Double(convertedDelta)
                : nil
        } else {
            convertMs = nil
        }
        previousRenderer = renderer

        line.append(" renderInFps=\(format1(receivedFps))")
        line.append(" renderDrawFps=\(format1(drawnFps))")
        line.append(" pending=\(renderer.pendingMainFrames)")
        line.append(" maxPending=\(renderer.maxPendingMainFrames)")
        line.append(" convertMs=\(format1(convertMs))")
        line.append(" unsupported=\(renderer.unsupportedFrames)")
    }

    private func candidateType(statsById: [String: NSObject], id: String?) -> String? {
        guard let id else {
            return nil
        }
        return statsById[id]?.rtcStatValues.string("candidateType")
    }

    private struct InboundSnapshot {
        let timestampUs: Double
        let framesDecoded: Int?
        let totalDecodeTime: Double?
        let jitterBufferDelay: Double?
        let jitterBufferEmittedCount: Int?
    }
}

final class PhoneVideoRendererView: NSView, RTCVideoRenderer {
    var pointerHandler: ((String, NSEvent, Int?) -> Void)?
    var keyHandler: ((NSEvent, Bool) -> Bool)?

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let statsLock = NSLock()
    private var lastSize: CGSize = .zero
    private var didLogUnsupportedFrameBuffer = false
    private var receivedFrames = 0
    private var drawnFrames = 0
    private var unsupportedFrames = 0
    private var convertedFrames = 0
    private var totalConvertMs = 0.0
    private var pendingMainFrames = 0
    private var maxPendingMainFrames = 0

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerHandler?("down", event, nil)
    }

    override func mouseDragged(with event: NSEvent) {
        pointerHandler?("move", event, nil)
    }

    override func mouseUp(with event: NSEvent) {
        pointerHandler?("up", event, nil)
    }

    override func rightMouseUp(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerHandler?("rightUp", event, nil)
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let wheelDy = Int(event.scrollingDeltaY.rounded())
        pointerHandler?("wheel", event, wheelDy == 0 ? nil : wheelDy)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event, true) != true {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if keyHandler?(event, false) != true {
            super.keyUp(with: event)
        }
    }

    func setSize(_ size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            self?.lastSize = size
            self?.needsLayout = true
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        recordReceivedFrame()
        guard let frame, let cvBuffer = frame.buffer as? RTCCVPixelBuffer else {
            logUnsupportedFrameBuffer(frame)
            return
        }

        let convertStartedAt = ProcessInfo.processInfo.systemUptime
        var image = CIImage(cvPixelBuffer: cvBuffer.pixelBuffer)
        if cvBuffer.requiresCropping() {
            image = image.cropped(to: CGRect(
                x: CGFloat(cvBuffer.cropX),
                y: CGFloat(cvBuffer.cropY),
                width: CGFloat(cvBuffer.cropWidth),
                height: CGFloat(cvBuffer.cropHeight)
            ))
        }
        image = rotated(image, rotation: frame.rotation.rawValue)

        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            return
        }
        recordConvertedFrame(ms: (ProcessInfo.processInfo.systemUptime - convertStartedAt) * 1000.0)
        recordMainFrameQueued()
        DispatchQueue.main.async { [weak self] in
            self?.layer?.contents = cgImage
            self?.recordMainFrameDrawn()
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.layer?.contents = nil
        }
    }

    func resetStats() {
        statsLock.lock()
        receivedFrames = 0
        drawnFrames = 0
        unsupportedFrames = 0
        convertedFrames = 0
        totalConvertMs = 0
        pendingMainFrames = 0
        maxPendingMainFrames = 0
        statsLock.unlock()
    }

    fileprivate func statsSnapshot() -> RendererStatsSnapshot {
        statsLock.lock()
        let snapshot = RendererStatsSnapshot(
            timestamp: ProcessInfo.processInfo.systemUptime,
            receivedFrames: receivedFrames,
            drawnFrames: drawnFrames,
            unsupportedFrames: unsupportedFrames,
            convertedFrames: convertedFrames,
            totalConvertMs: totalConvertMs,
            pendingMainFrames: pendingMainFrames,
            maxPendingMainFrames: maxPendingMainFrames
        )
        maxPendingMainFrames = pendingMainFrames
        statsLock.unlock()
        return snapshot
    }

    override func layout() {
        super.layout()
        layer?.contentsGravity = .resizeAspect
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }

    private func rotated(_ image: CIImage, rotation: Int) -> CIImage {
        switch rotation {
        case 90:
            return image.oriented(.right)
        case 180:
            return image.oriented(.down)
        case 270:
            return image.oriented(.left)
        default:
            return image
        }
    }

    private func logUnsupportedFrameBuffer(_ frame: RTCVideoFrame?) {
        statsLock.lock()
        unsupportedFrames += 1
        statsLock.unlock()
        guard !didLogUnsupportedFrameBuffer else {
            return
        }
        didLogUnsupportedFrameBuffer = true
        let bufferType = frame.map { String(describing: type(of: $0.buffer)) } ?? "nil"
        DiagnosticsLog.warn("screen.mac.unsupported_frame_buffer type=\(bufferType)")
    }

    private func recordReceivedFrame() {
        statsLock.lock()
        receivedFrames += 1
        statsLock.unlock()
    }

    private func recordConvertedFrame(ms: Double) {
        statsLock.lock()
        convertedFrames += 1
        totalConvertMs += ms
        statsLock.unlock()
    }

    private func recordMainFrameQueued() {
        statsLock.lock()
        pendingMainFrames += 1
        maxPendingMainFrames = max(maxPendingMainFrames, pendingMainFrames)
        statsLock.unlock()
    }

    private func recordMainFrameDrawn() {
        statsLock.lock()
        pendingMainFrames = max(0, pendingMainFrames - 1)
        drawnFrames += 1
        statsLock.unlock()
    }
}

private extension Dictionary where Key == String, Value == NSObject {
    func isVideo() -> Bool {
        string("kind") == "video" ||
            string("mediaType") == "video" ||
            string("trackIdentifier")?.localizedCaseInsensitiveContains("video") == true
    }

    func string(_ key: String) -> String? {
        self[key] as? String ?? self[key]?.description
    }

    func double(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber {
            return number.doubleValue
        }
        if let string = self[key] as? String {
            return Double(string)
        }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let number = self[key] as? NSNumber {
            return number.intValue
        }
        if let string = self[key] as? String {
            return Int(string)
        }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let number = self[key] as? NSNumber {
            return number.boolValue
        }
        if let string = self[key] as? String {
            return Bool(string)
        }
        return nil
    }
}

private extension NSObject {
    var rtcLegacyId: String {
        value(forKey: "reportId") as? String ?? ""
    }

    var rtcLegacyType: String {
        value(forKey: "type") as? String ?? ""
    }

    var rtcLegacyTimestampMs: Double {
        if let number = value(forKey: "timestamp") as? NSNumber {
            return number.doubleValue
        }
        return 0
    }

    var rtcLegacyValues: [String: NSObject] {
        value(forKey: "values") as? [String: NSObject] ?? [:]
    }

    var rtcStatId: String {
        value(forKey: "id") as? String ?? ""
    }

    var rtcStatType: String {
        value(forKey: "type") as? String ?? ""
    }

    var rtcStatTimestampUs: Double {
        if let number = value(forKey: "timestamp_us") as? NSNumber {
            return number.doubleValue
        }
        if let number = value(forKey: "timestamp") as? NSNumber {
            return number.doubleValue * 1000.0
        }
        return 0
    }

    var rtcStatValues: [String: NSObject] {
        value(forKey: "values") as? [String: NSObject] ?? [:]
    }
}

private func format1(_ value: Double?) -> String {
    guard let value else {
        return "-"
    }
    return String(format: "%.1f", value)
}

private func formatKbps(_ value: Double?) -> String {
    guard let value else {
        return "-"
    }
    return String(format: "%.0f", value / 1000.0)
}
