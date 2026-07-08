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

    override init() {
        super.init()
    }

    func setSender(_ sender: @escaping (Data) -> Void) {
        sendPlaintext = sender
    }

    func clearSender() {
        sendPlaintext = nil
    }

    func openAndStart() {
        showWindow()
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
        if sendRemoteStop {
            sendEnvelope(type: EnvelopeType.screenStop, body: EmptyBody())
        }
        remoteVideoTrack?.remove(videoView)
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

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
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
}

extension MacScreenSession: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard !isClosingWindow else {
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
}

struct PhoneVideoView: NSViewRepresentable {
    let videoView: PhoneVideoRendererView

    func makeNSView(context: Context) -> PhoneVideoRendererView {
        videoView
    }

    func updateNSView(_ nsView: PhoneVideoRendererView, context: Context) {}
}

final class PhoneVideoRendererView: NSView, RTCVideoRenderer {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lastSize: CGSize = .zero
    private var didLogUnsupportedFrameBuffer = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    func setSize(_ size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            self?.lastSize = size
            self?.needsLayout = true
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let cvBuffer = frame.buffer as? RTCCVPixelBuffer else {
            logUnsupportedFrameBuffer(frame)
            return
        }

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
        DispatchQueue.main.async { [weak self] in
            self?.layer?.contents = cgImage
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.layer?.contents = nil
        }
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
        guard !didLogUnsupportedFrameBuffer else {
            return
        }
        didLogUnsupportedFrameBuffer = true
        let bufferType = frame.map { String(describing: type(of: $0.buffer)) } ?? "nil"
        DiagnosticsLog.warn("screen.mac.unsupported_frame_buffer type=\(bufferType)")
    }
}
