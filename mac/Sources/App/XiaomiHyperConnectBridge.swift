import AppKit
import Foundation

enum XiaomiHyperConnectBridge {
    static let bundleIdentifier = "com.xiaomi.hyperConnect"
    private static let transferScheme = "hyperConnect"
    private static let localDeviceIdTailBytes = 512 * 1024
    private static let localDeviceIdFileLimit = 80

    static var isInstalled: Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil {
            return true
        }
        guard let url = URL(string: "\(transferScheme)://") else {
            return false
        }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    static func openTransfer(fileURLs: [URL]) throws {
        let paths = fileURLs
            .filter { $0.isFileURL }
            .map(\.path)
        guard !paths.isEmpty else {
            throw XiaomiHyperConnectError.noFiles
        }

        let data = try JSONSerialization.data(withJSONObject: paths, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw XiaomiHyperConnectError.encodingFailed
        }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        guard let encoded = json.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(transferScheme)://transfer?filePaths=\(encoded)")
        else {
            throw XiaomiHyperConnectError.encodingFailed
        }

        guard NSWorkspace.shared.open(url) else {
            throw XiaomiHyperConnectError.openFailed
        }
    }

    static func localDeviceId() -> String? {
        let fileManager = FileManager.default
        let files = hyperConnectLogRoots()
            .flatMap { root -> [URL] in
                guard let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    return []
                }
                return enumerator.compactMap { item -> URL? in
                    guard let url = item as? URL,
                          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    else {
                        return nil
                    }
                    let name = url.lastPathComponent.lowercased()
                    guard name.hasSuffix(".log") || name == "storage.lyra" || name.hasSuffix(".plist") else {
                        return nil
                    }
                    return url
                }
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        for file in files.prefix(localDeviceIdFileLimit) {
            if let deviceId = localDeviceId(in: file) {
                DiagnosticsLog.info("xiaomi.hyperconnect.local_device_id source=\(file.lastPathComponent) id=\(deviceId)")
                return deviceId
            }
        }
        DiagnosticsLog.warn("xiaomi.hyperconnect.local_device_id_missing")
        return nil
    }

    private static func hyperConnectLogRoots() -> [URL] {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.xiaomi.hyperConnect/Data/Library")
        return [
            container.appendingPathComponent("com.xiaomi.hyperConnect/Caches/Logs"),
            container.appendingPathComponent("Caches/com.xiaomi.hyperConnect"),
            container.appendingPathComponent("Application Support/HyperConnect"),
            container.appendingPathComponent("Preferences")
        ]
    }

    private static func localDeviceId(in file: URL) -> String? {
        guard let data = try? tailData(from: file, maxBytes: localDeviceIdTailBytes),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        else {
            return nil
        }
        for pattern in localDeviceIdPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.matches(in: text, range: range).last,
                  match.numberOfRanges > 1,
                  let idRange = Range(match.range(at: 1), in: text)
            else {
                continue
            }
            return String(text[idRange]).uppercased()
        }
        return nil
    }

    private static func tailData(from file: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    private static let localDeviceIdPatterns = [
        #"getLocalDeviceID\(\).*device_id\s*:\s*([0-9A-Fa-f]{8})"#,
        #"lyraBindSuccess\(\).*:\s*([0-9A-Fa-f]{8})\s+is this device id"#,
        #"local device\s+([0-9A-Fa-f]{8})"#,
        #"local_dev_id:\s*([0-9A-Fa-f]{8})"#,
        #"my_device_id=([0-9A-Fa-f]{8})"#,
        #""device_id"\s*:\s*"?([0-9A-Fa-f]{8})"?\s*,\s*"device_type"\s*:\s*14"#
    ]
}

enum XiaomiHyperConnectError: LocalizedError {
    case noFiles
    case encodingFailed
    case openFailed

    var errorDescription: String? {
        switch self {
        case .noFiles:
            return "No file URLs were selected."
        case .encodingFailed:
            return "Could not encode Xiaomi transfer URL."
        case .openFailed:
            return "Xiaomi HyperConnect did not accept the transfer URL."
        }
    }
}
