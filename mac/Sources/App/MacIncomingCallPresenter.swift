import AppKit
import AVFoundation
import EdgeLinkKit
import SwiftUI

@MainActor
final class MacIncomingCallPresenter {
    var onAnswerPhoneCall: (@MainActor @Sendable (String) -> Void)?
    var onHangUpPhoneCall: (@MainActor @Sendable (String) -> Void)?

    private let model = IncomingCallViewModel()
    private var panel: IncomingCallPanel?
    private var activeCallId: String?
    private var ringtonePlayer: AVAudioPlayer?
    private var answeredCallIds = Set<String>()
    private var locallyHandledCallIds = Set<String>()

    func reportIncomingCall(_ status: PhoneCallStatusBody) {
        guard !status.callId.isEmpty, !locallyHandledCallIds.contains(status.callId) else {
            return
        }

        let isNewCall = activeCallId != status.callId
        activeCallId = status.callId
        model.callerName = Self.callerName(for: status)
        model.callerDetail = Self.callerDetail(for: status)
        model.canAnswer = status.canAnswer
        model.canDecline = status.canHangUp
        model.onAnswer = { [weak self] in
            self?.answerCurrentCall()
        }
        model.onDecline = { [weak self] in
            self?.declineCurrentCall()
        }

        let panel = makePanelIfNeeded()
        position(panel)
        panel.orderFrontRegardless()

        if isNewCall {
            startRingtone(callId: status.callId)
        }
        DiagnosticsLog.info(
            "phone.mac.incoming_banner_shown callId=\(status.callId) caller=\(Self.logSafe(model.callerName))"
        )
    }

    func endCall(_ status: PhoneCallStatusBody, reason: EndReason) {
        endCall(callId: status.callId, reason: reason)
    }

    func endCall(callId: String, reason: EndReason) {
        guard !callId.isEmpty else {
            return
        }
        answeredCallIds.remove(callId)
        locallyHandledCallIds.remove(callId)
        if activeCallId == callId {
            dismissBanner()
        }
        DiagnosticsLog.info("phone.mac.incoming_banner_ended callId=\(callId) reason=\(reason.rawValue)")
    }

    func endAll(reason: EndReason) {
        answeredCallIds.removeAll()
        locallyHandledCallIds.removeAll()
        dismissBanner()
        DiagnosticsLog.info("phone.mac.incoming_banner_ended_all reason=\(reason.rawValue)")
    }

    func wasAnsweredByIncomingUI(callId: String) -> Bool {
        answeredCallIds.contains(callId)
    }

    private func answerCurrentCall() {
        guard let callId = activeCallId else {
            return
        }
        answeredCallIds.insert(callId)
        locallyHandledCallIds.insert(callId)
        dismissBanner()
        onAnswerPhoneCall?(callId)
        DiagnosticsLog.info("phone.mac.incoming_banner_answer callId=\(callId)")
    }

    private func declineCurrentCall() {
        guard let callId = activeCallId else {
            return
        }
        answeredCallIds.remove(callId)
        locallyHandledCallIds.insert(callId)
        dismissBanner()
        onHangUpPhoneCall?(callId)
        DiagnosticsLog.info("phone.mac.incoming_banner_decline callId=\(callId)")
    }

    private func makePanelIfNeeded() -> IncomingCallPanel {
        if let panel {
            return panel
        }

        let panel = IncomingCallPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: IncomingCallBanner(model: model))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.setContentSize(Self.panelSize)
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            return
        }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - Self.panelSize.width - Self.screenInset,
            y: visibleFrame.maxY - Self.panelSize.height - Self.screenInset
        )
        panel.setFrameOrigin(origin)
    }

    private func dismissBanner() {
        stopRingtone()
        panel?.orderOut(nil)
        activeCallId = nil
    }

    private func startRingtone(callId: String) {
        stopRingtone()
        guard let ringtoneURL = Self.ringtoneURL() else {
            NSSound(named: "Funk")?.play()
            DiagnosticsLog.warn("phone.mac.incoming_ringtone_fallback callId=\(callId) reason=system_tone_missing")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: ringtoneURL)
            player.numberOfLoops = -1
            player.volume = 1
            player.prepareToPlay()
            guard player.play() else {
                DiagnosticsLog.warn("phone.mac.incoming_ringtone_failed callId=\(callId) reason=play_returned_false")
                return
            }
            ringtonePlayer = player
            DiagnosticsLog.info(
                "phone.mac.incoming_ringtone_started callId=\(callId) tone=\(ringtoneURL.deletingPathExtension().lastPathComponent)"
            )
        } catch {
            DiagnosticsLog.error("phone.mac.incoming_ringtone_failed callId=\(callId)", error)
            NSSound(named: "Funk")?.play()
        }
    }

    private func stopRingtone() {
        ringtonePlayer?.stop()
        ringtonePlayer = nil
    }

    private static func ringtoneURL() -> URL? {
        for path in ringtonePaths where FileManager.default.isReadableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func callerName(for status: PhoneCallStatusBody) -> String {
        let displayName = status.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !displayName.isEmpty {
            return displayName
        }
        let handle = status.handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return handle.isEmpty ? "未知來電" : handle
    }

    private static func callerDetail(for status: PhoneCallStatusBody) -> String {
        let handle = status.handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = status.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !handle.isEmpty, handle != name {
            return "iPhone • \(handle)"
        }
        return "iPhone 行動電話"
    }

    private static func logSafe(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "_")
    }

    enum EndReason: String {
        case failed
        case remoteEnded
        case unanswered
        case answeredElsewhere
        case declinedElsewhere
    }

    private static let panelSize = NSSize(width: 372, height: 148)
    private static let screenInset: CGFloat = 12
    private static let toneResources = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones"
    private static let ringtonePaths = [
        "\(toneResources)/Reflection-EncoreInfinitum.m4r",
        "\(toneResources)/Reflection.m4r"
    ]
}

@MainActor
private final class IncomingCallViewModel: ObservableObject {
    @Published var callerName = "未知來電"
    @Published var callerDetail = "iPhone 行動電話"
    @Published var canAnswer = true
    @Published var canDecline = true
    var onAnswer: (() -> Void)?
    var onDecline: (() -> Void)?
}

private final class IncomingCallPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct IncomingCallBanner: View {
    @ObservedObject var model: IncomingCallViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.13))
                    Image(systemName: "person.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.callerName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(model.callerDetail)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "iphone")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            HStack(spacing: 10) {
                CallActionButton(
                    title: "拒絕",
                    systemImage: "phone.down.fill",
                    color: Color(nsColor: .systemRed),
                    isEnabled: model.canDecline,
                    action: { model.onDecline?() }
                )
                CallActionButton(
                    title: "接聽",
                    systemImage: "phone.fill",
                    color: Color(nsColor: .systemGreen),
                    isEnabled: model.canAnswer,
                    action: { model.onAnswer?() }
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 372, height: 148)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("iPhone 來電，\(model.callerName)")
    }
}

private struct CallActionButton: View {
    let title: String
    let systemImage: String
    let color: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(color.opacity(isEnabled ? 1 : 0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
