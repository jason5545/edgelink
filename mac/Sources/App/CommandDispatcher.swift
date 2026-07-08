import EdgeLinkKit
import Foundation

final class CommandDispatcher {
    private let inputInjector: InputInjector
    private let clipboardSync: ClipboardSync
    private let notificationPresenter: MacNotificationPresenter
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        inputInjector: InputInjector = InputInjector(),
        clipboardSync: ClipboardSync = ClipboardSync(),
        notificationPresenter: MacNotificationPresenter = MacNotificationPresenter()
    ) {
        self.inputInjector = inputInjector
        self.clipboardSync = clipboardSync
        self.notificationPresenter = notificationPresenter
    }

    func handle(_ plaintext: Data) throws -> Data? {
        let header = try decoder.decode(EnvelopeHeader.self, from: plaintext)
        switch header.t {
        case EnvelopeType.statusPing:
            return try encoder.encode(Envelope(t: EnvelopeType.statusPong, b: EmptyBody()))
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
