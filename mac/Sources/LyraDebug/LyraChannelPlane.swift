import Foundation

enum LyraChannelPlane {
    static let tlvMagic: [UInt8] = [0x01, 0x01, 0xFF, 0xFF]
    static let encryptedFlags: Set<UInt16> = [0x5882, 0x9882]
    static let plaintextFlags: Set<UInt16> = [0xB882]
    static let fileFlags: Set<UInt16> = [0xD882]

    static func looksLikeChannelFlow(_ flow: KCPFlow) -> Bool {
        guard let first = flow.orderedPayloads.first?.payload, first.count >= 8 else { return false }
        if Array(first.prefix(4)) == tlvMagic { return true }
        let flags = UInt16(first[first.startIndex]) | UInt16(first[first.startIndex + 1]) << 8
        return encryptedFlags.contains(flags) || plaintextFlags.contains(flags) || fileFlags.contains(flags)
    }

    struct Fragment {
        let flags: UInt16
        let offset: UInt16
        let count: UInt16
        let body: Data
        let totalLength: Int
    }

    static func parseFragment(_ payload: Data) -> Fragment? {
        guard payload.count >= 8 else { return nil }
        let flags = UInt16(payload[payload.startIndex]) | UInt16(payload[payload.startIndex + 1]) << 8
        guard encryptedFlags.contains(flags) || plaintextFlags.contains(flags) || fileFlags.contains(flags) else { return nil }
        let bodyLen = Int(UInt16(payload[payload.startIndex + 2]) << 8 | UInt16(payload[payload.startIndex + 3]))
        let offset = UInt16(payload[payload.startIndex + 4]) << 8 | UInt16(payload[payload.startIndex + 5])
        let count = UInt16(payload[payload.startIndex + 6]) << 8 | UInt16(payload[payload.startIndex + 7])
        guard bodyLen >= 8, bodyLen <= payload.count else { return nil }
        return Fragment(
            flags: flags,
            offset: offset,
            count: count,
            body: payload.subdata(in: (payload.startIndex + 8)..<(payload.startIndex + bodyLen)),
            totalLength: bodyLen
        )
    }

    static func isTLVFrame(_ payload: Data) -> Bool {
        payload.count >= 10 && Array(payload.prefix(4)) == tlvMagic
    }

    static func dumpTLVFrame(_ payload: Data, dump: inout Dump) {
        guard payload.count >= 10 else {
            dump.hex("short tlv", payload)
            return
        }
        let total = Int(payload[payload.startIndex + 4]) << 24 | Int(payload[payload.startIndex + 5]) << 16
            | Int(payload[payload.startIndex + 6]) << 8 | Int(payload[payload.startIndex + 7])
        let selected = Int(payload[payload.startIndex + 8]) << 8 | Int(payload[payload.startIndex + 9])
        dump.line("oneof select tag \(selected) (\(total)B)")
        let body = payload.subdata(in: (payload.startIndex + 10)..<min(payload.endIndex, payload.startIndex + 8 + total))
        dumpTLVNodes(body, dump: &dump, depth: 0)
    }

    static func dumpTLVNodes(_ data: Data, dump: inout Dump, depth: Int) {
        guard depth < 6 else {
            dump.hex("…", data, maxBytes: 32)
            return
        }
        var index = data.startIndex
        while index + 8 <= data.endIndex {
            let type = UInt16(data[index]) << 8 | UInt16(data[index + 1])
            let tag = UInt16(data[index + 2]) << 8 | UInt16(data[index + 3])
            let length = Int(UInt32(data[index + 4]) << 24 | UInt32(data[index + 5]) << 16
                | UInt32(data[index + 6]) << 8 | UInt32(data[index + 7]))
            guard length >= 0, index + 8 + length <= data.endIndex else {
                dump.hex("tlv truncated", Data(data[index...]), maxBytes: 32)
                return
            }
            let value = data[(index + 8)..<(index + 8 + length)]
            switch type {
            case 1:
                dump.line("byte tag\(tag) = \(value.hexString)")
            case 3:
                let intValue = value.count >= 4
                    ? Int32(Int32(value[value.startIndex]) << 24 | Int32(value[value.startIndex + 1]) << 16
                        | Int32(value[value.startIndex + 2]) << 8 | Int32(value[value.startIndex + 3]))
                    : 0
                dump.line("i32 tag\(tag) = \(intValue)")
            case 4:
                var intValue = 0
                for byte in value { intValue = intValue << 8 | Int(byte) }
                dump.line("i64 tag\(tag) = \(intValue)")
            case 5:
                if let string = String(data: value, encoding: .utf8), !string.isEmpty {
                    dump.line("string tag\(tag) (\(value.count)B) = \(string.prefix(400))")
                } else {
                    dump.hex("string tag\(tag)", Data(value), maxBytes: 48)
                }
            case 0x100:
                dump.section("nodes tag\(tag)") { dump in
                    dumpTLVNodes(Data(value), dump: &dump, depth: depth + 1)
                }
            case 0x101:
                guard value.count >= 2 else { return }
                let selected = Int(value[value.startIndex]) << 8 | Int(value[value.startIndex + 1])
                dump.line("oneof tag\(tag) select \(selected)")
                dumpTLVNodes(Data(value.dropFirst(2)), dump: &dump, depth: depth + 1)
            default:
                dump.hex("type\(String(type, radix: 16)) tag\(tag) (\(length)B)", Data(value), maxBytes: 48)
            }
            index += 8 + length
        }
    }
}
