import EdgeLinkKit
import Foundation
import Network
import XCTest

// The phone's KCP input drops over-MTU UDP datagrams (live 2026-08-05: our
// ~2 KB sync replies never surfaced phone-side while 442-byte announces
// flowed), so the socket must split large frames into <=1376-byte stream
// segments and reassemble them on receive. Two real sockets on loopback pin
// both directions.
final class LyraMeshSocketFragmentationTests: XCTestCase {
    private var sender: LyraMeshSocket?
    private var receiver: LyraMeshSocket?

    override func tearDown() {
        sender?.stop()
        receiver?.stop()
        sender = nil
        receiver = nil
        super.tearDown()
    }

    private func waitFor(
        _ description: String, timeout: TimeInterval = 10,
        _ predicate: @escaping () -> Bool
    ) {
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

    func testLargeFrameIsFragmentedAndReassembled() throws {
        let sender = LyraMeshSocket()
        let receiver = LyraMeshSocket()
        self.sender = sender
        self.receiver = receiver

        var received: [LyraMeshPack.Frame] = []
        let lock = NSLock()
        receiver.onFrame = { frame, _, _ in
            lock.lock()
            received.append(frame)
            lock.unlock()
        }
        try receiver.start()
        try sender.start()
        waitFor("both sockets bound") {
            receiver.boundPort != nil && sender.boundPort != nil
        }
        let port = try XCTUnwrap(receiver.boundPort)

        let payload = Data((0..<3000).map { UInt8($0 % 251) })
        let frame = LyraMeshPack.Frame(packType: 5, payload: payload)
        try sender.send(frame: frame, to: "127.0.0.1", port: port)

        waitFor("large frame reassembled") {
            lock.lock()
            defer { lock.unlock() }
            return received.count == 1
        }
        lock.lock()
        let got = try XCTUnwrap(received.first)
        lock.unlock()
        XCTAssertEqual(got.packType, 5)
        XCTAssertEqual(got.payload, payload)
    }

    func testSmallFrameStaysSingleSegment() throws {
        let sender = LyraMeshSocket()
        let receiver = LyraMeshSocket()
        self.sender = sender
        self.receiver = receiver

        var datagramSizes: [Int] = []
        let lock = NSLock()
        receiver.onRawDatagram = { content, _ in
            lock.lock()
            datagramSizes.append(content.count)
            lock.unlock()
        }
        try receiver.start()
        try sender.start()
        waitFor("both sockets bound") {
            receiver.boundPort != nil && sender.boundPort != nil
        }
        let port = try XCTUnwrap(receiver.boundPort)

        let payload = Data(repeating: 0x42, count: 300)
        try sender.send(frame: LyraMeshPack.Frame(packType: 2, payload: payload), to: "127.0.0.1", port: port)

        waitFor("small frame delivered") {
            lock.lock()
            defer { lock.unlock() }
            return datagramSizes.count == 1
        }
        lock.lock()
        let size = try XCTUnwrap(datagramSizes.first)
        lock.unlock()
        XCTAssertLessThanOrEqual(size, 24 + 1376, "small frames must not be fragmented")
    }
}
