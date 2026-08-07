import EdgeLinkKit
import Foundation

// Carries the Xiaomi mesh + relayCall channel datagram flows over an EdgeLink
// relay session. Each side attaches its local endpoints (the announce mesh
// pipe and the relayCall channel pipe) to the bridge; datagrams leave as
// relay.mesh.datagram / relay.channel.datagram envelopes and arrive on the
// peer's matching pipe. Sends are chained so KCP segment order survives the
// async session send.
public final class LyraRelayTransportBridge: @unchecked Sendable {
    public typealias SendHandler = @Sendable (Data) async throws -> Void

    public let mesh: LyraVirtualMeshPipe
    public let channel: LyraVirtualChannelPipe

    private let sendHandler: SendHandler
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var lastSend: Task<Void, Never>?

    public init(
        mesh: LyraVirtualMeshPipe = LyraVirtualMeshPipe(),
        channel: LyraVirtualChannelPipe = LyraVirtualChannelPipe(),
        sendHandler: @escaping SendHandler,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.mesh = mesh
        self.channel = channel
        self.sendHandler = sendHandler
        self.log = log
        mesh.attachOutbound { [weak self] datagram in
            self?.enqueue(EnvelopeType.relayMeshDatagram, datagram)
        }
        channel.attachOutbound { [weak self] datagram in
            self?.enqueue(EnvelopeType.relayChannelDatagram, datagram)
        }
    }

    public static func handles(_ type: String) -> Bool {
        type == EnvelopeType.relayMeshDatagram || type == EnvelopeType.relayChannelDatagram
    }

    public func handleEnvelope(type: String, plaintext: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope<RelayDatagramBody>.self, from: plaintext),
              let datagram = Data(base64Encoded: envelope.b.payload), !datagram.isEmpty
        else {
            log("relay.transport_bad_envelope type=\(type)")
            return
        }
        switch type {
        case EnvelopeType.relayMeshDatagram:
            mesh.deliver(datagram: datagram)
        case EnvelopeType.relayChannelDatagram:
            channel.deliver(datagram: datagram)
        default:
            break
        }
    }

    private func enqueue(_ type: String, _ datagram: Data) {
        let payload = datagram.base64EncodedString()
        let sendHandler = sendHandler
        let log = log
        lock.lock()
        let previous = lastSend
        let next = Task {
            await previous?.value
            do {
                let body = RelayDatagramBody(payload: payload)
                let encoded = try JSONEncoder().encode(Envelope(t: type, b: body))
                try await sendHandler(encoded)
            } catch {
                log("relay.transport_send_failed type=\(type) error=\(error)")
            }
        }
        lastSend = next
        lock.unlock()
    }
}
