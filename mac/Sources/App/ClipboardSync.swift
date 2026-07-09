import AppKit
import CryptoKit
import Foundation

struct ClipboardSnapshot: Equatable {
    let text: String
    let timestampSeconds: Int64
    let hash: String
}

final class ClipboardSync {
    private static let protectedOutboundInterval: TimeInterval = 10 * 60

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var suppressedHash: String?
    private var protectedOutboundHashes: [String: Date] = [:]

    func pollLocalText() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return nil
        }
        let hash = Self.hash(text)
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
