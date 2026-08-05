import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import Network
import XCTest

// The phone's reverse sync task (service 00150323) dials whichever phys conn
// is up; with a mirror session live that is the cast trust session's socket.
// Live 2026-08-04: the session dropped that sync_info (stage != .syncAuth)
// and every sync task died with "kcp trans timeout", so the phone never
// learned our TrustedDeviceInfo. The dial must get the classic server
// sync_info reply and follow-up conn frames must reach the sync task server.
final class LyraCastTrustSyncTaskTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustDeviceUUID",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
    ]

    private var savedValues: [String: Any?] = [:]
    private let macIdentity = P256.Signing.PrivateKey()
    private var phone: LyraPhoneServer?
    private var session: LyraCastTrustSession?
    private var phoneSocket: LyraMeshSocket?

    override func setUp() {
        super.setUp()
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
        session?.cancel()
        session = nil
        phoneSocket?.stop()
        phoneSocket = nil
        phone?.stop()
        phone = nil
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = savedValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    private func waitFor(
        _ description: String, timeout: TimeInterval = 10,
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

    func testSyncServiceDialOnCastTrustSocketGetsSyncInfoReply() throws {
        let trustManager = MacTrustManager()
        let session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", 9)],
            deviceIdHex: "721572C3",
            displayName: "EdgeLinkMacTests",
            trustManager: trustManager
        )
        self.session = session
        session.start()
        waitFor("cast trust socket bound") { session.meshSocketBoundPort != nil }
        let sessionPort = try XCTUnwrap(session.meshSocketBoundPort)

        let phoneSocket = LyraMeshSocket()
        self.phoneSocket = phoneSocket
        var replyLogiConns: [LogiConnFrame] = []
        let replyLock = NSLock()
        phoneSocket.onFrame = { frame, _, _ in
            guard let miFrame = MiConnectFrame(parsing: frame.payload) else { return }
            replyLock.lock()
            replyLogiConns.append(contentsOf: miFrame.logiConnFrames)
            replyLock.unlock()
        }
        try phoneSocket.start()

        // The phone's classic sync-task dial: plaintext logi sync_info for
        // service 00150323 on a fresh logi conn.
        let connId: UInt32 = 0x0BAD_F00D
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data(LyraSyncTaskServer.syncServiceName.utf8), to: &syncInfo
        )
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let dial = LogiConnFrame(
            logiConnId: connId, localNetId: 1, remoteNetId: 0, inner: inner.serialized()
        )
        let miDial = MiConnectFrame(version: 0, logiConnFrames: [dial])
        try phoneSocket.send(
            frame: LyraMeshPack.Frame(packType: 2, payload: miDial.serialized()),
            to: "127.0.0.1", port: sessionPort
        )

        waitFor("server sync_info reply") {
            replyLock.lock()
            defer { replyLock.unlock() }
            return replyLogiConns.contains { $0.logiConnId == connId }
        }

        replyLock.lock()
        let replyConn = try XCTUnwrap(replyLogiConns.first { $0.logiConnId == connId })
        replyLock.unlock()
        XCTAssertEqual(replyConn.remoteNetId, 1)
        let replyInner = try XCTUnwrap(LogiConnInnerFrame(parsing: replyConn.inner))
        guard case let .syncInfo(replySyncInfo) = replyInner.payload else {
            XCTFail("expected sync_info reply payload")
            return
        }
        let fields = try LyraProtoReader.readFields(from: replySyncInfo)
        let protocolVersion = fields.first { $0.number == 1 && $0.wireType == 0 }?.varintValue
        XCTAssertEqual(protocolVersion, 10000)
        XCTAssertNotNil(fields.first { $0.number == 5 && $0.wireType == 2 })
    }

    // Live 2026-08-05: TeleService's relayCall channel dial reuses the live
    // mirror phys conn the same way the sync task does — the cast trust
    // session must adopt it or channel creation dies at kAuthClient and every
    // call-state update falls to a 408 timeout.
    // Live 2026-08-05: TeleService's relayCall channel dial reuses the live
    // mirror phys conn the same way the sync task does — the cast trust
    // session must adopt it or channel creation dies at kAuthClient and every
    // call-state update falls to a 408 timeout.
    func testRelayCallDialOnCastTrustSocketGetsSyncInfoReply() throws {
        let phoneSocket = LyraMeshSocket()
        self.phoneSocket = phoneSocket
        var replyLogiConns: [LogiConnFrame] = []
        let replyLock = NSLock()
        phoneSocket.onFrame = { frame, _, _ in
            guard let miFrame = MiConnectFrame(parsing: frame.payload) else { return }
            replyLock.lock()
            replyLogiConns.append(contentsOf: miFrame.logiConnFrames)
            replyLock.unlock()
        }
        try phoneSocket.start()
        waitFor("phone socket bound") { phoneSocket.boundPort != nil }
        let phonePort = try XCTUnwrap(phoneSocket.boundPort)

        // Point the session's endpoint at the phone socket so the adopt reply
        // (sent via the session's own send path) lands back on it.
        let trustManager = MacTrustManager()
        let session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", phonePort)],
            deviceIdHex: "721572C3",
            displayName: "EdgeLinkMacTests",
            trustManager: trustManager
        )
        self.session = session
        session.start()
        waitFor("cast trust socket bound") { session.meshSocketBoundPort != nil }
        let sessionPort = try XCTUnwrap(session.meshSocketBoundPort)

        let connId: UInt32 = 0x0BAD_BEEF
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 10000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 16, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(
            4, value: Data(LyraRelayCallSession.serviceName.utf8), to: &syncInfo
        )
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let dial = LogiConnFrame(
            logiConnId: connId, localNetId: 1, remoteNetId: 0, inner: inner.serialized()
        )
        let miDial = MiConnectFrame(version: 0, logiConnFrames: [dial])
        try phoneSocket.send(
            frame: LyraMeshPack.Frame(packType: 2, payload: miDial.serialized()),
            to: "127.0.0.1", port: sessionPort
        )

        waitFor("relayCall server sync_info reply") {
            replyLock.lock()
            defer { replyLock.unlock() }
            return replyLogiConns.contains { $0.logiConnId == connId }
        }
        replyLock.lock()
        let replyConn = try XCTUnwrap(replyLogiConns.first { $0.logiConnId == connId })
        replyLock.unlock()
        let replyInner = try XCTUnwrap(LogiConnInnerFrame(parsing: replyConn.inner))
        guard case let .syncInfo(replySyncInfo) = replyInner.payload else {
            XCTFail("expected sync_info reply payload")
            return
        }
        let fields = try LyraProtoReader.readFields(from: replySyncInfo)
        XCTAssertEqual(fields.first { $0.number == 1 && $0.wireType == 0 }?.varintValue, 10000)
        XCTAssertTrue(LyraRelayCallSession.activeRelaySession?.handles(logiConn: dial) == true)
    }

    // Full classic sync-task dial (plaintext sync_info → handshake →
    // REQUEST → payload push) through the cast trust socket, driven by the
    // mock phone's sync task role — the phone reuses live phys conns for the
    // dial, so the cast session must serve the whole exchange.
    func testClassicSyncTaskDialCompletesOnCastTrustSocket() throws {
        let trustManager = MacTrustManager()
        let session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", 9)],
            deviceIdHex: "721572C3",
            displayName: "EdgeLinkMacTests",
            trustManager: trustManager
        )
        self.session = session
        session.start()
        waitFor("cast trust socket bound") { session.meshSocketBoundPort != nil }
        let sessionPort = try XCTUnwrap(session.meshSocketBoundPort)

        let identity = LyraPhoneIdentity.generate()
        let phone = LyraPhoneServer(identity: identity)
        self.phone = phone
        UserDefaults.standard.set(identity.identityPubB64, forKey: "xiaomiTrustPeerIdentityPubB64")
        try phone.start(port: 0)

        phone.syncTask.dialClassic(server: phone.mesh, host: "127.0.0.1", port: sessionPort)

        waitFor("sync task established over cast trust socket") {
            phone.syncTask.state == .established
        }
        waitFor("Mac payload reply parsed") {
            phone.syncTask.peerDevice != nil
        }
        XCTAssertEqual(phone.syncTask.peerDevice?.shortDeviceIdHex, "721572C3")
    }
}
