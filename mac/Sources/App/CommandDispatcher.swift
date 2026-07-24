import EdgeLinkKit
import Foundation

final class CommandDispatcher {
    private let inputInjector: InputInjector
    private let clipboardSync: ClipboardSync
    private let notificationPresenter: MacNotificationPresenter
    private let screenSession: MacScreenSession?
    private let onStatusPong: @Sendable () -> Void
    private let onSmsMessage: @Sendable (SmsMessageBody) -> Void
    private let onSmsSendResult: @Sendable (SmsSendResultBody) -> Void
    private let onPhoneActionResult: @Sendable (PhoneActionResultBody) -> Void
    private let onPhoneRelayStartRequest: @Sendable (PhoneRelayStartRequestBody) -> Void
    private let onPhoneRelayMedia: @Sendable (PhoneRelayMediaBody) -> Void
    private let onPhoneCallStatus: @Sendable (PhoneCallStatusBody) -> Void
    private let onAndroidMicStatus: @Sendable (AndroidMicStatusBody) -> Void
    private let onMiLinkStatus: @Sendable (MiLinkStatusBody) -> Void
    private let onMiLinkFrame: @Sendable (MiLinkFrameBody) -> Void
    private let onMiLinkMirrorMedia: @Sendable (MiLinkMirrorMediaBody) -> Void
    private let onMiLinkCommandResult: @Sendable (MiLinkCommandResultBody) -> Void
    private let onTunnelEnvelope: @Sendable (String, Data) -> Void
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        inputInjector: InputInjector = InputInjector(),
        clipboardSync: ClipboardSync = ClipboardSync(),
        notificationPresenter: MacNotificationPresenter = MacNotificationPresenter(),
        screenSession: MacScreenSession? = nil,
        onStatusPong: @escaping @Sendable () -> Void = {},
        onSmsMessage: @escaping @Sendable (SmsMessageBody) -> Void = { _ in },
        onSmsSendResult: @escaping @Sendable (SmsSendResultBody) -> Void = { _ in },
        onPhoneActionResult: @escaping @Sendable (PhoneActionResultBody) -> Void = { _ in },
        onPhoneRelayStartRequest: @escaping @Sendable (PhoneRelayStartRequestBody) -> Void = { _ in },
        onPhoneRelayMedia: @escaping @Sendable (PhoneRelayMediaBody) -> Void = { _ in },
        onPhoneCallStatus: @escaping @Sendable (PhoneCallStatusBody) -> Void = { _ in },
        onAndroidMicStatus: @escaping @Sendable (AndroidMicStatusBody) -> Void = { _ in },
        onMiLinkStatus: @escaping @Sendable (MiLinkStatusBody) -> Void = { _ in },
        onMiLinkFrame: @escaping @Sendable (MiLinkFrameBody) -> Void = { _ in },
        onMiLinkMirrorMedia: @escaping @Sendable (MiLinkMirrorMediaBody) -> Void = { _ in },
        onMiLinkCommandResult: @escaping @Sendable (MiLinkCommandResultBody) -> Void = { _ in },
        onTunnelEnvelope: @escaping @Sendable (String, Data) -> Void = { _, _ in }
    ) {
        self.inputInjector = inputInjector
        self.clipboardSync = clipboardSync
        self.notificationPresenter = notificationPresenter
        self.screenSession = screenSession
        self.onStatusPong = onStatusPong
        self.onSmsMessage = onSmsMessage
        self.onSmsSendResult = onSmsSendResult
        self.onPhoneActionResult = onPhoneActionResult
        self.onPhoneRelayStartRequest = onPhoneRelayStartRequest
        self.onPhoneRelayMedia = onPhoneRelayMedia
        self.onPhoneCallStatus = onPhoneCallStatus
        self.onAndroidMicStatus = onAndroidMicStatus
        self.onMiLinkStatus = onMiLinkStatus
        self.onMiLinkFrame = onMiLinkFrame
        self.onMiLinkMirrorMedia = onMiLinkMirrorMedia
        self.onMiLinkCommandResult = onMiLinkCommandResult
        self.onTunnelEnvelope = onTunnelEnvelope
    }

    func handle(_ plaintext: Data) throws -> Data? {
        let header = try decoder.decode(EnvelopeHeader.self, from: plaintext)
        switch header.t {
        case EnvelopeType.statusPing:
            return try encoder.encode(Envelope(t: EnvelopeType.statusPong, b: EmptyBody()))
        case EnvelopeType.statusPong:
            onStatusPong()
            return nil
        case EnvelopeType.inputPointer:
            let envelope = try decoder.decode(Envelope<InputPointerBody>.self, from: plaintext)
            handlePointer(envelope.b)
            return nil
        case EnvelopeType.inputKey:
            let envelope = try decoder.decode(Envelope<InputKeyBody>.self, from: plaintext)
            handleKey(envelope.b)
            return nil
        case EnvelopeType.inputText:
            let envelope = try decoder.decode(Envelope<InputTextBody>.self, from: plaintext)
            inputInjector.typeText(envelope.b.text)
            return nil
        case EnvelopeType.clipboardSet:
            let envelope = try decoder.decode(Envelope<ClipboardSetBody>.self, from: plaintext)
            clipboardSync.applyRemoteText(envelope.b.text, hash: envelope.b.hash)
            return nil
        case EnvelopeType.notificationPost:
            let envelope = try decoder.decode(Envelope<NotificationPostBody>.self, from: plaintext)
            notificationPresenter.show(envelope.b)
            return nil
        case EnvelopeType.notificationRemove:
            let envelope = try decoder.decode(Envelope<NotificationRemoveBody>.self, from: plaintext)
            notificationPresenter.remove(envelope.b)
            return nil
        case EnvelopeType.smsMessage:
            let envelope = try decoder.decode(Envelope<SmsMessageBody>.self, from: plaintext)
            onSmsMessage(envelope.b)
            return nil
        case EnvelopeType.smsSendResult:
            let envelope = try decoder.decode(Envelope<SmsSendResultBody>.self, from: plaintext)
            onSmsSendResult(envelope.b)
            return nil
        case EnvelopeType.phoneActionResult:
            let envelope = try decoder.decode(Envelope<PhoneActionResultBody>.self, from: plaintext)
            onPhoneActionResult(envelope.b)
            return nil
        case EnvelopeType.phoneRelayStart:
            let envelope = try decoder.decode(Envelope<PhoneRelayStartRequestBody>.self, from: plaintext)
            onPhoneRelayStartRequest(envelope.b)
            return nil
        case EnvelopeType.phoneRelayMedia:
            let envelope = try decoder.decode(Envelope<PhoneRelayMediaBody>.self, from: plaintext)
            onPhoneRelayMedia(envelope.b)
            return nil
        case EnvelopeType.phoneCallStatus:
            let envelope = try decoder.decode(Envelope<PhoneCallStatusBody>.self, from: plaintext)
            onPhoneCallStatus(envelope.b)
            return nil
        case EnvelopeType.androidMicStatus:
            let envelope = try decoder.decode(Envelope<AndroidMicStatusBody>.self, from: plaintext)
            onAndroidMicStatus(envelope.b)
            return nil
        case EnvelopeType.miLinkStatus:
            let envelope = try decoder.decode(Envelope<MiLinkStatusBody>.self, from: plaintext)
            onMiLinkStatus(envelope.b)
            return nil
        case EnvelopeType.miLinkFrame:
            let envelope = try decoder.decode(Envelope<MiLinkFrameBody>.self, from: plaintext)
            onMiLinkFrame(envelope.b)
            return nil
        case EnvelopeType.miLinkMirrorMedia:
            let envelope = try decoder.decode(Envelope<MiLinkMirrorMediaBody>.self, from: plaintext)
            onMiLinkMirrorMedia(envelope.b)
            return nil
        case EnvelopeType.miLinkCommandResult:
            let envelope = try decoder.decode(Envelope<MiLinkCommandResultBody>.self, from: plaintext)
            onMiLinkCommandResult(envelope.b)
            return nil
        case EnvelopeType.screenMeta:
            let envelope = try decoder.decode(Envelope<ScreenMetaBody>.self, from: plaintext)
            DispatchQueue.main.async { [screenSession] in
                screenSession?.handleMeta(envelope.b)
            }
            return nil
        case EnvelopeType.rtcOffer:
            let envelope = try decoder.decode(Envelope<RtcSdpBody>.self, from: plaintext)
            DispatchQueue.main.async { [screenSession] in
                screenSession?.handleOffer(envelope.b)
            }
            return nil
        case EnvelopeType.rtcAnswer:
            let envelope = try decoder.decode(Envelope<RtcSdpBody>.self, from: plaintext)
            DispatchQueue.main.async { [screenSession] in
                screenSession?.handleAnswer(envelope.b)
            }
            return nil
        case EnvelopeType.rtcIce:
            let envelope = try decoder.decode(Envelope<RtcIceBody>.self, from: plaintext)
            DispatchQueue.main.async { [screenSession] in
                screenSession?.handleIce(envelope.b)
            }
            return nil
        case EnvelopeType.tunnelOpen, EnvelopeType.tunnelOpenResult, EnvelopeType.tunnelData,
             EnvelopeType.tunnelClose, EnvelopeType.tunnelError, EnvelopeType.tunnelFlow:
            onTunnelEnvelope(header.t, plaintext)
            return nil
        default:
            return nil
        }
    }

    private func handlePointer(_ body: InputPointerBody) {
        if body.dx != 0 || body.dy != 0 {
            inputInjector.movePointer(dx: body.dx, dy: body.dy)
        }
        if let scrollX = body.scrollX, scrollX != 0 || body.scrollY != nil {
            inputInjector.scroll(dx: scrollX, dy: body.scrollY ?? 0)
        } else if let scrollY = body.scrollY, scrollY != 0 {
            inputInjector.scroll(dx: 0, dy: scrollY)
        }
        if let button = body.btn.flatMap(InputInjector.MouseButton.init(rawValue:)) {
            inputInjector.click(button)
        }
    }

    private func handleKey(_ body: InputKeyBody) {
        let modifiers = Set(body.mods.compactMap(InputInjector.KeyModifier.init(rawValue:)))
        inputInjector.pressKey(body.key, modifiers: modifiers)
    }
}

private struct EnvelopeHeader: Codable {
    let t: String
}
