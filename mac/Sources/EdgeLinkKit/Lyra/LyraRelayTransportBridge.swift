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
// The Mac-initiated relayCall DIAL takes random mesh flow indexes above
// `dialFlowIndexFloor` so a dial never retires (or is retired by) a cast
// dial on the phone bridge. Channel flows are indexed the same way: flow 0
// is the shared cast/relayCall channel pipe, non-zero flows are Mac-dialed
// relayCall dial channels (one per dial, so a dial mid-mirror does not
// clobber the cast channel).
public final class LyraRelayTransportBridge: @unchecked Sendable {
    public typealias SendHandler = @Sendable (Data) async throws -> Void

    // Mac-initiated relayCall dials take mesh/channel flow indexes at or
    // above this floor; the phone bridge retires only same-partition flows
    // when a fresh index arrives, so a dial never kills a cast dial's
    // socket (and vice versa).
    public static let dialFlowIndexFloor = 1_000_000_001

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
    // Mac-dialed channel pipes keyed by flow index (the relayCall dial
    // channel on a relay-routed session). Flow 0 is the shared `channel`.
    private var dialedChannelFlows: [Int: LyraVirtualChannelPipe] = [:]
    // Server channel ports the PEER announced out-of-band via
    // relay.channel.listen (the peer hosts a phone-dialed server channel and
    // wants our reverse listener up before its responseOfPeerPort arrives).
    // Production Mac never dials such channels; the test harness's phone-side
    // bridge gates its reverse-listener model on this set.
    public private(set) var announcedChannelListeners: Set<Int> = []

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

    // The channel pipe for a Mac-dialed channel flow (the relayCall dial
    // when the cast session already owns `channel`). Index 0 is `channel`
    // itself. Each pipe's outbound envelopes carry the flow index plus the
    // dialed Xiaomi channel port, so the phone bridge binds a per-flow local
    // forward to that port — exactly like a fresh LAN UDP socket.
    public func channelFlow(index: Int) -> LyraVirtualChannelPipe {
        if index == 0 { return channel }
        lock.lock()
        defer { lock.unlock() }
        if let existing = dialedChannelFlows[index] { return existing }
        let pipe = LyraVirtualChannelPipe()
        dialedChannelFlows[index] = pipe
        pipe.attachOutbound { [weak self, weak pipe] datagram in
            guard let self else { return }
            self.enqueue(
                EnvelopeType.relayChannelDatagram, datagram, flow: index,
                dialPort: pipe?.dialedPeerPortOnQueue()
            )
        }
        return pipe
    }

    public static func handles(_ type: String) -> Bool {
        type == EnvelopeType.relayMeshDatagram || type == EnvelopeType.relayChannelDatagram
            || type == EnvelopeType.relayChannelListen
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
        if type == EnvelopeType.relayChannelListen {
            guard let envelope = try? JSONDecoder().decode(Envelope<RelayChannelListenBody>.self, from: plaintext)
            else {
                log("relay.transport_bad_envelope type=\(type)")
                return
            }
            lock.lock()
            announcedChannelListeners.insert(envelope.b.p)
            lock.unlock()
            log("relay.channel_listen_rx port=\(envelope.b.p)")
            return
        }
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
            // server pipe. Non-zero flow indexes are Mac-dialed relayCall
            // dial channels. Unstamped flow-0 envelopes keep the legacy
            // behavior: everything lands on the Mac-dialed cast/relayCall
            // pipe.
            if let port = envelope.b.p {
                lock.lock()
                let pipe = channelPipes[port]
                lock.unlock()
                if let pipe {
                    pipe.deliver(datagram: datagram)
                    return
                }
            }
            if flow != 0 {
                lock.lock()
                let pipe = dialedChannelFlows[flow]
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

    // Announces a server channel port we host (the mitrustservice pipe) so
    // the peer's bridge binds its reverse listener directly instead of
    // snooping the responseOfPeerPort off the lossy mesh stream.
    public func announceChannelListener(port: UInt16) {
        let sendHandler = sendHandler
        let log = log
        lock.lock()
        let previous = lastSend
        let next = Task {
            await previous?.value
            do {
                let body = RelayChannelListenBody(p: Int(port))
                let encoded = try JSONEncoder().encode(Envelope(t: EnvelopeType.relayChannelListen, b: body))
                try await sendHandler(encoded)
            } catch {
                log("relay.transport_send_failed type=\(EnvelopeType.relayChannelListen) error=\(error)")
            }
        }
        lastSend = next
        lock.unlock()
        log("relay.channel_listen_tx port=\(port)")
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
