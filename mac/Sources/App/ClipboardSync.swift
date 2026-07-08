import AppKit
import CryptoKit
import Foundation

struct ClipboardSnapshot: Equatable {
    let text: String
    let timestampSeconds: Int64
    let hash: String
}

final class ClipboardSync {
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var suppressedHash: String?

    func pollLocalText() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return nil
        }
        let hash = Self.hash(text)
        if hash == suppressedHash {
            suppressedHash = nil
            return nil
        }
        return ClipboardSnapshot(
            text: text,
            timestampSeconds: Int64(Date().timeIntervalSince1970),
            hash: hash
        )
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

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
