import Foundation

public struct XiaomiMiShareDiscoveryAppData: Equatable, Sendable {
    public let rawData: Data
    public let deviceIdHex: String?
    public let displayName: String?

    public init(data: Data) {
        rawData = data
        deviceIdHex = Self.parseDeviceIdHex(from: data)
        displayName = Self.parseDisplayName(from: data)
    }

    public init?(base64Encoded string: String) {
        guard let data = Data(base64Encoded: string) else {
            return nil
        }
        self.init(data: data)
    }

    public var base64EncodedString: String {
        rawData.base64EncodedString()
    }

    public static func build(deviceIdHex: String, displayName: String) throws -> Data {
        let deviceIdBytes = try parseDeviceIdBytes(deviceIdHex)
        let nameBytes = Array(displayName.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !nameBytes.isEmpty else {
            throw XiaomiMiShareDiscoveryPayloadError.emptyDisplayName
        }
        guard nameBytes.count <= 255 else {
            throw XiaomiMiShareDiscoveryPayloadError.displayNameTooLong
        }

        // Captured from the phone's MiShare/Lyra mDNS AppData shape.
        // The fields between device id and display name are still opaque Xiaomi
        // continuity metadata; keeping a real phone-compatible template gives us
        // a stable discovery foothold while transfer-channel work continues.
        var bytes: [UInt8] = [
            0x02, 0x41, 0x01
        ]
        bytes.append(contentsOf: deviceIdBytes)
        bytes.append(contentsOf: [
            0x58, 0x1f, 0x00, 0x05, 0x19, 0x2f, 0x17, 0x1a,
            0x03, 0x0a, 0x03, 0x01, 0x8f, 0xb3, 0x01, 0x01,
            0x20, 0x23, 0x00, 0x23, 0x02, 0x54, 0x9a, 0x02
        ])
        bytes.append(UInt8(nameBytes.count))
        bytes.append(contentsOf: nameBytes)
        return Data(bytes)
    }

    public static func buildBase64(deviceIdHex: String, displayName: String) throws -> String {
        try build(deviceIdHex: deviceIdHex, displayName: displayName).base64EncodedString()
    }

    private static func parseDeviceIdHex(from data: Data) -> String? {
        let bytes = Array(data)
        guard bytes.count >= 7 else {
            return nil
        }
        return bytes[3..<7].map { String(format: "%02X", $0) }.joined()
    }

    private static func parseDisplayName(from data: Data) -> String? {
        let bytes = Array(data)
        guard bytes.count >= 2 else {
            return nil
        }

        var candidate: String?
        for index in bytes.indices {
            let length = Int(bytes[index])
            let start = index + 1
            let end = start + length
            guard length > 0, end == bytes.count else {
                continue
            }
            let nameData = Data(bytes[start..<end])
            guard let name = String(data: nameData, encoding: .utf8),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            candidate = name
        }
        return candidate
    }

    private static func parseDeviceIdBytes(_ deviceIdHex: String) throws -> [UInt8] {
        let cleaned = deviceIdHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard cleaned.count == 8,
              cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw XiaomiMiShareDiscoveryPayloadError.invalidDeviceId
        }

        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else {
                throw XiaomiMiShareDiscoveryPayloadError.invalidDeviceId
            }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }
}

public enum XiaomiMiShareDiscoveryPayloadError: Error, Equatable, Sendable {
    case invalidDeviceId
    case emptyDisplayName
    case displayNameTooLong
}
