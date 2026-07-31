import Foundation

struct UDPPacket {
    let timestamp: Date
    let source: String
    let sourcePort: UInt16
    let destination: String
    let destinationPort: UInt16
    let payload: Data

    var flowKey: String { "\(source):\(sourcePort)>\(destination):\(destinationPort)" }
}

enum PcapReaderError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case unsupportedFormat
    case unsupportedLinkType(UInt32)

    var description: String {
        switch self {
        case .cannotOpen(let path): return "cannot open \(path)"
        case .unsupportedFormat: return "unsupported capture format (not classic pcap or pcapng)"
        case .unsupportedLinkType(let t): return "unsupported link type \(t)"
        }
    }
}

enum PcapReader {
    static func read(path: String) throws -> [UDPPacket] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw PcapReaderError.cannotOpen(path)
        }
        guard data.count >= 4 else { throw PcapReaderError.unsupportedFormat }
        let magic = data.prefix(4)
        if magic == Data([0x0A, 0x0D, 0x0D, 0x0A]) {
            return try readPcapNG(data)
        }
        return try readClassic(data)
    }

    private static func readClassic(_ data: Data) throws -> [UDPPacket] {
        guard data.count >= 24 else { throw PcapReaderError.unsupportedFormat }
        let magicLE = readU32(data, 0, littleEndian: true)
        let littleEndian: Bool
        var nano = false
        switch magicLE {
        case 0xA1B2C3D4: littleEndian = true
        case 0xD4C3B2A1: littleEndian = false
        case 0xA1B23C4D: littleEndian = true; nano = true
        case 0x4D3CB2A1: littleEndian = false; nano = true
        default: throw PcapReaderError.unsupportedFormat
        }
        let linkType = readU32(data, 20, littleEndian: littleEndian) & 0xFFFF
        var packets: [UDPPacket] = []
        var offset = 24
        while offset + 16 <= data.count {
            let tsSec = readU32(data, offset, littleEndian: littleEndian)
            let tsFrac = readU32(data, offset + 4, littleEndian: littleEndian)
            let inclLen = Int(readU32(data, offset + 8, littleEndian: littleEndian))
            offset += 16
            guard offset + inclLen <= data.count else { break }
            let frame = data.subdata(in: offset..<(offset + inclLen))
            offset += inclLen
            let divisor = nano ? 1_000_000_000.0 : 1_000_000.0
            let ts = Date(timeIntervalSince1970: TimeInterval(tsSec) + TimeInterval(tsFrac) / divisor)
            if let packet = parseLinkFrame(frame, linkType: linkType, timestamp: ts) {
                packets.append(packet)
            }
        }
        return packets
    }

    private static func readPcapNG(_ data: Data) throws -> [UDPPacket] {
        var packets: [UDPPacket] = []
        var offset = 0
        var littleEndian = true
        var interfaceLinkTypes: [UInt32] = []
        var interfaceTSResolution: [Double] = []
        while offset + 12 <= data.count {
            let blockType = readU32(data, offset, littleEndian: littleEndian)
            if offset == 0 || blockType == 0x0A0D0D0A {
                guard offset + 12 <= data.count else { break }
                let bom = readU32(data, offset + 8, littleEndian: true)
                if bom == 0x1A2B3C4D {
                    littleEndian = true
                } else if bom == 0x4D3C2B1A {
                    littleEndian = false
                }
            }
            let totalLength = Int(readU32(data, offset + 4, littleEndian: littleEndian))
            guard totalLength >= 12, offset + totalLength <= data.count else { break }
            let body = data.subdata(in: (offset + 8)..<(offset + totalLength - 4))
            switch readU32(data, offset, littleEndian: littleEndian) {
            case 0x00000001:
                if body.count >= 8 {
                    interfaceLinkTypes.append(UInt32(readU16(body, 0, littleEndian: littleEndian)))
                    var resolution = 1e-6
                    if body.count > 12 {
                        var optOffset = 8
                        while optOffset + 4 <= body.count {
                            let code = readU16(body, optOffset, littleEndian: littleEndian)
                            let len = Int(readU16(body, optOffset + 2, littleEndian: littleEndian))
                            optOffset += 4
                            guard optOffset + len <= body.count else { break }
                            if code == 9, len >= 1 {
                                let raw = body[optOffset]
                                if raw & 0x80 != 0 {
                                    resolution = pow(2.0, -Double(raw & 0x7F))
                                } else {
                                    resolution = pow(10.0, -Double(raw))
                                }
                            }
                            optOffset += (len + 3) & ~3
                        }
                    }
                    interfaceTSResolution.append(resolution)
                }
            case 0x00000006:
                if body.count >= 20 {
                    let interfaceID = Int(readU32(body, 0, littleEndian: littleEndian))
                    let tsHigh = UInt64(readU32(body, 4, littleEndian: littleEndian))
                    let tsLow = UInt64(readU32(body, 8, littleEndian: littleEndian))
                    let capLen = Int(readU32(body, 12, littleEndian: littleEndian))
                    guard body.count >= 20 + capLen else { break }
                    let linkType = interfaceID < interfaceLinkTypes.count ? interfaceLinkTypes[interfaceID] : 1
                    let resolution = interfaceID < interfaceTSResolution.count ? interfaceTSResolution[interfaceID] : 1e-6
                    let ticks = tsHigh << 32 | tsLow
                    let ts = Date(timeIntervalSince1970: TimeInterval(ticks) * resolution)
                    let frame = body.subdata(in: 20..<(20 + capLen))
                    if let packet = parseLinkFrame(frame, linkType: linkType, timestamp: ts) {
                        packets.append(packet)
                    }
                }
            case 0x00000003:
                if !interfaceLinkTypes.isEmpty, let first = interfaceLinkTypes.first, body.count >= 4 {
                    let origLen = Int(readU32(body, 0, littleEndian: littleEndian))
                    let frame = body.subdata(in: 4..<min(body.count, 4 + origLen))
                    if let packet = parseLinkFrame(frame, linkType: first, timestamp: Date(timeIntervalSince1970: 0)) {
                        packets.append(packet)
                    }
                }
            default:
                break
            }
            offset += totalLength
        }
        return packets
    }

    private static func parseLinkFrame(_ frame: Data, linkType: UInt32, timestamp: Date) -> UDPPacket? {
        switch linkType {
        case 1:
            return parseEthernet(frame, timestamp: timestamp)
        case 101, 228, 229:
            return parseIP(frame, timestamp: timestamp)
        case 113:
            guard frame.count >= 16 else { return nil }
            let proto = UInt16(frame[14]) << 8 | UInt16(frame[15])
            return parseIPByProto(frame.subdata(in: 16..<frame.count), proto: proto, timestamp: timestamp)
        case 0, 108:
            guard frame.count >= 4 else { return nil }
            let family = readU32(frame, 0, littleEndian: true)
            let proto: UInt16 = (family == 2 || family == 0x02000000) ? 0x0800 : 0x86DD
            return parseIPByProto(frame.subdata(in: 4..<frame.count), proto: proto, timestamp: timestamp)
        default:
            return nil
        }
    }

    private static func parseEthernet(_ frame: Data, timestamp: Date) -> UDPPacket? {
        guard frame.count >= 14 else { return nil }
        var etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])
        var offset = 14
        while etherType == 0x8100 || etherType == 0x88A8 {
            guard frame.count >= offset + 4 else { return nil }
            etherType = UInt16(frame[offset + 2]) << 8 | UInt16(frame[offset + 3])
            offset += 4
        }
        return parseIPByProto(frame.subdata(in: offset..<frame.count), proto: etherType, timestamp: timestamp)
    }

    private static func parseIPByProto(_ data: Data, proto: UInt16, timestamp: Date) -> UDPPacket? {
        switch proto {
        case 0x0800: return parseIPv4(data, timestamp: timestamp)
        case 0x86DD: return parseIPv6(data, timestamp: timestamp)
        default: return nil
        }
    }

    private static func parseIP(_ data: Data, timestamp: Date) -> UDPPacket? {
        guard !data.isEmpty else { return nil }
        let version = data[data.startIndex] >> 4
        if version == 4 { return parseIPv4(data, timestamp: timestamp) }
        if version == 6 { return parseIPv6(data, timestamp: timestamp) }
        return nil
    }

    private static func parseIPv4(_ data: Data, timestamp: Date) -> UDPPacket? {
        guard data.count >= 20 else { return nil }
        let ihl = Int(data[data.startIndex] & 0x0F) * 4
        guard ihl >= 20, data.count >= ihl + 8 else { return nil }
        guard data[data.startIndex + 9] == 17 else { return nil }
        let src = ipv4String(data, data.startIndex + 12)
        let dst = ipv4String(data, data.startIndex + 16)
        return parseUDP(data.subdata(in: (data.startIndex + ihl)..<data.endIndex), src: src, dst: dst, timestamp: timestamp)
    }

    private static func parseIPv6(_ data: Data, timestamp: Date) -> UDPPacket? {
        guard data.count >= 48 else { return nil }
        guard data[data.startIndex + 6] == 17 else { return nil }
        let src = ipv6String(data, data.startIndex + 8)
        let dst = ipv6String(data, data.startIndex + 24)
        return parseUDP(data.subdata(in: (data.startIndex + 40)..<data.endIndex), src: src, dst: dst, timestamp: timestamp)
    }

    private static func parseUDP(_ data: Data, src: String, dst: String, timestamp: Date) -> UDPPacket? {
        guard data.count >= 8 else { return nil }
        let sport = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
        let dport = UInt16(data[data.startIndex + 2]) << 8 | UInt16(data[data.startIndex + 3])
        let length = Int(UInt16(data[data.startIndex + 4]) << 8 | UInt16(data[data.startIndex + 5]))
        guard length >= 8, data.count >= length else { return nil }
        let payload = data.subdata(in: (data.startIndex + 8)..<(data.startIndex + length))
        return UDPPacket(timestamp: timestamp, source: src, sourcePort: sport, destination: dst, destinationPort: dport, payload: payload)
    }

    private static func ipv4String(_ data: Data, _ offset: Int) -> String {
        "\(data[offset]).\(data[offset + 1]).\(data[offset + 2]).\(data[offset + 3])"
    }

    private static func ipv6String(_ data: Data, _ offset: Int) -> String {
        var groups: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            groups.append(String(UInt16(data[offset + i]) << 8 | UInt16(data[offset + i + 1]), radix: 16))
        }
        return groups.joined(separator: ":")
    }

    static func readU32(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return littleEndian ? (b0 | b1 << 8 | b2 << 16 | b3 << 24) : (b3 | b2 << 8 | b1 << 16 | b0 << 24)
    }

    static func readU16(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return littleEndian ? (b0 | b1 << 8) : (b1 | b0 << 8)
    }
}
