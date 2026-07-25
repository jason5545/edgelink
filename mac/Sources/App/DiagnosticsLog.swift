import Foundation
import CryptoKit
import OSLog

enum DiagnosticsLog {
    private static let logger = Logger(subsystem: "com.edgelink.mac", category: "diagnostics")
    private static let fileQueue = DispatchQueue(label: "EdgeLink.DiagnosticsLogFile")
    private static let maxFileBytes: UInt64 = 2 * 1024 * 1024
    private static let maxBackupCount = 3

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        write("WARN", message)
    }

    static func error(_ message: String, _ error: Error? = nil) {
        let fullMessage = error.map { "\(message) error=\(String(describing: $0))" } ?? message
        logger.error("\(fullMessage, privacy: .public)")
        write("ERROR", fullMessage)
    }

    static func fingerprint(_ data: Data) -> String {
        let digest = SHA256Digest.sha256(data)
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ level: String, _ message: String) {
        fileQueue.async {
            do {
                let url = try logURL()
                try rotateIfNeeded(url)
                let line = "\(timestamp()) \(level) \(message)\n"
                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                logger.error("diagnostics.log write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func logURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DiagnosticsLogError.missingApplicationSupport
        }
        let directory = base.appendingPathComponent("EdgeLink", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("diagnostics.log")
    }

    private static func rotateIfNeeded(_ url: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        let size = (try manager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size >= maxFileBytes else { return }
        let oldest = url.appendingPathExtension("\(maxBackupCount)")
        if manager.fileExists(atPath: oldest.path) {
            try manager.removeItem(at: oldest)
        }
        if maxBackupCount > 1 {
            for index in stride(from: maxBackupCount - 1, through: 1, by: -1) {
                let source = url.appendingPathExtension("\(index)")
                if manager.fileExists(atPath: source.path) {
                    try manager.moveItem(at: source, to: url.appendingPathExtension("\(index + 1)"))
                }
            }
        }
        try manager.moveItem(at: url, to: url.appendingPathExtension("1"))
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private enum DiagnosticsLogError: Error {
    case missingApplicationSupport
}

private enum SHA256Digest {
    static func sha256(_ data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }
}
