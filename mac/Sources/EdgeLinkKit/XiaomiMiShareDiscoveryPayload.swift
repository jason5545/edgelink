import Foundation

public struct XiaomiMiShareDiscoveryAppData: Equatable, Sendable {
    public static let deviceTypePhone: UInt8 = 0x01
    public static let deviceTypeMacBook: UInt8 = 0x0e
    static let meshPortOffsetInSuffix = 10
    private static let meshPortOffset = 3 + 4 + 2 + meshPortOffsetInSuffix
    private static let currentSameAccountProfileSuffix: [UInt8] = [
        0x00, 0x05, 0x19, 0x3f, 0x17, 0x0e,
        0x07, 0x0a, 0x03, 0x01, 0xb4, 0xde, 0x01, 0x01,
        0x20, 0x23, 0x00, 0x23, 0x02, 0xb1, 0x45, 0x02
    ]

    public let rawData: Data
    public let deviceIdHex: String?
    public let deviceType: UInt8?
    public let accountIdHex: String?
    public let displayName: String?
    public let meshPort: UInt16?

    public init(data: Data) {
        rawData = data
        deviceIdHex = Self.parseDeviceIdHex(from: data)
        deviceType = Self.parseDeviceType(from: data)
        accountIdHex = Self.parseAccountIdHex(from: data)
        displayName = Self.parseDisplayName(from: data)
        meshPort = Self.parseMeshPort(from: data)
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

    public static func build(
        deviceIdHex: String,
        displayName: String,
        deviceType: UInt8 = Self.deviceTypeMacBook,
        accountIdHex: String = "581F",
        meshPort: UInt16? = nil
    ) throws -> Data {
        let deviceIdBytes = try parseDeviceIdBytes(deviceIdHex)
        let accountIdBytes = try parseHexBytes(accountIdHex, expectedByteCount: 2)
        let nameBytes = Array(displayName.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !nameBytes.isEmpty else {
            throw XiaomiMiShareDiscoveryPayloadError.emptyDisplayName
        }
        guard nameBytes.count <= 255 else {
            throw XiaomiMiShareDiscoveryPayloadError.displayNameTooLong
        }

        // Captured from the phone's current same-account MiShare/Lyra mDNS
        // AppData shape, then adapted with device_type=0x0e so EdgeLink
        // publishes as a MacBook peer instead of another phone peer.
        var suffix = currentSameAccountProfileSuffix
        if let meshPort {
            suffix[Self.meshPortOffsetInSuffix] = UInt8((meshPort >> 8) & 0xFF)
            suffix[Self.meshPortOffsetInSuffix + 1] = UInt8(meshPort & 0xFF)
        }

        var bytes: [UInt8] = [
            0x02, 0x41, deviceType
        ]
        bytes.append(contentsOf: deviceIdBytes)
        bytes.append(contentsOf: accountIdBytes)
        bytes.append(contentsOf: suffix)
        bytes.append(UInt8(nameBytes.count))
        bytes.append(contentsOf: nameBytes)
        return Data(bytes)
    }

    public static func buildBase64(
        deviceIdHex: String,
        displayName: String,
        accountIdHex: String = "581F",
        meshPort: UInt16? = nil
    ) throws -> String {
        try build(
            deviceIdHex: deviceIdHex,
            displayName: displayName,
            accountIdHex: accountIdHex,
            meshPort: meshPort
        ).base64EncodedString()
    }

    private static func parseMeshPort(from data: Data) -> UInt16? {
        let bytes = Array(data)
        guard bytes.count > meshPortOffset + 1 else {
            return nil
        }
        return (UInt16(bytes[meshPortOffset]) << 8) | UInt16(bytes[meshPortOffset + 1])
    }

    private static func parseDeviceType(from data: Data) -> UInt8? {
        let bytes = Array(data)
        guard bytes.count >= 3 else {
            return nil
        }
        return bytes[2]
    }

    private static func parseDeviceIdHex(from data: Data) -> String? {
        let bytes = Array(data)
        guard bytes.count >= 7 else {
            return nil
        }
        return bytes[3..<7].map { String(format: "%02X", $0) }.joined()
    }

    private static func parseAccountIdHex(from data: Data) -> String? {
        let bytes = Array(data)
        guard bytes.count >= 9 else {
            return nil
        }
        return bytes[7..<9].map { String(format: "%02X", $0) }.joined()
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
        try parseHexBytes(deviceIdHex, expectedByteCount: 4)
    }

    private static func parseHexBytes(_ hexString: String, expectedByteCount: Int) throws -> [UInt8] {
        let cleaned = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard cleaned.count == expectedByteCount * 2,
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
