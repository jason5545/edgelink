import EdgeLinkKit
import Foundation

// Network-impairment stand-in for the cloud relay path (Cloudflare Worker +
// TURN data channel). The production dc is unreliable + unordered, so the
// relay session must survive message loss, duplication, reordering, latency
// spikes, and full blackouts (WiFi→5G transport flips). Profiles below are
// tuned from live measurements:
// - HiNet↔Cloudflare SIN detour: ~67ms RTT (docs/relay-analysis.md)
// - TURN anycast direct: ~6.6ms RTT
struct RelayImpairmentProfile: Sendable {
    // One-way base latency in seconds.
    var latency: TimeInterval = 0
    // Uniform extra delay in [0, jitter] added per message.
    var jitter: TimeInterval = 0
    // Probability [0,1] of dropping a message.
    var loss: Double = 0
    // Probability [0,1] of delivering an extra copy (delayed by jitter/2).
    var duplicate: Double = 0

    static var perfect: RelayImpairmentProfile { RelayImpairmentProfile() }

    // Measured Mac(HiNet)→CF SIN PoP path: 67ms RTT with routing jitter.
    static var hiNetCloudflareWAN: RelayImpairmentProfile {
        RelayImpairmentProfile(latency: 0.033, jitter: 0.012)
    }

    // Same RTT with delivery order preserved — isolates latency from
    // reordering when bisecting relay failures.
    static var hiNetCloudflareWANOrdered: RelayImpairmentProfile {
        RelayImpairmentProfile(latency: 0.033, jitter: 0)
    }

    static func lossy(_ fraction: Double, base: RelayImpairmentProfile = .hiNetCloudflareWAN) -> RelayImpairmentProfile {
        var profile = base
        profile.loss = fraction
        return profile
    }
}

// One direction of an impaired link. Delivery is scheduled per message so
// jitter naturally reorders; loss and duplication are applied per message.
final class ImpairedByteChannel: ByteChannel, @unchecked Sendable {
    struct Stats {
        var sent = 0
        var delivered = 0
        var dropped = 0
        var duplicated = 0
    }

    private let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let peer: () -> ImpairedByteChannel?
    private let lock = NSLock()
    private var profile: RelayImpairmentProfile
    private var blackoutUntil: Date?
    private(set) var stats = Stats()
    private var closed = false
    // Order-preserving delay line for zero-jitter profiles (models the
    // production WebSocket relay: delayed but strictly ordered). Jittered
    // profiles deliver from parallel tasks instead — reorder is the point.
    private var deliveryChain: Task<Void, Never>?

    init(profile: RelayImpairmentProfile, peer: @escaping () -> ImpairedByteChannel?) {
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.profile = profile
        self.peer = peer
    }

    func updateProfile(_ update: (inout RelayImpairmentProfile) -> Void) {
        lock.lock()
        update(&profile)
        lock.unlock()
    }

    // Transport flip: every message sent during the window is dropped.
    func blackout(for duration: TimeInterval) {
        lock.lock()
        blackoutUntil = Date().addingTimeInterval(duration)
        lock.unlock()
    }

    func send(_ bytes: Data) async throws {
        guard let peer = peer() else { throw ImpairedChannelError.closed }
        let snapshot: RelayImpairmentProfile
        let inBlackout: Bool
        lock.lock()
        if closed { throw ImpairedChannelError.closed }
        snapshot = profile
        if let until = blackoutUntil {
            inBlackout = Date() < until
            if !inBlackout { blackoutUntil = nil }
        } else {
            inBlackout = false
        }
        stats.sent += 1
        lock.unlock()

        if inBlackout || Double.random(in: 0..<1) < snapshot.loss {
            lock.lock()
            stats.dropped += 1
            lock.unlock()
            return
        }
        scheduleDelivery(bytes, to: peer, profile: snapshot)
        if Double.random(in: 0..<1) < snapshot.duplicate {
            lock.lock()
            stats.duplicated += 1
            lock.unlock()
            scheduleDelivery(bytes, to: peer, profile: snapshot, extraDelay: snapshot.jitter / 2)
        }
    }

    private func scheduleDelivery(
        _ bytes: Data, to peer: ImpairedByteChannel,
        profile: RelayImpairmentProfile, extraDelay: TimeInterval = 0
    ) {
        let delay = profile.latency + Double.random(in: 0...max(profile.jitter, 0)) + extraDelay
        lock.lock()
        stats.delivered += 1
        if delay <= 0 {
            lock.unlock()
            // Perfect-link behavior: synchronous delivery preserves send
            // order exactly like the old LoopbackChannelPair.
            peer.deliver(bytes)
            return
        }
        if profile.jitter <= 0, extraDelay <= 0 {
            // Sleep until enqueueTime + delay (not delay-after-previous) so
            // bursts don't accumulate lag; order is preserved by the chain.
            let deliverAt = Date().addingTimeInterval(delay)
            let previous = deliveryChain
            let next = Task {
                await previous?.value
                let remaining = deliverAt.timeIntervalSinceNow
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                peer.deliver(bytes)
            }
            deliveryChain = next
            lock.unlock()
            return
        }
        lock.unlock()
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            peer.deliver(bytes)
        }
    }

    func receive() async throws -> Data? {
        for await data in incoming {
            return data
        }
        return nil
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        continuation.finish()
    }

    fileprivate func deliver(_ data: Data) {
        continuation.yield(data)
    }
}

enum ImpairedChannelError: Error {
    case closed
}

// Bidirectional impaired link; each direction carries its own profile so the
// Mac→phone and phone→Mac legs can be impaired independently.
final class ImpairedChannelPair {
    let hostSide: ImpairedByteChannel
    let clientSide: ImpairedByteChannel

    init(
        hostToClient: RelayImpairmentProfile = .perfect,
        clientToHost: RelayImpairmentProfile = .perfect
    ) {
        var host: ImpairedByteChannel!
        var client: ImpairedByteChannel!
        // hostSide.send() → client receives: that leg uses clientToHost? No —
        // the host SENDS on the host→client leg, so the host side's send
        // profile is the host→client profile.
        host = ImpairedByteChannel(profile: hostToClient) { client }
        client = ImpairedByteChannel(profile: clientToHost) { host }
        hostSide = host
        clientSide = client
    }
}
