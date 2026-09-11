import EdgeLinkKit
import Foundation
import Network
import XCTest

// Pins the mesh-contact reachability signal that closes the mDNS-lag hole
// from the 2026-09-11 Tailscale outage: with the exit node hijacking LAN
// routes, the phone's mDNS advert refresh lagged, hasLivePhonePeer went
// stale, and the mirror flow picked the relay transport even though LAN
// mesh traffic was flowing the whole time. The signal must come ONLY from
// genuine LAN sources — relay-fed loopback frames (127.0.0.1) and tailnet
// peers must never count, or the flow would flip to LAN into a black hole.
final class LyraLANReachabilityTests: XCTestCase {
    private var sockets: [LyraMeshSocket] = []

    override func tearDown() {
        for socket in sockets { socket.stop() }
        sockets = []
        UserDefaults.standard.removeObject(forKey: "xiaomiMiShareMeshPort")
        super.tearDown()
    }

    private func en0Interface() throws -> LANEgressInterface.LocalInterface {
        guard let en0 = LANEgressInterface.currentLocalInterfaces().first(where: { $0.name == "en0" }) else {
            throw XCTSkip("en0 has no IPv4 on this machine")
        }
        return en0
    }

    private func makeSocket() throws -> LyraMeshSocket {
        let socket = LyraMeshSocket()
        sockets.append(socket)
        try socket.start()
        let deadline = Date().addingTimeInterval(5)
        while socket.boundPort == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return socket
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 8, _ predicate: @escaping () -> Bool) {
        let expectation = XCTestExpectation(description: description)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
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

    // A frame from a LAN-interface address counts as phone contact; a frame
    // from loopback (the relay bridge's source) must not.
    func testResponderCountsOnlyLANSourceAsPhoneContact() throws {
        let en0 = try en0Interface()
        let responderSocket = try makeSocket()
        let responder = LyraMeshResponder(
            socket: responderSocket,
            deviceIdHexProvider: { "AB12CD34" },
            displayNameProvider: { "Reach Test Mac" }
        )
        responder.attach()
        let responderPort = try XCTUnwrap(responderSocket.boundPort)
        let phone = try makeSocket()

        XCTAssertEqual(responder.lastLANPhoneContactAt, .distantPast)
        try phone.send(
            frame: LyraMeshPack.Frame(packType: 5, payload: Data("loopback".utf8)),
            to: "127.0.0.1",
            port: responderPort
        )
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(
            responder.lastLANPhoneContactAt, .distantPast,
            "relay-fed loopback traffic must never prove LAN reachability"
        )

        // Hairpin through en0: the frame's source is the Mac's own LAN
        // address, exactly what a phone on the same subnet looks like.
        try phone.send(
            frame: LyraMeshPack.Frame(packType: 5, payload: Data("lan".utf8)),
            to: en0.address,
            port: responderPort
        )
        waitFor("LAN-source frame counted as phone contact") {
            responder.lastLANPhoneContactAt != .distantPast
        }
    }

    // Discovery level: actual LAN mesh traffic flips reachability even with
    // zero mDNS sightings — the exact gap from the 2026-09-11 mirror attempt.
    func testDiscoveryMeshContactMarksLANReachable() throws {
        let en0 = try en0Interface()
        let meshPort = UInt16.random(in: 45_000...59_000)
        UserDefaults.standard.set(Int(meshPort), forKey: "xiaomiMiShareMeshPort")

        let discovery = XiaomiMiShareDiscovery()
        XCTAssertFalse(discovery.hasRecentPhoneMeshContact(), "no responder yet → no contact")
        discovery.start(identitySeed: "lan-reach-test", displayName: "Reach Test")
        defer { discovery.stop() }
        XCTAssertFalse(discovery.hasRecentPhoneMeshContact(), "nothing heard yet")

        let phone = try makeSocket()
        let frame = LyraMeshPack.Frame(packType: 5, payload: Data("lan".utf8))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !discovery.hasRecentPhoneMeshContact() {
            try? phone.send(frame: frame, to: en0.address, port: meshPort)
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(discovery.hasRecentPhoneMeshContact(), "LAN mesh traffic must count as contact")
        XCTAssertTrue(discovery.isLANPhoneReachable(), "mesh contact alone must satisfy reachability")
    }
}
