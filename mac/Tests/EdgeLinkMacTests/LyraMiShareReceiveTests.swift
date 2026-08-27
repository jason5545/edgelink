import CryptoKit
import EdgeLinkKit
import Foundation
import LyraServerKit
import XCTest

// Phone→Mac MiShare receive: the phone's gallery share dials the Mac's
// miLyraShareTransfer service (sync_info → P256 upgrade → encrypted conn
// request → responseAck → requestOfPeerPort → responseOfPeerPort).
//
// Live 2026-08-21: the phone's score-based phys-conn reuse dialed the service
// on the MAC's announcer conn; the announcer had no route for it
// (announcer_stray_conn) and the phone's 15s kcp timeout surfaced as
// 「連線失敗」. The first test is the baseline dial on the responder's own
// socket; the second recreates the announcer-conn dial and times out without
// the responder-adoption fix.
//
// Live 2026-08-27: the real phone's conn request carries a trailing
// .authHandshake payload after the .request in the same inner frame, which
// last-payload-wins parsing dropped — the Mac never answered and the phone
// showed 傳送失敗 again. The sender role appends that block by default.
// Same day, second root cause: the phone's conn request carries a tunnel
// profile (private_data field 5), and its CheckTunnelCapacity then requires
// the response to carry TunnelCapacity — the responder's empty response was
// rejected (15s timeout, sync_auth 15006, then 15071 "logical conn secret
// decrypt failed" while we probed a wrong-direction key). The sender role
// now sends the captured profile block and rejects capacity-less responses,
// so these tests fail against an empty-body responder.
//
// Same day, third root cause: with a cast trust session live, the phone's
// score-based phys-conn reuse dials the service on the CAST TRUST socket,
// whose sync_info dispatch swallowed it (stage != .syncAuth). The session
// now forwards the dial to the responder for adoption; sends without a
// reply context (responseOfPeerPort) ride the session's inbound connection.
//
// The remaining tests drive the actual file transfer past channel
// negotiation: a small inline file (no stream), a chunked stream, and a 10GB
// stream to prove very large files (update packages) survive the express
// link. Receives are redirected to a temp directory via
// LyraMeshResponder.miShareDownloadDirectoryOverride.
final class LyraMiShareReceiveTests: XCTestCase {
    private static let defaultsKeys = [
        "xiaomiTrustIdentityPrivHex",
        "xiaomiTrustIdentityPubB64",
        "xiaomiTrustPeerIdentityPubB64",
        "xiaomiTrustPeerAccountPubB64",
        "xiaomiTrustDeviceUUID",
        "xiaomiTrustSessionKeyHex",
        "xiaomiTrustTicketHex",
        "xiaomiTrustUidHashB64",
        "lanLastPhoneIP",
    ]

    private var savedValues: [String: Any?] = [:]
    private let macIdentity = P256.Signing.PrivateKey()
    private var phone: LyraPhoneServer?
    private var responderSocket: LyraMeshSocket?
    private var responder: LyraMeshResponder?
    private var announcer: LyraMeshAnnouncer?
    private var castSession: LyraCastTrustSession?
    private var senders: [LyraMiShareSenderRole] = []
    private var downloadDirs: [URL] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.set(macIdentity.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                     forKey: "xiaomiTrustIdentityPrivHex")
        defaults.set(macIdentity.publicKey.x963Representation.base64EncodedString(),
                     forKey: "xiaomiTrustIdentityPubB64")
        defaults.set(UUID().uuidString, forKey: "xiaomiTrustDeviceUUID")
        defaults.removeObject(forKey: "xiaomiTrustSessionKeyHex")
        defaults.removeObject(forKey: "xiaomiTrustTicketHex")
        // Endpoint learning must not be gated by a pinned LAN IP from the
        // developer machine's real defaults (loopback host is 127.0.0.1).
        defaults.removeObject(forKey: "lanLastPhoneIP")
        MiTrustTicketStore.lastAuthSessionKeyData = nil
    }

    override func tearDown() {
        for sender in senders {
            sender.stopTransfer()
        }
        senders = []
        castSession?.cancel()
        castSession = nil
        announcer?.stop()
        announcer = nil
        responder = nil
        responderSocket?.stop()
        responderSocket = nil
        phone?.stop()
        phone = nil
        LyraMeshResponder.miShareDownloadDirectoryOverride = nil
        for dir in downloadDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        downloadDirs = []
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeys {
            if let value = savedValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        MiTrustTicketStore.lastAuthSessionKeyData = nil
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

    private func startResponder() throws -> UInt16 {
        let socket = LyraMeshSocket()
        let responder = LyraMeshResponder(
            socket: socket,
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        try socket.start()
        responder.attach()
        self.responderSocket = socket
        self.responder = responder
        waitFor("responder listener ready") { socket.boundPort != nil }
        return try XCTUnwrap(socket.boundPort)
    }

    private func makePhone() throws -> LyraPhoneServer {
        let identity = LyraPhoneIdentity.generate()
        let phone = LyraPhoneServer(identity: identity)
        UserDefaults.standard.set(
            identity.identityPubB64, forKey: "xiaomiTrustPeerIdentityPubB64"
        )
        UserDefaults.standard.set(
            identity.accountPubB64, forKey: "xiaomiTrustPeerAccountPubB64"
        )
        try phone.start(port: 0)
        waitFor("phone listener ready") { phone.boundPort != nil }
        return phone
    }

    // Redirects receives into a fresh temp directory and returns it.
    private func makeDownloadDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mishare-tests-\(UUID().uuidString)", isDirectory: true)
        LyraMeshResponder.miShareDownloadDirectoryOverride = url
        downloadDirs.append(url)
        return url
    }

    private func makeSender(phone: LyraPhoneServer) -> LyraMiShareSenderRole {
        let sender = LyraMiShareSenderRole(identity: phone.identity)
        phone.mesh.register(sender)
        senders.append(sender)
        return sender
    }

    // Baseline: the dial lands on the responder's published mesh socket (the
    // phone's own mesh conn winning the score). Validates the mock speaks the
    // receive flow the responder expects.
    func testMiShareReceiveOverMeshResponderConn() throws {
        let responderPort = try startResponder()
        let phone = try makePhone()
        self.phone = phone

        let sender = makeSender(phone: phone)
        sender.dial(server: phone.mesh, toHost: "127.0.0.1", port: responderPort)

        waitFor("responseOfPeerPort received") { sender.receivedChannelPort != nil }
        XCTAssertEqual(sender.state, .channelReady)
    }

    // Regression: the phone's score-based reuse dials miLyraShareTransfer on
    // the MAC's announcer phys conn. Pre-fix the sync_info fell into
    // announcer_stray_conn and the phone timed out (live 2026-08-21
    // 「連線失敗」); the responder must adopt the conn off the announcer's
    // socket, like the 2026-08-12 mitrustservice adoption.
    func testMiShareReceiveWhenPhoneDialsOnAnnouncerConn() throws {
        _ = try startResponder()
        let phone = try makePhone()
        self.phone = phone

        let announcer = LyraMeshAnnouncer(
            deviceIdHexProvider: { "721572C3" },
            displayNameProvider: { "MacBook Pro" }
        )
        self.announcer = announcer
        announcer.start(host: "127.0.0.1", port: try XCTUnwrap(phone.boundPort))
        // The phone learned the announcer's endpoint from its phys sync;
        // sendToPeer now rides the announcer conn.
        waitFor("announcer endpoint learned by phone") {
            !phone.mesh.peer.endpointDescription.isEmpty
        }

        let sender = makeSender(phone: phone)
        sender.dial(server: phone.mesh)

        waitFor("responseOfPeerPort received over announcer conn") {
            sender.receivedChannelPort != nil
        }
        XCTAssertEqual(sender.state, .channelReady)
    }

    // Regression: the real phone's encrypted conn request carries TWO
    // payload fields — .request plus a trailing .authHandshake block. Live
    // 2026-08-27: the responder's last-payload-wins parse dropped the
    // request, never answered, and the phone's 15s kcp timeout surfaced as
    // 傳送失敗. The sender role appends the block by default, so the
    // baseline dial above recreates the phone's frame; this test pins the
    // full flow (through file delivery) on that frame shape.
    func testMiShareReceiveWhenConnRequestCarriesAuthHandshakeTrailer() throws {
        let responderPort = try startResponder()
        let phone = try makePhone()
        self.phone = phone
        let downloadDir = makeDownloadDir()

        var payload = Data(count: 32 * 1024)
        payload.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
        }

        let sender = makeSender(phone: phone)
        XCTAssertTrue(sender.appendsAuthHandshakeToConnRequest)
        sender.dial(server: phone.mesh, toHost: "127.0.0.1", port: responderPort)
        waitFor("channel ready") { sender.state == .channelReady }

        sender.sendFile(name: "trailer.bin", mode: .inlineData(payload), host: "127.0.0.1")
        waitFor("transfer done") { sender.state == .transferDone }
        let fileURL = downloadDir.appendingPathComponent("trailer.bin")
        waitFor("file written") { (try? Data(contentsOf: fileURL)) == payload }
    }

    // Legacy frame shape: a single .request payload (pre-2026-08-27 mock and
    // older phone builds) must keep working alongside the dual-payload one.
    func testMiShareReceiveWithLegacySinglePayloadConnRequest() throws {
        let responderPort = try startResponder()
        let phone = try makePhone()
        self.phone = phone

        let sender = makeSender(phone: phone)
        sender.appendsAuthHandshakeToConnRequest = false
        sender.dial(server: phone.mesh, toHost: "127.0.0.1", port: responderPort)

        waitFor("responseOfPeerPort received") { sender.receivedChannelPort != nil }
        XCTAssertEqual(sender.state, .channelReady)
    }

    // Regression: with a cast trust session live (the mirror trust flow
    // starts one on session connect), the phone's score-based phys-conn
    // reuse dials miLyraShareTransfer on the CAST TRUST socket. Live
    // 2026-08-27: the session swallowed the sync_info at stage != .syncAuth
    // (trust_sync_info_ignored) and the phone hit its 15s kcp timeout
    // (33006, 連線失敗). The session must forward the dial to the responder
    // for adoption, like the announcer socket does since 2026-08-21.
    func testMiShareReceiveWhenPhoneDialsOnCastTrustSocket() throws {
        _ = try startResponder()
        let phone = try makePhone()
        self.phone = phone
        let downloadDir = makeDownloadDir()

        let session = LyraCastTrustSession(
            endpoints: [("127.0.0.1", 9)],
            deviceIdHex: "721572C3",
            displayName: "EdgeLinkMacTests",
            trustManager: MacTrustManager()
        )
        castSession = session
        session.start()
        waitFor("cast trust socket bound") { session.meshSocketBoundPort != nil }
        let castPort = try XCTUnwrap(session.meshSocketBoundPort)

        var payload = Data(count: 24 * 1024)
        payload.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
        }

        let sender = makeSender(phone: phone)
        sender.dial(server: phone.mesh, toHost: "127.0.0.1", port: castPort)
        waitFor("channel ready via cast trust socket") { sender.state == .channelReady }

        sender.sendFile(name: "cast-conn.bin", mode: .inlineData(payload), host: "127.0.0.1")
        waitFor("transfer done") { sender.state == .transferDone }
        let fileURL = downloadDir.appendingPathComponent("cast-conn.bin")
        waitFor("file written") { (try? Data(contentsOf: fileURL)) == payload }
    }

    // Small file: the bytes ride file-message field 4 and the responder
    // writes them without a stream.
    func testMiShareReceiveInlineSmallFile() throws {
        let responderPort = try startResponder()
        let phone = try makePhone()
        self.phone = phone
        let downloadDir = makeDownloadDir()

        var payload = Data(count: 48 * 1024)
        payload.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
        }

        let sender = makeSender(phone: phone)
        sender.dial(server: phone.mesh, toHost: "127.0.0.1", port: responderPort)
        waitFor("channel ready") { sender.state == .channelReady }

        sender.sendFile(name: "small.bin", mode: .inlineData(payload), host: "127.0.0.1")
        waitFor("inline transfer done") { sender.state == .transferDone }

        let fileURL = downloadDir.appendingPathComponent("small.bin")
        waitFor("inline file written") {
            (try? Data(contentsOf: fileURL)) == payload
        }
        XCTAssertEqual(sender.transferredBytes, Int64(payload.count))
    }

    // Streamed file: chunks ride the express TCP link.
    func testMiShareReceiveStreamedFile() throws {
        let responderPort = try startResponder()
        let phone = try makePhone()
        self.phone = phone
        let downloadDir = makeDownloadDir()

        let chunkSize = 64 * 1024
        let totalSize: Int64 = 8 * 1024 * 1024
        let template = Self.makePatternTemplate(chunkSize)

        let sender = makeSender(phone: phone)
        sender.dial(server: phone.mesh, toHost: "127.0.0.1", port: responderPort)
        waitFor("channel ready") { sender.state == .channelReady }

        sender.sendFile(
            name: "medium.bin",
            mode: .stream(size: totalSize, chunkSize: chunkSize) { offset, count in
                Self.patternChunk(template: template, chunkSize: chunkSize, offset: offset, count: count)
            },
            host: "127.0.0.1"
        )
        waitFor("stream transfer done", timeout: 120) { sender.state == .transferDone }
        XCTAssertEqual(sender.transferredBytes, totalSize)

        let fileURL = downloadDir.appendingPathComponent("medium.bin")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.size] as? Int64, totalSize)
        try Self.verifyPattern(
            fileURL: fileURL, template: template, chunkSize: chunkSize,
            chunkIndices: [0, 1, 63, 127]
        )
    }

    // Very large file: 10GB (an update package) through the express link.
    // Exercises 64-bit stream offsets past the 4GB boundary; the chunk source
    // generates data on demand so the test never holds the file in memory.
    func testMiShareReceiveVeryLargeStream() throws {
        let responderPort = try startResponder()
        let phone = try makePhone()
        self.phone = phone
        let downloadDir = makeDownloadDir()

        let chunkSize = 1024 * 1024
        let totalSize: Int64 = 10 * 1024 * 1024 * 1024
        let template = Self.makePatternTemplate(chunkSize)

        let sender = makeSender(phone: phone)
        sender.dial(server: phone.mesh, toHost: "127.0.0.1", port: responderPort)
        waitFor("channel ready") { sender.state == .channelReady }

        sender.sendFile(
            name: "huge.bin",
            mode: .stream(size: totalSize, chunkSize: chunkSize) { offset, count in
                Self.patternChunk(template: template, chunkSize: chunkSize, offset: offset, count: count)
            },
            host: "127.0.0.1"
        )
        waitFor("10GB stream transfer done", timeout: 900) { sender.state == .transferDone }
        XCTAssertEqual(sender.transferredBytes, totalSize)

        let fileURL = downloadDir.appendingPathComponent("huge.bin")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.size] as? Int64, totalSize)
        // Chunk 4096 starts just past the 32-bit 4GB boundary.
        try Self.verifyPattern(
            fileURL: fileURL, template: template, chunkSize: chunkSize,
            chunkIndices: [0, 4095, 4096, 4097, 7000, 10239]
        )
    }

    // MARK: - Pattern helpers

    // Deterministic per-chunk content: first 8 bytes are the chunk index
    // (big-endian), the rest a position-derived pattern. The index header
    // catches seek/offset bugs on the receive side even at multi-GB offsets.
    private static func patternChunk(template: Data, chunkSize: Int, offset: Int64, count: Int) -> Data {
        var chunk = Data(template.prefix(count))
        let index = (UInt64(offset) / UInt64(chunkSize)).bigEndian
        withUnsafeBytes(of: index) { chunk.replaceSubrange(0..<8, with: $0) }
        return chunk
    }

    private static func makePatternTemplate(_ size: Int) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<size {
                base[index] = UInt8(truncatingIfNeeded: (index &* 2_654_435_761) >> 8)
            }
        }
        return data
    }

    private static func verifyPattern(
        fileURL: URL, template: Data, chunkSize: Int, chunkIndices: [UInt64]
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        for index in chunkIndices {
            try handle.seek(toOffset: index * UInt64(chunkSize))
            let header = try handle.read(upToCount: 8) ?? Data()
            let expectedIndex = index.bigEndian
            let expectedHeader = withUnsafeBytes(of: expectedIndex) { Data($0) }
            XCTAssertEqual(header, expectedHeader, "chunk \(index) header mismatch")
            let sample = try handle.read(upToCount: 64) ?? Data()
            XCTAssertEqual(
                sample, Data(template[8..<72]),
                "chunk \(index) body mismatch"
            )
        }
    }
}
