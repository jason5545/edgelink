import AppKit
import CryptoKit
import EdgeLinkKit
import Foundation

struct ClipboardSnapshot: Equatable {
    let text: String
    let timestampSeconds: Int64
    let hash: String
    let kind: ClipboardKind
    let thumbnailBase64: String?
    let blobData: Data?
    let blobMime: String?
}

final class ClipboardSync {
    private static let protectedOutboundInterval: TimeInterval = 10 * 60
    private static let imageTextMaxChars = 2_048
    private static let wireImageMaxBytes = 24 * 1024
    private static let textWireMaxBytes = 48 * 1024
    private static let textStoreMaxBytes = 256 * 1024
    private static let textPreviewMaxBytes = 16 * 1024

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var suppressedHash: String?
    private var protectedOutboundHashes: [String: Date] = [:]

    func pollLocalClip() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current

        let types = pasteboard.types ?? []
        let hasImage = types.contains(.tiff) || types.contains(.png)
        let stringText = pasteboard.string(forType: .string) ?? ""

        var kind: ClipboardKind = .text
        var text = ""
        var thumbnailBase64: String?
        var blobData: Data?
        var blobMime: String?
        if hasImage {
            kind = .image
            thumbnailBase64 = ClipboardThumbnailGenerator.thumbnailBase64(forImageIn: pasteboard)
            text = String(stringText.prefix(Self.imageTextMaxChars))
            if let thumbnail = thumbnailBase64,
               thumbnail.utf8.count + text.utf8.count > Self.wireImageMaxBytes {
                DiagnosticsLog.info("clipboard.mac.image_thumbnail_dropped bytes=\(thumbnail.utf8.count)")
                thumbnailBase64 = nil
            }
            if let png = pasteboard.data(forType: .png) {
                blobData = png
                blobMime = "image/png"
            } else if let tiff = pasteboard.data(forType: .tiff),
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) {
                blobData = png
                blobMime = "image/png"
            }
            if let data = blobData, data.count > ClipboardBlobTransfer.maxBlobBytes {
                DiagnosticsLog.info("clipboard.mac.image_blob_too_large bytes=\(data.count)")
                blobData = nil
                blobMime = nil
            }
        } else if !stringText.isEmpty {
            let textBytes = stringText.utf8.count
            guard textBytes <= Self.textStoreMaxBytes else {
                DiagnosticsLog.info("clipboard.mac.text_too_large_skipped bytes=\(textBytes)")
                return nil
            }
            kind = .text
            if textBytes > Self.textWireMaxBytes {
                blobData = Data(stringText.utf8)
                blobMime = "text/plain"
                text = Self.utf8Preview(stringText, maxBytes: Self.textPreviewMaxBytes)
            } else {
                text = stringText
            }
        } else {
            return nil
        }

        let hash: String
        if kind == .image {
            hash = Self.hash("\u{1}" + (thumbnailBase64 ?? ""))
        } else if blobData != nil {
            hash = Self.hash(stringText)
        } else {
            hash = Self.hash(text)
        }

        pruneProtectedOutboundHashes()
        if protectedOutboundHashes[hash] != nil {
            DiagnosticsLog.info("clipboard.mac.local_blocked hashFp=\(Self.fingerprint(hash))")
            return nil
        }
        if hash == suppressedHash {
            suppressedHash = nil
            return nil
        }
        return ClipboardSnapshot(
            text: text,
            timestampSeconds: Int64(Date().timeIntervalSince1970),
            hash: hash,
            kind: kind,
            thumbnailBase64: thumbnailBase64,
            blobData: blobData,
            blobMime: blobMime
        )
    }

    func applyRemoteImage(_ data: Data, mime: String?) {
        guard let thumbnail = ClipboardThumbnailGenerator.thumbnailBase64(for: data) else {
            DiagnosticsLog.info("clipboard.mac.remote_image_undecodable bytes=\(data.count)")
            return
        }
        let hash = Self.hash("\u{1}" + thumbnail)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if mime == "image/png" {
            pasteboard.setData(data, forType: .png)
        } else if let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        } else {
            pasteboard.setData(data, forType: .png)
        }
        suppressedHash = hash
        lastChangeCount = pasteboard.changeCount
    }

    static func utf8Preview(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let prefix = text.utf8.prefix(maxBytes)
        var endIndex = prefix.endIndex
        while endIndex > prefix.startIndex {
            if String(prefix[..<endIndex]) != nil {
                break
            }
            endIndex = prefix.index(before: endIndex)
        }
        return String(prefix[..<endIndex]) ?? ""
    }

    func applyRemoteText(_ text: String, hash remoteHash: String) {
        let hash = remoteHash.isEmpty ? Self.hash(text) : remoteHash
        guard hash != Self.hash(NSPasteboard.general.string(forType: .string) ?? "") else {
            suppressedHash = hash
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        suppressedHash = hash
        lastChangeCount = pasteboard.changeCount
    }

    func setLocalTextWithoutPublishing(_ text: String) {
        let hash = Self.hash(text)
        protectOutbound(hash)
        guard hash != Self.hash(NSPasteboard.general.string(forType: .string) ?? "") else {
            suppressedHash = hash
            lastChangeCount = NSPasteboard.general.changeCount
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        suppressedHash = hash
        lastChangeCount = pasteboard.changeCount
    }

    private func protectOutbound(_ hash: String) {
        protectedOutboundHashes[hash] = Date().addingTimeInterval(Self.protectedOutboundInterval)
    }

    private func pruneProtectedOutboundHashes(now: Date = Date()) {
        protectedOutboundHashes = protectedOutboundHashes.filter { _, expiresAt in
            expiresAt > now
        }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func fingerprint(_ value: String) -> String {
        String(value.prefix(12))
    }
}
