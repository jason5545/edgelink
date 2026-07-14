import AppKit
import AVFoundation
import CoreImage
import EdgeLinkKit
import SwiftUI
import WebRTC

final class MacScreenSession: NSObject, ObservableObject {
    @Published private(set) var status = "Idle"
    @Published private(set) var screenMeta: ScreenMetaBody?
    @Published private(set) var hasRemoteVideo = false
    @Published private(set) var hasRemoteAudio = false
    @Published private(set) var isPinned = false

    let videoView = PhoneVideoRendererView()
    var onWindowVisibilityChanged: ((Bool) -> Void)?
    var onSessionActivityChanged: ((Bool) -> Void)?

    private let encoder = JSONEncoder()
    private var sendPlaintext: ((Data) -> Void)?
    private var window: NSWindow?
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var remoteVideoTrack: RTCVideoTrack?
    private var remoteAudioTrack: RTCMediaStreamTrack?
    private var localMicrophoneSource: RTCAudioSource?
    private var localMicrophoneTrack: RTCAudioTrack?
    private var localMicrophoneSender: RTCRtpSender?
    private var controlDataChannel: RTCDataChannel?
    private var didInitializeSSL = false
    private var isClosingWindow = false
    private var isStopping = false
    private var isScreenSessionActive = false
    private var microphoneRelayEnabled = false
    private var forwardedKeyCodes = Set<UInt16>()
    private var lastPointerMoveSentAt: TimeInterval = 0
    private var pendingPointerMove: CtrlPointerBody?
    private var pointerMoveFlushWorkItem: DispatchWorkItem?
    private var pendingWheel: CtrlPointerBody?
    private var wheelFlushWorkItem: DispatchWorkItem?
    private let statsQueue = DispatchQueue(label: "EdgeLinkMac.ScreenStats")
    private var statsTimer: DispatchSourceTimer?
    private let statsLogger = MacScreenStatsLogger()
    private let mainThreadWatchdog = MainThreadWatchdog()

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
        if isScreenSessionActive && peerConnection == nil {
            status = "Starting"
            DiagnosticsLog.info("screen.mac.resume_start_after_reconnect")
            sendEnvelope(type: EnvelopeType.screenStart, body: EmptyBody())
        }
    }

    func clearSender() {
        sendPlaintext = nil
    }

    func setMicrophoneRelayEnabled(_ enabled: Bool) {
        guard microphoneRelayEnabled != enabled else {
            return
        }
        microphoneRelayEnabled = enabled
        DiagnosticsLog.info("screen.mac.microphone_relay_enabled enabled=\(enabled)")
        if enabled {
            requestMicrophoneAccessIfNeeded()
        } else {
            removeLocalMicrophoneTrack()
        }
        if isScreenSessionActive && peerConnection != nil {
            restartActiveSession(reason: "microphone_relay_changed")
        }
    }

    func openAndStart() {
        isScreenSessionActive = true
        onSessionActivityChanged?(true)
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
        guard isScreenSessionActive else {
            DiagnosticsLog.warn("screen.mac.meta_ignored inactive_session")
            return
        }
        screenMeta = body
        status = "Connecting"
        showWindow()
        DiagnosticsLog.info("screen.mac.meta w=\(body.w) h=\(body.h) scale=\(body.scale) dpi=\(body.dpi)")
    }

    func handleOffer(_ body: RtcSdpBody) {
        guard isScreenSessionActive else {
            DiagnosticsLog.warn("screen.mac.offer_ignored inactive_session")
            return
        }
        showWindow()
        status = "Answering"
        let pc = ensurePeerConnection()
        let offer = RTCSessionDescription(type: .offer, sdp: body.sdp)
        DiagnosticsLog.info("screen.mac.offer_in bytes=\(body.sdp.count)")
        pc.setRemoteDescription(offer) { [weak self, weak pc] error in
            DispatchQueue.main.async {
                guard let self, let pc, self.peerConnection === pc, self.isScreenSessionActive else {
                    DiagnosticsLog.warn("screen.mac.offer_set_ignored stale_peer")
                    return
                }
                if let error {
                    DiagnosticsLog.error("screen.mac.set_remote_offer_failed", error)
                    self.status = "Offer failed"
                    return
                }
                self.createAnswer(on: pc)
            }
        }
    }

    func handleAnswer(_ body: RtcSdpBody) {
        guard isScreenSessionActive else {
            DiagnosticsLog.warn("screen.mac.answer_ignored inactive_session")
            return
        }
        guard let peerConnection else {
            DiagnosticsLog.warn("screen.mac.answer_ignored no_peer_connection")
            return
        }
        status = "Connecting"
        let answer = RTCSessionDescription(type: .answer, sdp: body.sdp)
        DiagnosticsLog.info("screen.mac.answer_in bytes=\(body.sdp.count)")
        peerConnection.setRemoteDescription(answer) { [weak self, weak peerConnection] error in
            DispatchQueue.main.async {
                guard let self, let peerConnection, self.peerConnection === peerConnection, self.isScreenSessionActive else {
                    DiagnosticsLog.warn("screen.mac.answer_set_ignored stale_peer")
                    return
                }
                if let error {
                    DiagnosticsLog.error("screen.mac.set_remote_answer_failed", error)
                    self.status = "Answer failed"
                    return
                }
                self.status = "Connected"
            }
        }
    }

    func handleIce(_ body: RtcIceBody) {
        guard isScreenSessionActive else {
            DiagnosticsLog.warn("screen.mac.ice_ignored inactive_session")
            return
        }
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
        guard !isStopping else {
            DiagnosticsLog.warn("screen.mac.stop_ignored already_stopping")
            return
        }
        let shouldSendRemoteStop = sendRemoteStop && isScreenSessionActive
        let hadPeerConnection = peerConnection != nil
        let hadControlDataChannel = controlDataChannel != nil
        let hadRemoteVideoTrack = remoteVideoTrack != nil
        let hadRemoteAudioTrack = remoteAudioTrack != nil
        let hadSessionState = isScreenSessionActive || hadPeerConnection || hadControlDataChannel || hadRemoteVideoTrack || hadRemoteAudioTrack || screenMeta != nil
        guard hadSessionState || status != "Stopped" else {
            return
        }

        isStopping = true
        defer { isStopping = false }
        DiagnosticsLog.info(
            "screen.mac.stop_start sendRemoteStop=\(sendRemoteStop) willSendRemoteStop=\(shouldSendRemoteStop) active=\(isScreenSessionActive) pc=\(hadPeerConnection) dc=\(hadControlDataChannel)"
        )

        isScreenSessionActive = false
        onSessionActivityChanged?(false)
        status = "Stopped"
        screenMeta = nil
        hasRemoteVideo = false
        hasRemoteAudio = false
        cancelPendingPointerMove()
        cancelPendingWheel()
        if shouldSendRemoteStop {
            sendEnvelope(type: EnvelopeType.screenStop, body: EmptyBody())
        }

        let track = remoteVideoTrack
        remoteVideoTrack = nil
        track?.remove(videoView)
        remoteAudioTrack = nil
        localMicrophoneSender = nil
        localMicrophoneTrack = nil
        localMicrophoneSource = nil
        stopStatsLogging()
        videoView.clear()

        let dataChannel = controlDataChannel
        controlDataChannel = nil
        dataChannel?.delegate = nil

        let peerConnectionToClose = peerConnection
        self.peerConnection = nil
        peerConnectionToClose?.close()
        factory = nil
        DiagnosticsLog.info(
            "screen.mac.stop_done pc=\(hadPeerConnection) dc=\(hadControlDataChannel) video=\(hadRemoteVideoTrack) audio=\(hadRemoteAudioTrack)"
        )
    }

    func handleTransportInterrupted() {
        guard !isStopping else {
            DiagnosticsLog.warn("screen.mac.transport_interrupted_ignored already_stopping")
            return
        }

        let hadPeerConnection = peerConnection != nil
        let hadControlDataChannel = controlDataChannel != nil
        let hadRemoteVideoTrack = remoteVideoTrack != nil
        let hadRemoteAudioTrack = remoteAudioTrack != nil
        let shouldResume = isScreenSessionActive
        let hadSessionState = shouldResume || hadPeerConnection || hadControlDataChannel || hadRemoteVideoTrack || hadRemoteAudioTrack || screenMeta != nil
        guard hadSessionState else {
            return
        }

        isStopping = true
        defer { isStopping = false }
        DiagnosticsLog.info(
            "screen.mac.transport_interrupted resume=\(shouldResume) active=\(isScreenSessionActive) pc=\(hadPeerConnection) dc=\(hadControlDataChannel)"
        )

        status = shouldResume ? "Reconnecting" : "Stopped"
        hasRemoteVideo = false
        hasRemoteAudio = false
        cancelPendingPointerMove()
        cancelPendingWheel()

        let track = remoteVideoTrack
        remoteVideoTrack = nil
        track?.remove(videoView)
        remoteAudioTrack = nil
        localMicrophoneSender = nil
        localMicrophoneTrack = nil
        localMicrophoneSource = nil
        stopStatsLogging()
        videoView.clear()

        let dataChannel = controlDataChannel
        controlDataChannel = nil
        dataChannel?.delegate = nil

        let peerConnectionToClose = peerConnection
        peerConnection = nil
        peerConnectionToClose?.close()
        factory = nil

        if !shouldResume {
            isScreenSessionActive = false
            screenMeta = nil
        }

        DiagnosticsLog.info(
            "screen.mac.transport_interrupted_done resume=\(shouldResume) pc=\(hadPeerConnection) dc=\(hadControlDataChannel) video=\(hadRemoteVideoTrack) audio=\(hadRemoteAudioTrack)"
        )
    }

    func closeWindow(sendRemoteStop: Bool = true) {
        if let window {
            self.window = nil
            isClosingWindow = true
            window.delegate = nil
            window.close()
            isClosingWindow = false
            onWindowVisibilityChanged?(false)
        }
        stop(sendRemoteStop: sendRemoteStop)
    }

    func hideWindowAndStop(sendRemoteStop: Bool = true) {
        if let window {
            window.orderOut(nil)
            reportWindowVisibility(false, reason: "stopAndHide")
        }
        DiagnosticsLog.info("screen.mac.window_hidden stop_projection=true keep_window=true")
        stop(sendRemoteStop: sendRemoteStop)
    }

    func showActiveWindow() {
        guard isScreenSessionActive else {
            DiagnosticsLog.warn("screen.mac.show_ignored inactive_session")
            return
        }
        showWindow()
    }

    func sendGlobal(_ action: String) {
        markControlSent(kind: "global:\(action)", shouldLog: false)
        DiagnosticsLog.info("screen.mac.global_out action=\(action)")
        sendControlEnvelope(type: EnvelopeType.ctrlGlobal, body: CtrlGlobalBody(action: action))
    }

    func togglePinned() {
        isPinned.toggle()
        applyPinnedWindowState()
        DiagnosticsLog.info("screen.mac.window_pin pinned=\(isPinned)")
    }

    private func showWindow() {
        if let window {
            applyPinnedWindowState()
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(videoView)
            NSApp.activate(ignoringOtherApps: true)
            reportWindowVisibility(true, reason: "showWindow")
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
        self.window = window
        applyPinnedWindowState()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        NSApp.activate(ignoringOtherApps: true)
        reportWindowVisibility(true, reason: "showWindow")
    }

    private func applyPinnedWindowState() {
        guard let window else {
            return
        }
        window.level = isPinned ? .floating : .normal
        let pinnedBehaviors: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if isPinned {
            window.collectionBehavior = window.collectionBehavior.union(pinnedBehaviors)
        } else {
            window.collectionBehavior = window.collectionBehavior.subtracting(pinnedBehaviors)
        }
    }

    private func ensurePeerConnection() -> RTCPeerConnection {
        if let peerConnection {
            return peerConnection
        }

        if !didInitializeSSL {
            // WebRTC SSL is process-wide; keep it initialized for the app lifetime.
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
        addLocalMicrophoneTrackIfNeeded(to: peerConnection, factory: factory)
        startStatsLogging(on: peerConnection)
        return peerConnection
    }

    private func createAnswer(on peerConnection: RTCPeerConnection) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection.answer(for: constraints) { [weak self, weak peerConnection] answer, error in
            DispatchQueue.main.async {
                guard let self, let peerConnection, self.peerConnection === peerConnection, self.isScreenSessionActive else {
                    DiagnosticsLog.warn("screen.mac.answer_create_ignored stale_peer")
                    return
                }
                if let error {
                    DiagnosticsLog.error("screen.mac.answer_create_failed", error)
                    self.status = "Answer failed"
                    return
                }
                guard let answer else {
                    DiagnosticsLog.warn("screen.mac.answer_create_empty")
                    self.status = "Answer failed"
                    return
                }

                peerConnection.setLocalDescription(answer) { [weak self, weak peerConnection] error in
                    DispatchQueue.main.async {
                        guard let self, let peerConnection, self.peerConnection === peerConnection, self.isScreenSessionActive else {
                            DiagnosticsLog.warn("screen.mac.local_answer_ignored stale_peer")
                            return
                        }
                        if let error {
                            DiagnosticsLog.error("screen.mac.set_local_answer_failed", error)
                            self.status = "Answer failed"
                            return
                        }
                        DiagnosticsLog.info("screen.mac.answer_out bytes=\(answer.sdp.count)")
                        self.status = "Connected"
                        self.sendEnvelope(type: EnvelopeType.rtcAnswer, body: RtcSdpBody(sdp: answer.sdp))
                    }
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

    private func attachRemoteAudioTrack(_ track: RTCMediaStreamTrack) {
        if remoteAudioTrack === track {
            return
        }
        remoteAudioTrack = track
        track.isEnabled = true
        hasRemoteAudio = true
        status = "Connected"
        DiagnosticsLog.info("screen.mac.remote_audio_attached track=\(track.trackId)")
    }

    private func addLocalMicrophoneTrackIfNeeded(to peerConnection: RTCPeerConnection, factory: RTCPeerConnectionFactory) {
        guard microphoneRelayEnabled else {
            return
        }
        guard localMicrophoneSender == nil else {
            return
        }
        guard microphoneCaptureAllowedForTrackCreation() else {
            DiagnosticsLog.warn("screen.mac.local_microphone_track_skipped permission_denied")
            return
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: Self.microphoneTrackId)
        track.isEnabled = true
        guard let sender = peerConnection.add(track, streamIds: [Self.mediaStreamId]) else {
            DiagnosticsLog.warn("screen.mac.local_microphone_track_add_failed")
            return
        }
        localMicrophoneSource = source
        localMicrophoneTrack = track
        localMicrophoneSender = sender
        DiagnosticsLog.info("screen.mac.local_microphone_track_added track=\(track.trackId)")
    }

    private func removeLocalMicrophoneTrack() {
        let sender = localMicrophoneSender
        localMicrophoneSender = nil
        localMicrophoneTrack?.isEnabled = false
        localMicrophoneTrack = nil
        localMicrophoneSource = nil
        if let peerConnection, let sender {
            let removed = peerConnection.removeTrack(sender)
            DiagnosticsLog.info("screen.mac.local_microphone_track_removed removed=\(removed)")
        }
    }

    private func requestMicrophoneAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                DiagnosticsLog.info("screen.mac.microphone_permission_result granted=\(granted)")
            }
        }
    }

    private func microphoneCaptureAllowedForTrackCreation() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized, .notDetermined:
            return true
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func restartActiveSession(reason: String) {
        guard isScreenSessionActive, sendPlaintext != nil else {
            return
        }
        DiagnosticsLog.info("screen.mac.restart_requested reason=\(reason)")
        stop(sendRemoteStop: true)
        isScreenSessionActive = true
        onSessionActivityChanged?(true)
        status = "Starting"
        sendEnvelope(type: EnvelopeType.screenStart, body: EmptyBody())
    }

    private func sendPointer(action: String, event: NSEvent, wheelDy: Int? = nil) {
        guard let coordinate = screenCoordinate(for: event) else {
            DiagnosticsLog.warn("screen.mac.pointer_ignored no_screen_meta action=\(action)")
            return
        }
        let body = CtrlPointerBody(x: coordinate.x, y: coordinate.y, action: action, wheelDy: wheelDy)
        if action == "wheel" {
            sendCoalescedWheel(body)
            return
        }
        flushPendingWheel()
        if action == "move" {
            sendCoalescedPointerMove(body)
            return
        }
        flushPendingPointerMove()
        markControlSent(kind: "pointer:\(action)", shouldLog: true)
        sendControlEnvelope(type: EnvelopeType.ctrlPointer, body: body)
    }

    private func handleKey(_ event: NSEvent, isDown: Bool) -> Bool {
        if let specialKey = specialKeyName(for: event) {
            sendKey(specialKey, down: isDown, modifiers: modifiers(from: event))
            return true
        }

        if isDown, shouldSendText(for: event), let text = event.characters, !text.isEmpty {
            markControlSent(kind: "text", shouldLog: true)
            sendControlEnvelope(type: EnvelopeType.ctrlText, body: CtrlTextBody(text: text))
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
        markControlSent(kind: "key:\(key):\(down)", shouldLog: true)
        sendControlEnvelope(type: EnvelopeType.ctrlKey, body: CtrlKeyBody(key: key, down: down, mods: modifiers))
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
        markControlSent(kind: "pointer:move", shouldLog: false)
        sendControlEnvelope(type: EnvelopeType.ctrlPointer, body: body)
    }

    private func sendCoalescedWheel(_ body: CtrlPointerBody) {
        guard let wheelDy = body.wheelDy, wheelDy != 0 else {
            return
        }

        if let currentPendingWheel = pendingWheel, let pendingDy = currentPendingWheel.wheelDy {
            let mergedDy = min(max(pendingDy + wheelDy, -Self.maxPendingWheelDy), Self.maxPendingWheelDy)
            pendingWheel = mergedDy == 0
                ? nil
                : CtrlPointerBody(x: body.x, y: body.y, action: body.action, wheelDy: mergedDy)
        } else {
            pendingWheel = body
        }
        scheduleWheelFlush()
    }

    private func scheduleWheelFlush() {
        guard wheelFlushWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingWheel()
        }
        wheelFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wheelIntervalSeconds, execute: workItem)
    }

    private func flushPendingWheel() {
        wheelFlushWorkItem?.cancel()
        wheelFlushWorkItem = nil
        guard let body = pendingWheel else {
            return
        }
        pendingWheel = nil
        markControlSent(kind: "pointer:wheel", shouldLog: false)
        DiagnosticsLog.info("screen.mac.wheel_out dy=\(body.wheelDy ?? 0)")
        sendControlEnvelope(type: EnvelopeType.ctrlPointer, body: body)
    }

    private func cancelPendingWheel() {
        wheelFlushWorkItem?.cancel()
        wheelFlushWorkItem = nil
        pendingWheel = nil
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

    private func sendControlEnvelope<Body: Codable & Sendable>(type: String, body: Body) {
        do {
            let data = try encoder.encode(Envelope(t: type, b: body))
            if sendControlData(data, type: type) {
                return
            }
            sendEnvelopeData(data, type: type)
        } catch {
            DiagnosticsLog.error("screen.mac.encode_failed type=\(type)", error)
        }
    }

    private func sendViewerVisibility(visible: Bool, reason: String) {
        DiagnosticsLog.info("screen.mac.viewer_visibility_out visible=\(visible) reason=\(reason)")
        sendControlEnvelope(
            type: EnvelopeType.screenViewerVisibility,
            body: ScreenViewerVisibilityBody(visible: visible)
        )
    }

    private func reportWindowVisibility(_ visible: Bool, reason: String) {
        sendViewerVisibility(visible: visible, reason: reason)
        onWindowVisibilityChanged?(visible)
    }

    private func currentViewerVisible(for window: NSWindow?) -> Bool {
        guard let window, window.isVisible else {
            return false
        }
        return window.occlusionState.contains(.visible)
    }

    private func sendControlData(_ data: Data, type: String) -> Bool {
        guard let controlDataChannel, controlDataChannel.readyState == .open else {
            return false
        }
        let sent = controlDataChannel.sendData(RTCDataBuffer(data: data, isBinary: true))
        if !sent {
            DiagnosticsLog.warn("screen.mac.control_data_channel_send_failed type=\(type)")
        }
        return sent
    }

    private func sendEnvelope<Body: Codable & Sendable>(type: String, body: Body) {
        do {
            let data = try encoder.encode(Envelope(t: type, b: body))
            sendEnvelopeData(data, type: type)
        } catch {
            DiagnosticsLog.error("screen.mac.encode_failed type=\(type)", error)
        }
    }

    private func sendEnvelopeData(_ data: Data, type: String) {
        guard let sendPlaintext else {
            DiagnosticsLog.warn("screen.mac.send_ignored no_secure_session type=\(type)")
            return
        }
        sendPlaintext(data)
    }

    private func markControlSent(kind: String, shouldLog: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        videoView.markControlSent(at: now)
        if shouldLog {
            DiagnosticsLog.info("screen.mac.control_out kind=\(kind)")
        }
    }

    private func startStatsLogging(on peerConnection: RTCPeerConnection) {
        stopStatsLogging()
        statsQueue.sync {
            statsLogger.reset()
        }
        videoView.resetStats()
        mainThreadWatchdog.start()

        let timer = DispatchSource.makeTimerSource(queue: statsQueue)
        timer.schedule(deadline: .now() + Self.statsIntervalSeconds, repeating: Self.statsIntervalSeconds)
        let statsWorkItem = DispatchWorkItem { [weak self, weak peerConnection] in
            guard let self, let peerConnection, self.peerConnection === peerConnection else {
                return
            }
            peerConnection.statistics { [weak self, weak peerConnection] report in
                guard let self, let peerConnection, self.peerConnection === peerConnection else {
                    return
                }
                let renderer = self.videoView.statsSnapshot()
                self.statsQueue.async { [weak self, weak peerConnection] in
                    guard let self, let peerConnection, self.peerConnection === peerConnection else {
                        return
                    }
                    self.statsLogger.log(report: report, renderer: renderer)
                }
            }
        }
        timer.setEventHandler(handler: statsWorkItem)
        statsTimer = timer
        timer.resume()
    }

    private func stopStatsLogging() {
        mainThreadWatchdog.stop()
        statsTimer?.setEventHandler {}
        statsTimer?.cancel()
        statsTimer = nil
        statsQueue.sync {
            statsLogger.reset()
        }
        videoView.resetStats()
    }

    private static let pointerMoveIntervalSeconds: TimeInterval = 1.0 / 30.0
    private static let wheelIntervalSeconds: TimeInterval = 1.0 / 20.0
    private static let maxPendingWheelDy = 240
    private static let statsIntervalSeconds: TimeInterval = 2.0
    private static let controlChannelLabel = "edgelink-control"
    private static let mediaStreamId = "edgelink-screen"
    private static let microphoneTrackId = "edgelink-mac-microphone"
}

extension MacScreenSession: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingWindow else {
            return true
        }
        sender.orderOut(nil)
        reportWindowVisibility(false, reason: "windowShouldClose")
        DiagnosticsLog.info("screen.mac.window_hidden keep_projection=true")
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosingWindow else {
            window = nil
            return
        }
        reportWindowVisibility(false, reason: "windowWillClose")
        stop(sendRemoteStop: true)
        window = nil
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else {
            return
        }
        reportWindowVisibility(false, reason: "miniaturized")
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        let changedWindow = notification.object as? NSWindow
        guard changedWindow === window else {
            return
        }
        reportWindowVisibility(currentViewerVisible(for: changedWindow), reason: "deminiaturized")
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let changedWindow = notification.object as? NSWindow
        guard changedWindow === window else {
            return
        }
        reportWindowVisibility(currentViewerVisible(for: changedWindow), reason: "occlusion")
    }
}

extension MacScreenSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        DiagnosticsLog.info("screen.mac.signaling state=\(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let videoTrack = stream.videoTracks.first
        let audioTrack = stream.audioTracks.first
        DispatchQueue.main.async { [weak self, weak peerConnection] in
            guard let self, let peerConnection, self.peerConnection === peerConnection, self.isScreenSessionActive else {
                return
            }
            if let videoTrack {
                self.attachRemoteVideoTrack(videoTrack)
            }
            if let audioTrack {
                self.attachRemoteAudioTrack(audioTrack)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        let removedVideo = !stream.videoTracks.isEmpty
        let removedAudio = !stream.audioTracks.isEmpty
        DispatchQueue.main.async { [weak self, weak peerConnection] in
            guard let self, let peerConnection, self.peerConnection === peerConnection else {
                return
            }
            if removedVideo {
                self.hasRemoteVideo = false
                self.remoteVideoTrack = nil
            }
            if removedAudio {
                self.hasRemoteAudio = false
                self.remoteAudioTrack = nil
            }
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
        DispatchQueue.main.async { [weak self, weak peerConnection] in
            guard let self, let peerConnection, self.peerConnection === peerConnection, self.isScreenSessionActive else {
                return
            }
            self.sendEnvelope(type: EnvelopeType.rtcIce, body: body)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        guard dataChannel.label == Self.controlChannelLabel else {
            DiagnosticsLog.info("screen.mac.data_channel_ignored label=\(dataChannel.label)")
            return
        }
        DispatchQueue.main.async { [weak self, weak peerConnection] in
            guard let self, let peerConnection, self.peerConnection === peerConnection else {
                DiagnosticsLog.info("screen.mac.control_data_channel_ignored stale_peer")
                return
            }
            self.controlDataChannel?.delegate = nil
            self.controlDataChannel?.close()
            self.controlDataChannel = dataChannel
            dataChannel.delegate = self
            DiagnosticsLog.info("screen.mac.control_data_channel_open label=\(dataChannel.label)")
            self.sendViewerVisibility(
                visible: self.currentViewerVisible(for: self.window),
                reason: "dataChannelOpen"
            )
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track else {
            return
        }
        DispatchQueue.main.async { [weak self, weak peerConnection] in
            guard let self, let peerConnection, self.peerConnection === peerConnection, self.isScreenSessionActive else {
                return
            }
            if let videoTrack = track as? RTCVideoTrack {
                self.attachRemoteVideoTrack(videoTrack)
            } else if track.kind == "audio" {
                self.attachRemoteAudioTrack(track)
            }
        }
    }
}

extension MacScreenSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            DiagnosticsLog.info("screen.mac.control_data_channel_state state=\(dataChannel.readyState.rawValue)")
            if self.controlDataChannel === dataChannel, dataChannel.readyState == .closed {
                self.controlDataChannel?.delegate = nil
                self.controlDataChannel = nil
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        DiagnosticsLog.info("screen.mac.control_data_channel_message_ignored bytes=\(buffer.data.count)")
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
            VStack {
                HStack {
                    Spacer()
                    Button {
                        session.togglePinned()
                    } label: {
                        Image(systemName: session.isPinned ? "pin.fill" : "pin")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help(session.isPinned ? "Unpin" : "Keep on Top")
                    .accessibilityLabel(Text(session.isPinned ? "Unpin Phone Window" : "Pin Phone Window"))
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
                Spacer()
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

private final class MainThreadWatchdog {
    private let queue = DispatchQueue(label: "EdgeLinkMac.MainThreadWatchdog")
    private var timer: DispatchSourceTimer?

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.intervalSeconds, repeating: Self.intervalSeconds)
        timer.setEventHandler {
            let postedAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                let stallMs = (ProcessInfo.processInfo.systemUptime - postedAt) * 1000.0
                if stallMs > Self.stallThresholdMs {
                    DiagnosticsLog.warn("screen.mac.main_stall stallMs=\(format1(stallMs))")
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private static let intervalSeconds: TimeInterval = 0.1
    private static let stallThresholdMs = 100.0
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

    func log(report: RTCStatisticsReport, renderer: RendererStatsSnapshot) {
        let statsById = report.statistics.reduce(into: [String: NSObject]()) { partial, item in
            partial[item.key] = item.value
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
                packetsReceived: previous?.packetsReceived,
                bytesReceived: previous?.bytesReceived,
                totalDecodeTime: totalDecodeTime ?? previous?.totalDecodeTime,
                jitterBufferDelay: jitterBufferDelay ?? previous?.jitterBufferDelay,
                jitterBufferEmittedCount: values.int("jitterBufferEmittedCount") ?? previous?.jitterBufferEmittedCount,
                totalFreezesDuration: previous?.totalFreezesDuration,
                totalPausesDuration: previous?.totalPausesDuration
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
        let packetsReceived = values.int("packetsReceived")
        let bytesReceived = values.int("bytesReceived")
        let jitterBufferEmittedCount = values.int("jitterBufferEmittedCount")
        let totalDecodeTime = values.double("totalDecodeTime")
        let jitterBufferDelay = values.double("jitterBufferDelay")
        let totalFreezesDuration = values.double("totalFreezesDuration")
        let totalPausesDuration = values.double("totalPausesDuration")
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
        let receiveKbps: Double?
        if
            let previous,
            let bytesReceived,
            let previousBytesReceived = previous.bytesReceived,
            let deltaSeconds {
            receiveKbps = Double(bytesReceived - previousBytesReceived) * 8.0 / deltaSeconds / 1000.0
        } else {
            receiveKbps = nil
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
        let freezeDeltaMs: Double?
        if
            let previous,
            let totalFreezesDuration,
            let previousTotalFreezesDuration = previous.totalFreezesDuration {
            freezeDeltaMs = (totalFreezesDuration - previousTotalFreezesDuration) * 1000.0
        } else {
            freezeDeltaMs = nil
        }
        let pauseDeltaMs: Double?
        if
            let previous,
            let totalPausesDuration,
            let previousTotalPausesDuration = previous.totalPausesDuration {
            pauseDeltaMs = (totalPausesDuration - previousTotalPausesDuration) * 1000.0
        } else {
            pauseDeltaMs = nil
        }

        if
            framesDecoded != nil ||
            packetsReceived != nil ||
            bytesReceived != nil ||
            totalDecodeTime != nil ||
            jitterBufferDelay != nil {
            previousInbound[stat.rtcStatId] = InboundSnapshot(
                timestampUs: stat.rtcStatTimestampUs,
                framesDecoded: framesDecoded ?? previous?.framesDecoded,
                packetsReceived: packetsReceived ?? previous?.packetsReceived,
                bytesReceived: bytesReceived ?? previous?.bytesReceived,
                totalDecodeTime: totalDecodeTime ?? previous?.totalDecodeTime,
                jitterBufferDelay: jitterBufferDelay ?? previous?.jitterBufferDelay,
                jitterBufferEmittedCount: jitterBufferEmittedCount ?? previous?.jitterBufferEmittedCount,
                totalFreezesDuration: totalFreezesDuration ?? previous?.totalFreezesDuration,
                totalPausesDuration: totalPausesDuration ?? previous?.totalPausesDuration
            )
        }

        line.append(" fps=\(format1(values.double("framesPerSecond") ?? measuredFps))")
        line.append(" dec=\(framesDecoded.map(String.init) ?? "-")")
        line.append(" drop=\(values.int("framesDropped").map(String.init) ?? "-")")
        line.append(" w=\(values.int("frameWidth").map(String.init) ?? "-")")
        line.append(" h=\(values.int("frameHeight").map(String.init) ?? "-")")
        line.append(" decMs=\(format1(avgDecodeMs))")
        line.append(" jitterMs=\(format1(jitterMs))")
        line.append(" recvKbps=\(format1(receiveKbps))")
        line.append(" packets=\(packetsReceived.map(String.init) ?? "-")")
        line.append(" bytes=\(bytesReceived.map(String.init) ?? "-")")
        line.append(" key=\(values.int("keyFramesDecoded").map(String.init) ?? "-")")
        line.append(" pli=\(values.int("pliCount").map(String.init) ?? "-")")
        line.append(" nack=\(values.int("nackCount").map(String.init) ?? "-")")
        line.append(" freeze=\(values.int("freezeCount").map(String.init) ?? "-")")
        line.append(" freezeMs=\(format1(freezeDeltaMs))")
        line.append(" pause=\(values.int("pauseCount").map(String.init) ?? "-")")
        line.append(" pauseMs=\(format1(pauseDeltaMs))")
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
        let packetsReceived: Int?
        let bytesReceived: Int?
        let totalDecodeTime: Double?
        let jitterBufferDelay: Double?
        let jitterBufferEmittedCount: Int?
        let totalFreezesDuration: Double?
        let totalPausesDuration: Double?
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
    private var lastRenderFrameAt: TimeInterval = 0
    private var lastControlSentAt: TimeInterval = 0

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
        recordReceivedFrameAndGap()
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
        lastRenderFrameAt = 0
        lastControlSentAt = 0
        statsLock.unlock()
    }

    func markControlSent(at timestamp: TimeInterval) {
        statsLock.lock()
        lastControlSentAt = timestamp
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

    private func recordReceivedFrameAndGap() {
        let now = ProcessInfo.processInfo.systemUptime
        let gapMs: Double?
        let sinceControlMs: Double?
        statsLock.lock()
        receivedFrames += 1
        if lastRenderFrameAt > 0 {
            gapMs = (now - lastRenderFrameAt) * 1000.0
        } else {
            gapMs = nil
        }
        lastRenderFrameAt = now
        if lastControlSentAt > 0 {
            sinceControlMs = (now - lastControlSentAt) * 1000.0
        } else {
            sinceControlMs = nil
        }
        statsLock.unlock()
        if let gapMs, gapMs > Self.renderGapLogThresholdMs {
            DiagnosticsLog.info(
                "screen.mac.render_gap gapMs=\(format1(gapMs)) phase=\(Self.gapPhase(sinceControlMs)) sinceCtrlMs=\(format1(sinceControlMs))"
            )
        }
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

    private static let renderGapLogThresholdMs = 150.0
    private static let postControlGapWindowMs = 2_000.0

    private static func gapPhase(_ sinceControlMs: Double?) -> String {
        guard let sinceControlMs else {
            return "unknown"
        }
        return sinceControlMs <= postControlGapWindowMs ? "post_control" : "idle_or_static"
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
