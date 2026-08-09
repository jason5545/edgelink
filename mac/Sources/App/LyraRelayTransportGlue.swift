import EdgeLinkKit
import Foundation

// Transport-selection glue between the secure session and the Xiaomi relay
// stack: which transport gets a relay bridge + announcer, and when an
// existing cast trust session must be invalidated because the transport it
// rides is gone. Extracted from EdgeLinkRuntime so the decision logic is
// unit-testable without constructing the whole runtime; the runtime drives
// this through closures over its own state.
enum LyraRelayTransportGlue {
    struct Context {
        // Cast-session invalidation hooks.
        var hasExistingCastSession: () -> Bool = { false }
        var existingCastSessionIsRelayRouted: () -> Bool = { false }
        var invalidateCastSession: () -> Void = {}
        // Bridge/announcer state hooks.
        var stopAnnouncer: () -> Void = {}
        var setBridge: (LyraRelayTransportBridge?) -> Void = { _ in }
        var currentBridge: () -> LyraRelayTransportBridge? = { nil }
        var setAnnouncer: (LyraMeshAnnouncer?) -> Void = { _ in }
        var currentAnnouncer: () -> LyraMeshAnnouncer? = { nil }
        // Bridge send path (only needed when configuring a fresh bridge).
        var sendPlaintext: (_ data: Data) async throws -> Void = { _ in }
        // Announcer gating hooks.
        var relayCallAdvertiseEnabled: () -> Bool = { false }
        var reportedPhoneMeshPort: () -> UInt16? = { nil }
        var deviceIdHex: () -> String? = { nil }
        var displayName: () -> String = { "EdgeLink Mac" }
        var log: (String) -> Void = { _ in }
    }

    // Binds the relay-datagram bridge to the secure session's send path when
    // the phone is only reachable through the cloud relay. The LAN UDP
    // announcer / cast session stay intact as the fallback; the bridge is
    // only populated on the relay transport.
    static func configureRelayBridge(transport: String, context: Context) {
        context.stopAnnouncer()
        // A fresh secure session replaces the relay bridge object; a cast
        // session riding the old bridge's pipes is dead even though
        // isChannelReady stays true (live 2026-08-08: OPEN_MIRROR_SCREEN was
        // sent into the dead channel and the mirror start churned phone-side
        // cloud sessions until the WebRTC teardown crashed the app). The
        // same applies when the transport FLIPPED: a LAN-routed session
        // whose phone left the LAN keeps its stale isChannelReady and the
        // flow sends OPEN into a dead pipe (live 2026-08-09: phone switched
        // to 5G, castChannel=timeout, zero media). Only a LAN session with
        // the transport still on LAN survives (its mesh socket is
        // independent of the secure session).
        if context.hasExistingCastSession(),
           context.existingCastSessionIsRelayRouted() || transport == "relay"
        {
            context.invalidateCastSession()
        }
        guard transport == "relay" else {
            context.setBridge(nil)
            return
        }
        let bridge = LyraRelayTransportBridge(
            sendHandler: { data in try await context.sendPlaintext(data) },
            log: { context.log("bridge.\($0)") }
        )
        context.setBridge(bridge)
        context.log("configured transport=\(transport)")
        startRelayAnnouncerIfEnabled(context: context)
    }

    // Reproduces the LAN announce dial over the relay-carried mesh pipe so
    // the phone registers this Mac as an online relayCall device (gated the
    // same way as the LAN announcer).
    static func startRelayAnnouncerIfEnabled(context: Context) {
        guard let bridge = context.currentBridge() else { return }
        guard context.relayCallAdvertiseEnabled() else { return }
        guard let phoneMeshPort = context.reportedPhoneMeshPort() else {
            context.log("announcer.deferred reason=no_phone_mesh_port")
            return
        }
        // The announcer pins its dial port from the inbound endpoint; point
        // the relay mesh pipe at the phone's announced mesh port before
        // starting.
        bridge.mesh.peerPort = phoneMeshPort
        let announcer = context.currentAnnouncer() ?? LyraMeshAnnouncer(
            deviceIdHexProvider: context.deviceIdHex,
            displayNameProvider: context.displayName,
            meshTransport: bridge.mesh
        )
        announcer.relayCallChannelTransport = bridge.channel
        context.setAnnouncer(announcer)
        announcer.start(host: "127.0.0.1", port: phoneMeshPort)
        context.log("announcer.started port=\(phoneMeshPort)")
    }
}
