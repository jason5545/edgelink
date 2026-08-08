import Foundation

// Carries the Xiaomi mesh + channel datagram flows over an EdgeLink relay
// session. Each side attaches its local endpoints (the announce mesh pipe,
// the relayCall/cast channel pipe) to the bridge; datagrams leave as
// relay.mesh.datagram / relay.channel.datagram envelopes and arrive on the
// peer's matching pipe. Sends are chained so KCP segment order survives the
// async session send.
//
// Mesh flows are indexed (body.f, default 0): the announce/relayCall dial
// uses flow 0 while the cast trust dial uses flow 1, so the phone side can
// present each flow from its own UDP socket — the Xiaomi mesh service keys
// peers by source endpoint and only answers phys sync from a fresh peer.
public final class LyraRelayTransportBridge: @unchecked Sendable {
    public typealias SendHandler = @Sendable (Data) async throws -> Void

    public let mesh: LyraVirtualMeshPipe
    public let channel: LyraVirtualChannelPipe

    private let sendHandler: SendHandler
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var lastSend: Task<Void, Never>?
    private var meshFlows: [Int: LyraVirtualMeshPipe] = [:]

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
            self?.enqueue(EnvelopeType.relayMeshDatagram, datagram, flow: 0)
        }
        channel.attachOutbound { [weak self] datagram in
            guard let self else { return }
            // Stamp the dialed Xiaomi channel port so the phone bridge can
            // bind its local forward on first datagram (it has no other way
            // to learn which channel listener this flow targets). The read
            // must stay on-queue: this handler already runs on the pipe's
            // delivery queue.
            self.enqueue(
                EnvelopeType.relayChannelDatagram, datagram, flow: 0,
                dialPort: self.channel.dialedPeerPortOnQueue()
            )
        }
    }

    // The mesh pipe for a logical flow index (lazily created; index 0 is the
    // shared `mesh` property).
    public func meshFlow(index: Int) -> LyraVirtualMeshPipe {
        if index == 0 { return mesh }
        lock.lock()
        defer { lock.unlock() }
        if let existing = meshFlows[index] { return existing }
        let pipe = LyraVirtualMeshPipe()
        meshFlows[index] = pipe
        pipe.attachOutbound { [weak self] datagram in
            self?.enqueue(EnvelopeType.relayMeshDatagram, datagram, flow: index)
        }
        return pipe
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
        let flow = envelope.b.f ?? 0
        switch type {
        case EnvelopeType.relayMeshDatagram:
            meshFlow(index: flow).deliver(datagram: datagram)
        case EnvelopeType.relayChannelDatagram:
            channel.deliver(datagram: datagram)
        default:
            break
        }
    }

    private func enqueue(_ type: String, _ datagram: Data, flow: Int, dialPort: UInt16? = nil) {
        let payload = datagram.base64EncodedString()
        let sendHandler = sendHandler
        let log = log
        lock.lock()
        let previous = lastSend
        let next = Task {
            await previous?.value
            do {
                let body = RelayDatagramBody(
                    payload: payload,
                    f: flow == 0 ? nil : flow,
                    p: dialPort.map { Int($0) }
                )
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
