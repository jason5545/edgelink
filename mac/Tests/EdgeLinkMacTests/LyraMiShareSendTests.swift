import EdgeLinkKit
import Foundation
import LyraServerKit
import XCTest

// Mac→phone MiShare send: the production LyraFileSendSession (phys sync →
// cookie → sync_info → P256 family-5 upgrade → encrypted conn request →
// responseAck → packType-5 requestOfPeerPort → channel negotiation → express
// handshake → file request → AES-GCM streamlets over the express TCP link →
// complete/done) against the mock phone's LyraMiShareReceiverRole — the
// reverse direction of LyraMiShareReceiveTests, closing the 互傳 loop.
//
// Sizes: a small file (two 64KB chunks), two files in one job (multi-stream
// sequencing + per-stream offset reset), and a sparse 10GB update-package-
// style file whose chunks are verified on the fly (APFS sparse regions read
// back as zeros, so the test never holds the file in memory or on disk).
final class LyraMiShareSendTests: XCTestCase {
    // Thread-safe status collector for the session's onStatus callbacks.
    private final class StatusBox {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }

    private var phone: LyraPhoneServer?
    private var receiver: LyraMiShareReceiverRole?
    private var sessions: [LyraFileSendSession] = []
    private var tempDirs: [URL] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        for session in sessions {
            session.cancel()
        }
        sessions = []
        receiver = nil
        phone?.stop()
        phone = nil
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
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

    private func makePhone() throws -> LyraPhoneServer {
        let identity = LyraPhoneIdentity.generate()
        let phone = LyraPhoneServer(identity: identity)
        let receiver = LyraMiShareReceiverRole(identity: identity)
        receiver.onEvent = { print("[mishare-receiver] \($0)") }
        phone.mesh.register(receiver)
        try phone.start(port: 0)
        self.phone = phone
        self.receiver = receiver
        waitFor("phone listener ready") { phone.boundPort != nil }
        return phone
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mishare-send-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func writeFile(name: String, data: Data) throws -> URL {
        let url = makeTempDir().appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @discardableResult
    private func startSession(phone: LyraPhoneServer, files: [URL], statuses: StatusBox) -> LyraFileSendSession {
        let session = LyraFileSendSession(
            host: "127.0.0.1",
            port: phone.boundPort ?? 0,
            deviceIdHex: "721572C3",
            displayName: "MacBook Pro",
            files: LyraFileSendSession.makeFiles(from: files)
        )
        session.onStatus = { statuses.append($0); print("[mishare-send] \($0)") }
        sessions.append(session)
        session.start()
        return session
    }

    // Small file: two 64KB express chunks + EOF; every chunk's bytes are
    // compared against the source file at the stream offset it claims.
    func testMiShareSendSmallFile() throws {
        let phone = try makePhone()
        let receiver = try XCTUnwrap(receiver)

        var fileData = Data(count: 100_000)
        fileData.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
        }
        let fileURL = try writeFile(name: "small.bin", data: fileData)

        receiver.chunkValidator = { _, offset, chunk in
            chunk == fileData.subdata(in: Int(offset)..<Int(offset) + chunk.count)
        }

        let statuses = StatusBox()
        startSession(phone: phone, files: [fileURL], statuses: statuses)

        waitFor("receiver transfer done", timeout: 60) { receiver.state == .transferDone }
        XCTAssertEqual(receiver.receivedBytes, Int64(fileData.count))
        XCTAssertEqual(
            receiver.receivedFiles,
            [LyraMiShareReceiverRole.ReceivedFile(streamId: 1, name: "small.bin", bytes: Int64(fileData.count))]
        )
        waitFor("session reports done") {
            statuses.values.contains { $0.contains("已傳送") }
        }
    }

    // Two files in one job: the send session sequences them as streamIds 1
    // and 2, and each stream's offsets restart at 0 (the receiver rejects an
    // offset that doesn't match the running count).
    func testMiShareSendMultipleFiles() throws {
        let phone = try makePhone()
        let receiver = try XCTUnwrap(receiver)

        var firstData = Data(count: 100_000)
        firstData.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
        }
        var secondData = Data(count: 3 * 1024 * 1024)
        secondData.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
        }
        let firstURL = try writeFile(name: "first.bin", data: firstData)
        let secondURL = try writeFile(name: "second.bin", data: secondData)

        receiver.chunkValidator = { streamId, offset, chunk in
            let source = streamId == 1 ? firstData : secondData
            return chunk == source.subdata(in: Int(offset)..<Int(offset) + chunk.count)
        }

        let statuses = StatusBox()
        startSession(phone: phone, files: [firstURL, secondURL], statuses: statuses)

        waitFor("receiver transfer done", timeout: 120) { receiver.state == .transferDone }
        XCTAssertEqual(
            receiver.declaredFiles.map { $0.name }.sorted(),
            ["first.bin", "second.bin"]
        )
        XCTAssertEqual(receiver.receivedFiles.count, 2)
        XCTAssertEqual(receiver.receivedFiles.first?.name, "first.bin")
        XCTAssertEqual(receiver.receivedFiles.first?.bytes, Int64(firstData.count))
        XCTAssertEqual(receiver.receivedFiles.last?.name, "second.bin")
        XCTAssertEqual(receiver.receivedFiles.last?.bytes, Int64(secondData.count))
        XCTAssertEqual(receiver.receivedBytes, Int64(firstData.count + secondData.count))
        waitFor("session reports done") {
            statuses.values.contains { $0.contains("已傳送 2") }
        }
    }

    // Very large file: a 10GB update package. The file is APFS-sparse — only
    // three 1MB pattern segments are physically written (file start, the 32-
    // bit 4GB boundary, file end); everything else reads back as zeros. The
    // chunk validator recomputes the expected bytes per chunk, so 64-bit
    // stream offsets past 4GB are verified without holding the file anywhere.
    //
    // Regression coverage: the send session's 30s liveness watchdog used to
    // count only inbound traffic, killing any one-way stream longer than 30s
    // mid-transfer; outgoing chunks now mark progress too.
    func testMiShareSendVeryLargeFile() throws {
        let phone = try makePhone()
        let receiver = try XCTUnwrap(receiver)

        let totalSize: Int64 = 10 * 1024 * 1024 * 1024
        let segments: [(offset: Int64, data: Data)] = [
            (offset: 0, data: Self.makePattern(1 << 20, seed: 0xA5)),
            (offset: (Int64(1) << 32) - 32 * 1024, data: Self.makePattern(1 << 20, seed: 0x5A)),
            (offset: totalSize - (1 << 20), data: Self.makePattern(1 << 20, seed: 0x11)),
        ]
        let fileURL = try makeSparseFile(name: "huge.bin", size: totalSize, segments: segments)

        var lastLoggedGB: Int64 = -1
        receiver.chunkValidator = { _, offset, chunk in
            let gb = offset / (1 << 30)
            if gb != lastLoggedGB {
                lastLoggedGB = gb
                print("[mishare-receiver] 10GB progress: \(gb) GiB")
            }
            return chunk == Self.expectedChunk(segments: segments, offset: offset, count: chunk.count)
        }

        let statuses = StatusBox()
        startSession(phone: phone, files: [fileURL], statuses: statuses)

        waitFor("10GB transfer done", timeout: 900) { receiver.state == .transferDone }
        XCTAssertEqual(receiver.receivedBytes, totalSize)
        XCTAssertEqual(
            receiver.receivedFiles,
            [LyraMiShareReceiverRole.ReceivedFile(streamId: 1, name: "huge.bin", bytes: totalSize)]
        )
        waitFor("session reports done") {
            statuses.values.contains { $0.contains("已傳送") }
        }
    }

    // MARK: - Sparse file + pattern helpers

    private func makeSparseFile(
        name: String, size: Int64, segments: [(offset: Int64, data: Data)]
    ) throws -> URL {
        let url = makeTempDir().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        for segment in segments {
            try handle.seek(toOffset: UInt64(segment.offset))
            try handle.write(contentsOf: segment.data)
        }
        try handle.close()
        return url
    }

    private static func makePattern(_ size: Int, seed: UInt8) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<size {
                base[index] = UInt8(truncatingIfNeeded: (index &* 2_654_435_761) >> 8) ^ seed
            }
        }
        return data
    }

    private static func expectedChunk(
        segments: [(offset: Int64, data: Data)], offset: Int64, count: Int
    ) -> Data {
        var chunk = Data(count: count)
        for segment in segments {
            let start = max(offset, segment.offset)
            let end = min(offset + Int64(count), segment.offset + Int64(segment.data.count))
            guard start < end else { continue }
            chunk.replaceSubrange(
                Int(start - offset)..<Int(end - offset),
                with: segment.data[Int(start - segment.offset)..<Int(end - segment.offset)]
            )
        }
        return chunk
    }
}
