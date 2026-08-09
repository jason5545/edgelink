import EdgeLinkKit
import Foundation
import XCTest

// The transport-selection glue between the secure session and the Xiaomi
// relay stack: which transport gets a relay bridge + announcer, when the
// announcer is gated off, and when an existing cast trust session must be
// invalidated because the transport it rides is gone. Drives the real glue
// with spy closures over real bridge/announcer objects.
final class LyraRelayTransportGlueTests: XCTestCase {
    private var bridge: LyraRelayTransportBridge?
    private var announcer: LyraMeshAnnouncer?
    private var announcerStopped = false
    private var castSessionInvalidated = false
    private var hasCastSession = false
    private var castSessionIsRelayRouted = false
    private var advertiseEnabled = true
    private var reportedPort: UInt16? = 43495

    override func setUp() {
        super.setUp()
        bridge = nil
        announcer = nil
        announcerStopped = false
        castSessionInvalidated = false
        hasCastSession = false
        castSessionIsRelayRouted = false
        advertiseEnabled = true
        reportedPort = 43495
    }

    private func makeContext() -> LyraRelayTransportGlue.Context {
        LyraRelayTransportGlue.Context(
            hasExistingCastSession: { self.hasCastSession },
            existingCastSessionIsRelayRouted: { self.castSessionIsRelayRouted },
            invalidateCastSession: { self.castSessionInvalidated = true },
            stopAnnouncer: { self.announcerStopped = true },
            setBridge: { self.bridge = $0 },
            currentBridge: { self.bridge },
            setAnnouncer: { self.announcer = $0 },
            currentAnnouncer: { self.announcer },
            sendPlaintext: { _ in },
            relayCallAdvertiseEnabled: { self.advertiseEnabled },
            reportedPhoneMeshPort: { self.reportedPort },
            deviceIdHex: { "721572C3" },
            displayName: { "EdgeLinkMacTests" },
            log: { _ in }
        )
    }

    // Phone reachable only through the cloud relay: the glue must build the
    // relay bridge and start the relay announcer so the phone registers this
    // Mac for relayCall.
    func testRelayTransportConfiguresBridgeAndAnnouncer() {
        LyraRelayTransportGlue.configureRelayBridge(transport: "relay", context: makeContext())

        XCTAssertNotNil(bridge)
        XCTAssertNotNil(announcer)
        XCTAssertEqual(bridge?.mesh.peerPort, 43495)
    }

    // LAN transport: no relay bridge, no relay announcer — the LAN
    // announcer/cast session own the path. Any previous relay announcer is
    // stopped first.
    func testLANTransportLeavesBridgeAndAnnouncerNil() {
        LyraRelayTransportGlue.configureRelayBridge(transport: "lan", context: makeContext())

        XCTAssertTrue(announcerStopped)
        XCTAssertNil(bridge)
        XCTAssertNil(announcer)
    }

    // The relayCall advertisement gate holds on the relay transport too: no
    // bridge announcer without the advertise flag, bridge still built.
    func testAnnouncerGatedOffWithoutAdvertise() {
        advertiseEnabled = false
        LyraRelayTransportGlue.configureRelayBridge(transport: "relay", context: makeContext())

        XCTAssertNotNil(bridge)
        XCTAssertNil(announcer)
    }

    // No reported phone mesh port yet: the announcer defers instead of
    // dialing blindly.
    func testAnnouncerDeferredWithoutReportedPort() {
        reportedPort = nil
        LyraRelayTransportGlue.configureRelayBridge(transport: "relay", context: makeContext())

        XCTAssertNotNil(bridge)
        XCTAssertNil(announcer)
    }

    // Transport flip relay→LAN: a cast session riding the (now dead) relay
    // bridge must be invalidated — its isChannelReady would lie otherwise.
    func testRelayRoutedCastSessionInvalidatedOnFlipToLAN() {
        hasCastSession = true
        castSessionIsRelayRouted = true

        LyraRelayTransportGlue.configureRelayBridge(transport: "lan", context: makeContext())

        XCTAssertTrue(castSessionInvalidated)
        XCTAssertNil(bridge)
    }

    // A LAN-routed cast session on a LAN transport is untouched: its mesh
    // socket is independent of the secure session.
    func testLANCastSessionSurvivesLANTransport() {
        hasCastSession = true
        castSessionIsRelayRouted = false

        LyraRelayTransportGlue.configureRelayBridge(transport: "lan", context: makeContext())

        XCTAssertFalse(castSessionInvalidated)
    }

    // A fresh relay secure session replaces the bridge object; a cast
    // session riding the old bridge's pipes is dead and must be invalidated
    // even though its transport label is unchanged.
    func testFreshRelaySessionInvalidatesExistingCastSession() {
        LyraRelayTransportGlue.configureRelayBridge(transport: "relay", context: makeContext())
        let firstBridge = bridge
        XCTAssertNotNil(firstBridge)

        hasCastSession = true
        castSessionIsRelayRouted = true
        LyraRelayTransportGlue.configureRelayBridge(transport: "relay", context: makeContext())

        XCTAssertTrue(castSessionInvalidated)
        XCTAssertNotNil(bridge)
        XCTAssertFalse(bridge === firstBridge)
    }

    // No cast session at all: invalidation must not fire (a spurious
    // channel-released would restart a mirror flow that never started).
    func testNoCastSessionSkipsInvalidation() {
        hasCastSession = false

        LyraRelayTransportGlue.configureRelayBridge(transport: "relay", context: makeContext())

        XCTAssertFalse(castSessionInvalidated)
    }

    // Re-arm path (the cast session finished while the bridge lived): the
    // announcer restarts on the existing bridge without rebuilding it.
    func testAnnouncerRearmUsesExistingBridge() {
        LyraRelayTransportGlue.configureRelayBridge(transport: "relay", context: makeContext())
        let configuredBridge = bridge
        XCTAssertNotNil(configuredBridge)
        announcer = nil

        LyraRelayTransportGlue.startRelayAnnouncerIfEnabled(context: makeContext())

        XCTAssertTrue(bridge === configuredBridge)
        XCTAssertNotNil(announcer)
    }
}
