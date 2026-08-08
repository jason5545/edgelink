import CryptoKit
import Foundation
import Network

// MARK: - Relay transport envelopes
// Carries the raw Xiaomi mesh/channel datagrams over an EdgeLink relay
// session so the production call-relay logic (announce dial, relayCall
// quick-conn, channel socket) runs unchanged when the peer is only reachable
// through the cloud relay. The worker stays blind: these are opaque payloads
// inside the E2EE session.

public struct RelayDatagramBody: Codable, Equatable, Sendable {
    public let payload: String
    // Logical flow index within the envelope type (nil/absent = 0). The cast
    // trust dial rides a second mesh flow (f=1) so the phone sees a fresh
    // peer for its phys sync, exactly like a brand-new LAN UDP socket; the
    // announce / relayCall dial stays on flow 0. Omitted on the wire when 0.
    public let f: Int?
    // Channel-only: the local Xiaomi port the phone side should dial for
    // this flow (the peer port the Mac's channel socket dialed). Lets the
    // phone bridge bind the channel flow lazily on first datagram.
    public let p: Int?

    public init(payload: String, f: Int? = nil, p: Int? = nil) {
        self.payload = payload
        self.f = f
        self.p = p
    }
}

// MARK: - Mesh datagram pipe
// The transport surface the mesh endpoints (Mac announcer / relayCall server
// side, phone mesh endpoint) need from LyraMeshSocket. A UDP socket and a
// relay-carried virtual pipe both satisfy it.

public protocol LyraMeshDatagramPipe: AnyObject {
    var onFrame: ((LyraMeshPack.Frame, NWEndpoint, LyraMeshSocket.ReplyHandler) -> Void)? { get set }
    var onRawDatagram: ((Data, NWEndpoint) -> Void)? { get set }
    var boundPort: UInt16? { get }
    func start(preferredPort: UInt16?) throws
    func stop()
    func send(frame: LyraMeshPack.Frame, to host: String, port: UInt16) throws
    func sendInboundAsync(frame: LyraMeshPack.Frame, toEndpointDescription: String)
}

extension LyraMeshSocket: LyraMeshDatagramPipe {}

// MARK: - Channel datagram pipe
// The transport surface the relayCall channel needs from LyraChannelSocket:
// the Mac side listens (start), the phone side dials (connect), both exchange
// negotiation TLVs and trans-key encrypted packets.

public protocol LyraChannelDatagramPipe: AnyObject {
    var onPeerConnected: ((NWEndpoint) -> Void)? { get set }
    var onNegotiated: ((UInt32, UInt32) -> Void)? { get set }
    var onMessage: ((Data, NWEndpoint) -> Void)? { get set }
    var boundPort: UInt16? { get }
    func start(socketKey: Data, serverChannelId: UInt32) throws
    func connect(host: String, port: UInt16, socketKey: Data) throws
    func sendClientNegotiation(channelId: UInt32, version: UInt32, mtu: UInt32) throws
    func sendVariant(channelFrame: Data, key: Data, singleLayer: Bool) throws
    func stop()
}

extension LyraChannelSocket: LyraChannelDatagramPipe {}

// MARK: - Virtual mesh pipe
// LyraMeshSocket stand-in: identical KCP-segmented frame stream (sn/una
// bookkeeping, acks, length-prefixed frame reassembly) with datagrams leaving
// through an injectable handler instead of UDP. Single-peer, like the real
// announce pairing.

public final class LyraVirtualMeshPipe: LyraMeshDatagramPipe, @unchecked Sendable {
    public typealias DatagramHandler = @Sendable (Data) -> Void

    public var onFrame: ((LyraMeshPack.Frame, NWEndpoint, LyraMeshSocket.ReplyHandler) -> Void)?
    public var onRawDatagram: ((Data, NWEndpoint) -> Void)?
    // Endpoint the peer's datagrams appear to arrive from. The Mac announcer
    // pins its dial port from it, so point it at the phone's mesh port.
    public var peerHost = "127.0.0.1"
    public var peerPort: UInt16 = 40101

    public private(set) var boundPort: UInt16?

    // Command byte stamped on outbound data segments (default push). Tests
    // flip this to commandAck to reproduce the real phone's ack-framed
    // responses (0x52 + payload).
    public var dataCommand: UInt8 = LyraMeshDatagram.commandPush

    private let queue = DispatchQueue(label: "edgelink.lyra.virtualmesh", qos: .userInitiated)
    private var outbound: DatagramHandler?
    private var nextSendSn: UInt32 = 0
    private var recvUna: UInt32 = 0
    private var recvBuffer = Data()
    private var pendingSegments: [UInt32: Data] = [:]

    // The phone's KCP input drops over-MTU datagrams, same as the UDP socket.
    private static let maxSegmentPayload = 1376
    private let defaultPort: UInt16

    public init(defaultPort: UInt16 = 40101) {
        self.defaultPort = defaultPort
    }

    // Wires the datagram exit (the relay bridge's envelope sender).
    public func attachOutbound(_ handler: @escaping DatagramHandler) {
        queue.sync { outbound = handler }
    }

    // Feeds a datagram that crossed the relay session from the peer.
    public func deliver(datagram: Data) {
        queue.async { [weak self] in
            self?.handleDatagramOnQueue(datagram)
        }
    }

    public func start(preferredPort: UInt16?) throws {
        queue.sync {
            boundPort = preferredPort.flatMap { $0 != 0 ? $0 : nil } ?? defaultPort
        }
    }

    public func stop() {
        // Async: frame handlers run on this queue (deliver → onFrame), and
        // LyraCastTrustSession.finishLocked() stops the pipe from inside such
        // a handler — a sync stop deadlocked the queue (SIGTRAP). The state
        // clear is idempotent and ordering is preserved by the serial queue.
        queue.async { [self] in
            boundPort = nil
            nextSendSn = 0
            recvUna = 0
            recvBuffer.removeAll()
            pendingSegments.removeAll()
        }
    }

    public func send(frame: LyraMeshPack.Frame, to host: String, port: UInt16) throws {
        let encoded = try LyraMeshPack.encode(frame)
        // Frame handlers run on this queue — never sync onto it here.
        queue.async { [weak self] in
            self?.sendEncodedOnQueue(encoded)
        }
    }

    public func sendInboundAsync(frame: LyraMeshPack.Frame, toEndpointDescription: String) {
        queue.async { [weak self] in
            guard let self, let encoded = try? LyraMeshPack.encode(frame) else { return }
            self.sendEncodedOnQueue(encoded)
        }
    }

    private func sendEncodedOnQueue(_ encoded: Data) {
        guard let outbound else { return }
        let tick = LyraMeshSocket.tick()
        var offset = 0
        while offset < encoded.count {
            let end = min(offset + Self.maxSegmentPayload, encoded.count)
            let datagram = LyraMeshDatagram.encode(
                command: dataCommand,
                tick: tick,
                sn: nextSendSn,
                una: recvUna,
                payload: encoded[offset..<end]
            )
            nextSendSn &+= 1
            outbound(datagram)
            offset = end
        }
    }

    private func handleDatagramOnQueue(_ datagram: Data) {
        let endpoint = peerEndpoint()
        onRawDatagram?(datagram, endpoint)
        // Accept any payload-bearing segment as data: the phone's mesh service
        // answers some dials with an ack-command datagram carrying the
        // response (0x52 + payload) instead of a push. Pure acks (no payload)
        // carry no data and are ignored.
        guard let segment = try? LyraMeshDatagram.decodeSegment(datagram),
              !segment.payload.isEmpty
        else { return }
        let isDuplicate = segment.sn < recvUna
        if !isDuplicate {
            pendingSegments[segment.sn] = segment.payload
            if pendingSegments.count > 64 {
                pendingSegments = [:]
                recvBuffer.removeAll()
            }
            var next = recvUna
            while let payload = pendingSegments.removeValue(forKey: next) {
                recvBuffer.append(payload)
                next &+= 1
            }
            recvUna = next
            if recvBuffer.count > 1_000_000 {
                recvBuffer.removeAll()
            }
        }
        let ack = LyraMeshDatagram.encodeAck(tick: LyraMeshSocket.tick(), sn: segment.sn, una: recvUna)
        outbound?(ack)
        if !isDuplicate {
            drainFrames(endpoint: endpoint)
        }
    }

    private func drainFrames(endpoint: NWEndpoint) {
        let reply: LyraMeshSocket.ReplyHandler = { [weak self] responseFrame in
            guard let self, let encoded = try? LyraMeshPack.encode(responseFrame) else { return }
            self.queue.async { self.sendEncodedOnQueue(encoded) }
        }
        while recvBuffer.count >= LyraMeshPack.headerLength {
            do {
                let decoded = try LyraMeshPack.decode(recvBuffer)
                recvBuffer.removeFirst(decoded.consumedBytes)
                onFrame?(decoded.frame, endpoint, reply)
            } catch LyraMeshPack.PackError.truncated {
                break
            } catch {
                recvBuffer.removeFirst()
            }
        }
    }

    private func peerEndpoint() -> NWEndpoint {
        .hostPort(
            host: NWEndpoint.Host(peerHost),
            port: NWEndpoint.Port(rawValue: peerPort) ?? NWEndpoint.Port(rawValue: defaultPort)!
        )
    }
}

// MARK: - Virtual channel pipe
// LyraChannelSocket stand-in for relay-carried channels (relayCall, cast):
// plaintext negotiation TLVs plus trans-key encrypted packets
// (LyraSocketPacket + LyraChannelFragment), wrapped in the same KCP
// segment framing (sn/una + acks) the real UDP channel socket uses, and
// exchanged through the relay session instead of UDP.

public final class LyraVirtualChannelPipe: LyraChannelDatagramPipe, @unchecked Sendable {
    public typealias DatagramHandler = @Sendable (Data) -> Void

    public var onPeerConnected: ((NWEndpoint) -> Void)?
    public var onNegotiated: ((UInt32, UInt32) -> Void)?
    public var onMessage: ((Data, NWEndpoint) -> Void)?
    // Endpoint the peer's datagrams appear to arrive from (log surface only).
    public var peerHost = "127.0.0.1"
    public var peerPort: UInt16 = 40201
    // Set by connect(): the dialed Xiaomi channel port (the relay bridge
    // stamps it onto outbound envelopes so the phone can bind its local
    // forward).
    private var dialedPeerPort: UInt16?

    // Command byte stamped on outbound data segments (default push). Tests
    // flip this to commandAck to reproduce the real phone's ack-framed
    // responses (0x52 + payload).
    public var dataCommand: UInt8 = LyraMeshDatagram.commandPush

    public private(set) var boundPort: UInt16?

    private let queue = DispatchQueue(label: "edgelink.lyra.virtualchannel", qos: .userInitiated)
    private var outbound: DatagramHandler?
    private var socketKey: SymmetricKey?
    private var nextSendSn: UInt32 = 0
    private var recvUna: UInt32 = 0
    private var announced = false
    private var packetBuffer = Data()
    private var fragments: [Int: Data] = [:]
    private var fragmentExpectedTotal = 0
    private let defaultPort: UInt16

    public init(defaultPort: UInt16 = 40201) {
        self.defaultPort = defaultPort
    }

    public func attachOutbound(_ handler: @escaping DatagramHandler) {
        queue.sync { outbound = handler }
    }

    public func deliver(datagram: Data) {
        queue.async { [weak self] in
            self?.handleDatagramOnQueue(datagram)
        }
    }

    public func start(socketKey: Data, serverChannelId: UInt32) throws {
        queue.sync {
            resetStateLocked()
            self.socketKey = SymmetricKey(data: socketKey)
            boundPort = defaultPort
        }
    }

    public func connect(host: String, port: UInt16, socketKey: Data) throws {
        queue.sync {
            resetStateLocked()
            self.socketKey = SymmetricKey(data: socketKey)
            self.peerPort = port
            self.dialedPeerPort = port
        }
        onPeerConnected?(peerEndpoint())
    }

    // The port the most recent connect() dialed (nil before the first dial).
    // The relay bridge stamps it onto outbound channel envelopes so the peer
    // can bind its local forward to the right Xiaomi channel port.
    public var currentDialedPeerPort: UInt16? {
        queue.sync { dialedPeerPort }
    }

    // Same value, but only callable from the pipe's own queue — the bridge
    // reads it inside the outbound handler (a queue.sync here would deadlock
    // against the delivery queue).
    func dialedPeerPortOnQueue() -> UInt16? {
        dialedPeerPort
    }

    // Mirrors LyraChannelSocket.stop(): a fresh start/connect begins a new KCP
    // session (redials must not carry stale sn/una into the peer's new socket).
    private func resetStateLocked() {
        nextSendSn = 0
        recvUna = 0
        announced = false
        packetBuffer.removeAll()
        fragments.removeAll()
        fragmentExpectedTotal = 0
    }

    public func sendClientNegotiation(channelId: UInt32, version: UInt32, mtu: UInt32) throws {
        let tlv = LyraExpressTLV.oneOfNode(
            tag: 0xFFFF,
            selectedTag: 0,
            child: LyraExpressTLV.containerNode(tag: 0, children: [
                LyraExpressTLV.int32Node(tag: 0, value: channelId),
                LyraExpressTLV.int32Node(tag: 1, value: version),
                LyraExpressTLV.int32Node(tag: 2, value: mtu)
            ])
        )
        sendDatagram(tlv)
    }

    public func sendVariant(channelFrame: Data, key: Data, singleLayer: Bool) throws {
        let symmetricKey = SymmetricKey(data: key)
        if singleLayer {
            let packet = try LyraSocketPacket.encode(plaintext: channelFrame, key: symmetricKey)
            sendDatagram(packet)
            return
        }
        let encodedFragments = try LyraChannelFragment.encode(message: channelFrame, key: symmetricKey)
        for fragment in encodedFragments {
            let packet = try LyraSocketPacket.encode(plaintext: fragment, key: symmetricKey)
            sendDatagram(packet)
        }
    }

    public func stop() {
        // Async: message handlers run on this queue (deliver → onMessage), and
        // session teardown stops the pipe from inside such handlers — a sync
        // stop deadlocks the queue. State clear is idempotent.
        queue.async { [self] in
            socketKey = nil
            boundPort = nil
            nextSendSn = 0
            recvUna = 0
            announced = false
            packetBuffer.removeAll()
            fragments.removeAll()
            fragmentExpectedTotal = 0
        }
    }

    // KCP segment exit — same framing the real channel socket emits on UDP.
    private func sendDatagram(_ payload: Data) {
        queue.async { [weak self] in
            self?.sendPayloadOnQueue(payload)
        }
    }

    private func sendPayloadOnQueue(_ payload: Data) {
        guard let outbound else { return }
        let datagram = LyraMeshDatagram.encode(
            command: dataCommand,
            tick: LyraMeshSocket.tick(),
            sn: nextSendSn,
            una: recvUna,
            payload: payload
        )
        nextSendSn &+= 1
        outbound(datagram)
    }

    private func handleDatagramOnQueue(_ datagram: Data) {
        let endpoint = peerEndpoint()
        // Accept any payload-bearing segment as data (see the mesh pipe note:
        // the phone can frame responses as ack + payload). Pure acks ignored.
        guard let segment = try? LyraMeshDatagram.decodeSegment(datagram),
              !segment.payload.isEmpty
        else { return }
        if !announced {
            announced = true
            onPeerConnected?(endpoint)
        }
        packetBuffer.append(segment.payload)
        recvUna = segment.sn &+ 1
        let ack = LyraMeshDatagram.encodeAck(tick: LyraMeshSocket.tick(), sn: segment.sn, una: recvUna)
        outbound?(ack)
        guard socketKey != nil else { return }
        while packetBuffer.count >= 2 {
            let first = packetBuffer[packetBuffer.startIndex]
            let second = packetBuffer[packetBuffer.index(packetBuffer.startIndex, offsetBy: 1)]
            if first == 0x01, second == 0x01 {
                guard packetBuffer.count >= 10 else { return }
                let tlvLength = 8 + Int(LyraChannelSocket.readUInt32BE(packetBuffer, at: 4))
                guard packetBuffer.count >= tlvLength else { return }
                let tlv = Data(packetBuffer.prefix(tlvLength))
                packetBuffer.removeFirst(tlvLength)
                handlePlaintextTLV(tlv)
            } else if first == 0x81, second == 0x04 {
                guard let frameLength = LyraSocketPacket.frameLength(prefix: packetBuffer),
                      frameLength > 0
                else {
                    packetBuffer = Data()
                    return
                }
                guard packetBuffer.count >= frameLength else { return }
                let frame = Data(packetBuffer.prefix(frameLength))
                packetBuffer.removeFirst(frameLength)
                guard let key = socketKey,
                      let (fragment, _) = try? LyraSocketPacket.decode(frame, key: key)
                else { continue }
                if let (chunk, offset, total, _) = try? LyraChannelFragment.decode(fragment: fragment, key: key) {
                    deliverChunk(chunk: chunk, offset: offset, total: total, endpoint: endpoint)
                } else if (try? LyraExpressTLVParser.parseOneOf(fragment)) != nil {
                    deliverChunk(chunk: fragment, offset: 0, total: 1, endpoint: endpoint)
                }
            } else {
                packetBuffer = Data()
                return
            }
        }
    }

    private func handlePlaintextTLV(_ tlv: Data) {
        guard let (selectedTag, children) = LyraChannelSocket.parseOneOf(tlv) else { return }
        if selectedTag == 0, children.count >= 3 {
            let peerChannelId = children[0]
            let mtu = children[2]
            let reply = LyraExpressTLV.oneOfNode(
                tag: 0xFFFF,
                selectedTag: 4,
                child: LyraExpressTLV.containerNode(tag: 4, children: [
                    LyraExpressTLV.int32Node(tag: 0, value: peerChannelId),
                    LyraExpressTLV.int32Node(tag: 1, value: 0xFF00)
                ])
            )
            sendPayloadOnQueue(reply)
            onNegotiated?(peerChannelId, mtu)
        } else if selectedTag == 4, !children.isEmpty {
            onNegotiated?(children[0], children.count > 1 ? children[1] : 0)
        }
    }

    private func deliverChunk(chunk: Data, offset: Int, total: Int, endpoint: NWEndpoint) {
        if total <= 1 {
            fragments.removeAll()
            fragmentExpectedTotal = 0
            onMessage?(chunk, endpoint)
            return
        }
        fragments[offset] = chunk
        fragmentExpectedTotal = total
        guard fragments.count == total else { return }
        var message = Data()
        for key in fragments.keys.sorted() {
            if let part = fragments[key] {
                message.append(part)
            }
        }
        fragments.removeAll()
        fragmentExpectedTotal = 0
        onMessage?(message, endpoint)
    }

    private func peerEndpoint() -> NWEndpoint {
        .hostPort(
            host: NWEndpoint.Host(peerHost),
            port: NWEndpoint.Port(rawValue: peerPort) ?? NWEndpoint.Port(rawValue: defaultPort)!
        )
    }
}
