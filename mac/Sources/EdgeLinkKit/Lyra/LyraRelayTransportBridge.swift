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
    // Server channel pipes keyed by their advertised port (the mitrustservice
    // channel on a relay-routed session). Inbound channel envelopes stamped
    // with "p" route here; unstamped envelopes keep landing on `channel` (the
    // Mac-dialed cast/relayCall pipe) for backward compatibility.
    private var channelPipes: [Int: LyraVirtualChannelPipe] = [:]

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

    // The channel pipe for a phone-dialed server channel (mitrustservice on a
    // relay-routed session). The pipe's outbound envelopes are stamped with
    // the port so the phone bridge can route the datagrams to the local
    // reverse listener that the phone's channel client dialed.
    public func channelPipe(port: UInt16) -> LyraVirtualChannelPipe {
        lock.lock()
        defer { lock.unlock() }
        if let existing = channelPipes[Int(port)] { return existing }
        let pipe = LyraVirtualChannelPipe(defaultPort: port)
        channelPipes[Int(port)] = pipe
        pipe.attachOutbound { [weak self] datagram in
            self?.enqueue(EnvelopeType.relayChannelDatagram, datagram, flow: 0, dialPort: port)
        }
        return pipe
    }

    // Drops a server channel pipe when its channel is torn down so late
    // datagrams for the port fall back to `channel` instead of a dead pipe.
    public func removeChannelPipe(port: UInt16) {
        lock.lock()
        channelPipes.removeValue(forKey: Int(port))
        lock.unlock()
    }

    // Allocates a port for a new server channel pipe: unique within this
    // bridge and outside the well-known Xiaomi service ranges.
    public func allocateChannelPort() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        while true {
            let candidate = UInt16.random(in: 20_000...60_999)
            if channelPipes[Int(candidate)] == nil { return candidate }
        }
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
            // The phone bridge stamps the Mac-side port it dialed ("p") onto
            // phone-initiated channel envelopes; route those to the matching
            // server pipe. Unstamped (or unknown-port) envelopes keep the
            // legacy behavior: everything lands on the Mac-dialed pipe.
            if let port = envelope.b.p {
                lock.lock()
                let pipe = channelPipes[port]
                lock.unlock()
                if let pipe {
                    pipe.deliver(datagram: datagram)
                    return
                }
            }
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
