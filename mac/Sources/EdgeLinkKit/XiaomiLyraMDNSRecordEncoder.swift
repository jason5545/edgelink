import Foundation

public enum XiaomiLyraMDNSRecordEncodingError: Error, Equatable, Sendable {
    case emptyDomainName
    case labelTooLong(String)
    case domainNameTooLong
    case txtEntryTooLong(String)
}

public enum XiaomiLyraMDNSRecordEncoder {
    public static func dnsName(_ fqdn: String) throws -> Data {
        let trimmed = fqdn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw XiaomiLyraMDNSRecordEncodingError.emptyDomainName
        }

        let labels = trimmed
            .split(separator: ".", omittingEmptySubsequences: true)
            .map(String.init)
        guard !labels.isEmpty else {
            throw XiaomiLyraMDNSRecordEncodingError.emptyDomainName
        }

        var bytes: [UInt8] = []
        for label in labels {
            let labelBytes = Array(label.utf8)
            guard labelBytes.count <= 63 else {
                throw XiaomiLyraMDNSRecordEncodingError.labelTooLong(label)
            }
            bytes.append(UInt8(labelBytes.count))
            bytes.append(contentsOf: labelBytes)
        }
        bytes.append(0)

        guard bytes.count <= 255 else {
            throw XiaomiLyraMDNSRecordEncodingError.domainNameTooLong
        }
        return Data(bytes)
    }

    public static func ptrRecord(targetFQDN: String) throws -> Data {
        try dnsName(targetFQDN)
    }

    public static func srvRecord(port: UInt16, targetFQDN: String) throws -> Data {
        var bytes: [UInt8] = []
        appendUInt16(0, to: &bytes) // priority
        appendUInt16(0, to: &bytes) // weight
        appendUInt16(port, to: &bytes)
        bytes.append(contentsOf: try dnsName(targetFQDN))
        return Data(bytes)
    }

    public static func txtRecord(entries: [(String, String)]) throws -> Data {
        var bytes: [UInt8] = []
        for (key, value) in entries {
            let entry = "\(key)=\(value)"
            let entryBytes = Array(entry.utf8)
            guard entryBytes.count <= 255 else {
                throw XiaomiLyraMDNSRecordEncodingError.txtEntryTooLong(key)
            }
            bytes.append(UInt8(entryBytes.count))
            bytes.append(contentsOf: entryBytes)
        }
        return Data(bytes)
    }

    private static func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }
}
