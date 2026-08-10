import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import XCTest

// Recreates the live 2026-08-10 relay-channel clobber: the phone holds the
// Mac's relayPhoneCall dial channel pair after the call ends and releases it
// ~85s later; TeleService's onChannelRelease then clears deviceInRelay
// unconditionally — mid-NEXT-call — and that call never gets relay audio
// ("createRelayChannel...No relay service created", connectRelayAudio:false).
//
// The Mac-side fix: LyraRelayCallSession reports call end to
// LyraRelayCallDialer.callEnded(), which sends a logi disconnect so the
// phone releases the pair immediately, while no call is in flight.
//
// LyraRelayPhoneCallRole models the phone: dial handshake, TeleService's
// setDeviceInRelay-on-dial, the post-call release timer, and the
// unconditional deviceInRelay clear.
@MainActor
final class LyraRelayDialCallEndTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustDeviceUUID",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
    ]

    private static var portBlockIndex: UInt16 = 0
    private var meshPort: UInt16!

    private var savedValues: [String: Any?] = [:]
    private let macIdentity = P256.Signing.PrivateKey()
    private var phone: LyraPhoneServer?
    private var role: LyraRelayPhoneCallRole?
    private var dialer: LyraRelayCallDialer?

    override func setUp() {
        super.setUp()
        Self.portBlockIndex += 1
        meshPort = 32_101 + Self.portBlockIndex * 10
        continueAfterFailure = false
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.set(UUID().uuidString, forKey: "xiaomiTrustDeviceUUID")
        defaults.set(macIdentity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustIdentityPrivHex")
        defaults.set(macIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustIdentityPubB64")
        defaults.set(LyraPhoneIdentity.fixtureAccountPubB64, forKey: "xiaomiTrustPeerAccountPubB64")
        defaults.removeObject(forKey: "xiaomiTrustSessionKeyHex")
        defaults.removeObject(forKey: "xiaomiTrustTicketHex")
    }

    override func tearDown() {
        dialer?.stop()
        dialer = nil
        phone?.stop()
        phone = nil
        role = nil
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = savedValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedValues = [:]
        super.tearDown()
    }

    private func waitFor(
        _ description: String, timeout: TimeInterval = 15,
        _ predicate: @escaping () -> Bool
    ) {
        let expectation = XCTestExpectation(description: description)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            if predicate() {
                expectation.fulfill()
                timer.cancel()
            }
        }
        timer.resume()
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        timer.cancel()
        XCTAssertEqual(result, .completed, "timed out waiting for: \(description)")
    }

    private func startPhone() throws {
        let phone = LyraPhoneServer(identity: LyraPhoneIdentity.generate())
        let role = LyraRelayPhoneCallRole()
        role.releaseDelayAfterCallEnd = 0.5
        role.onEvent = { print("[relaydial-mock] \($0)") }
        phone.mesh.register(role)
        phone.relayCall.onEvent = { print("[relaycall-mock] \($0)") }
        self.phone = phone
        self.role = role
        try phone.start(port: meshPort)
    }

    private func dial(_ number: String) {
        if dialer == nil {
            dialer = LyraRelayCallDialer(
                deviceIdHexProvider: { "721572C3" },
                displayNameProvider: { "EdgeLinkMacTests" }
            )
        }
        dialer?.dial(number: number, host: "127.0.0.1", ports: [meshPort])
    }

    // The phone's return channel (createRelayChannel): TeleService dials the
    // Mac's relayCall service on the dialer's phys conn, keyed by the dial
    // session key.
    private func dialReturnChannel() throws {
        let phone = try XCTUnwrap(phone)
        let role = try XCTUnwrap(role)
        let sessionKey = try XCTUnwrap(role.sessionKey)
        phone.relayCall.hangup(server: phone.mesh)
        phone.relayCall.dial(server: phone.mesh, sessionKey: sessionKey)
        waitFor("return channel up") { phone.relayCall.state == .channelUp }
    }

    // Fixed behavior: call 1's end makes the Mac disconnect the dial channel
    // immediately; the pair release lands while idle, so call 2's relay
    // state survives past the stale-release window.
    func testCallEndDisconnectReleasesPairBeforeStaleTimer() throws {
        try startPhone()
        let role = try XCTUnwrap(role)
        let phone = try XCTUnwrap(phone)

        dial("800")
        waitFor("call 1 dialed") { role.dialRequests.count == 1 && self.dialer?.state == .done }
        try dialReturnChannel()
        role.noteCallActive()
        phone.relayCall.sendUpdateCallState(4)

        role.noteCallEnded()
        phone.relayCall.sendUpdateCallState(6)

        waitFor("call 1 pair released by the Mac's disconnect") {
            role.releases.contains { $0.reason == "mac_disconnect" }
        }
        // callEnded tears the dialer down 0.3s after the disconnect (flush
        // delay); a new dial before that would be wiped by the teardown.
        waitFor("dialer back to idle") { self.dialer?.state == .idle }
        // The post-call timer must find nothing left to release.
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(role.releases.count, 1)
        XCTAssertEqual(role.deviceInRelayClearedWhileCallActive, 0)

        dial("800")
        waitFor("call 2 dialed") { role.dialRequests.count == 2 && self.dialer?.state == .done }
        try dialReturnChannel()
        role.noteCallActive()
        phone.relayCall.sendUpdateCallState(4)
        waitFor("call 2 active acked") {
            phone.relayCall.lastRingResponse?.contains("\"code\":200") == true
        }

        // Outlive call 1's would-have-been stale release window.
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(role.deviceInRelayClearedWhileCallActive, 0,
                       "call 1's stale pair release must not clobber call 2")
        XCTAssertNotNil(role.deviceInRelay)
    }

    // The bug itself: call 1 ends but the Mac never learns (the callState
    // push is lost — live 2026-08-10 also showed a 408-timeout on one), so
    // the dial channel stays open. Call 2 dials and goes active inside the
    // stale-release window; the timer then releases call 1's pair and
    // TeleService clears deviceInRelay mid-call.
    func testStalePairReleaseMidNextCallClobbersDeviceInRelay() throws {
        try startPhone()
        let role = try XCTUnwrap(role)
        // Wide enough that call 2's dial completes inside the window (the
        // live window is ~85s; a re-dial takes ~0.7s on loopback).
        role.releaseDelayAfterCallEnd = 1.5

        dial("800")
        waitFor("call 1 dialed") { role.dialRequests.count == 1 && self.dialer?.state == .done }
        role.noteCallActive()

        // Call 1 ends phone-side; the call-end push never reaches the Mac.
        role.noteCallEnded()

        // Call 2 starts inside the stale-release window.
        dial("800")
        waitFor("call 2 dialed") { role.dialRequests.count == 2 && self.dialer?.state == .done }
        role.noteCallActive()

        waitFor("call 1 pair released by the post-call timer") {
            role.releases.contains { $0.reason == "post_call_idle" }
        }
        XCTAssertEqual(role.deviceInRelayClearedWhileCallActive, 1,
                       "the stale pair release must clobber call 2's deviceInRelay")
        XCTAssertNil(role.deviceInRelay)
    }
}
