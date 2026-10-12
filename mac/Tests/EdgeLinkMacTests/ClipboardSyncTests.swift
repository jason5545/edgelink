import AppKit
import EdgeLinkKit
import XCTest

// Image clipboards are content-hashed (sha256 of the blob bytes) so that an
// image we applied from the peer polls back with the same hash and is not
// re-broadcast. Covers the PNG/TIFF write paths of applyRemoteImage.
final class ClipboardSyncTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var sync: ClipboardSync!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("edgelink.clipboardsync.test.\(UUID().uuidString)"))
        sync = ClipboardSync(pasteboard: pasteboard)
    }

    override func tearDown() {
        pasteboard?.releaseGlobally()
        pasteboard = nil
        sync = nil
        super.tearDown()
    }

    private func makeBitmap(width: Int, height: Int, color: NSColor) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func makePNG(width: Int, height: Int, color: NSColor) -> Data {
        makeBitmap(width: width, height: height, color: color)
            .representation(using: .png, properties: [:])!
    }

    private func makeJPEG(width: Int, height: Int, color: NSColor) -> Data {
        makeBitmap(width: width, height: height, color: color)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    }

    func testImagePollUsesContentHash() {
        let png = makePNG(width: 32, height: 32, color: .red)
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let snapshot = sync.pollLocalClip()
        XCTAssertEqual(snapshot?.kind, .image)
        XCTAssertEqual(snapshot?.hash, ClipboardBlobTransfer.sha256Hex(png))
        XCTAssertEqual(snapshot?.blobData, png)
    }

    func testAppliedRemotePngIsNotRebroadcast() {
        let png = makePNG(width: 32, height: 32, color: .blue)
        sync.applyRemoteImage(png, mime: "image/png")
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertNil(sync.pollLocalClip())
    }

    func testAppliedRemoteJpegIsWrittenAsPngAndNotRebroadcast() {
        let jpeg = makeJPEG(width: 32, height: 32, color: .green)
        sync.applyRemoteImage(jpeg, mime: "image/jpeg")
        let written = pasteboard.data(forType: .png)
        XCTAssertNotNil(written)
        XCTAssertNotEqual(written, jpeg)
        XCTAssertNil(sync.pollLocalClip())
    }

    func testNewImageAfterApplyStillPolls() {
        sync.applyRemoteImage(makePNG(width: 32, height: 32, color: .blue), mime: "image/png")
        XCTAssertNil(sync.pollLocalClip())
        let other = makePNG(width: 48, height: 24, color: .yellow)
        pasteboard.clearContents()
        pasteboard.setData(other, forType: .png)
        let snapshot = sync.pollLocalClip()
        XCTAssertEqual(snapshot?.kind, .image)
        XCTAssertEqual(snapshot?.hash, ClipboardBlobTransfer.sha256Hex(other))
    }

    func testAppliedRemoteTextStillSuppressed() {
        sync.applyRemoteText("hello", hash: "")
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertNil(sync.pollLocalClip())
    }
}
