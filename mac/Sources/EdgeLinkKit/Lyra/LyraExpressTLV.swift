import Foundation

public enum LyraExpressTLV {
    public static let typeByte: UInt16 = 1
    public static let typeInt32: UInt16 = 3
    public static let typeInt64: UInt16 = 4
    public static let typeString: UInt16 = 5
    public static let typeContainer: UInt16 = 0x100
    public static let typeOneOf: UInt16 = 0x101

    public static func node(type: UInt16, tag: UInt16, payload: Data) -> Data {
        var data = Data(capacity: 8 + payload.count)
        appendUInt16BE(type, to: &data)
        appendUInt16BE(tag, to: &data)
        appendUInt32BE(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    public static func int32Node(tag: UInt16, value: UInt32) -> Data {
        var payload = Data(capacity: 4)
        appendUInt32BE(value, to: &payload)
        return node(type: typeInt32, tag: tag, payload: payload)
    }

    public static func byteNode(tag: UInt16, value: UInt8) -> Data {
        node(type: typeByte, tag: tag, payload: Data([value]))
    }

    public static func int64Node(tag: UInt16, value: UInt64) -> Data {
        var payload = Data(capacity: 8)
        for shift in stride(from: 56, through: 0, by: -8) {
            payload.append(UInt8((value >> shift) & 0xFF))
        }
        return node(type: typeInt64, tag: tag, payload: payload)
    }

    public static func stringNode(tag: UInt16, value: Data) -> Data {
        node(type: typeString, tag: tag, payload: value)
    }

    public static func containerNode(tag: UInt16, children: [Data]) -> Data {
        var payload = Data()
        for child in children {
            payload.append(child)
        }
        return node(type: typeContainer, tag: tag, payload: payload)
    }

    public static func oneOfNode(tag: UInt16, selectedTag: UInt16, child: Data) -> Data {
        var payload = Data(capacity: 2 + child.count)
        appendUInt16BE(selectedTag, to: &payload)
        payload.append(child)
        return node(type: typeOneOf, tag: tag, payload: payload)
    }

    public static func handshakeEventFrame(dataPort: UInt32, key: Data, multilinks: UInt32 = 0) -> Data {
        let handshake = containerNode(tag: 1, children: [
            int32Node(tag: 0, value: 0),
            int32Node(tag: 1, value: 1),
            int32Node(tag: 2, value: multilinks),
            int32Node(tag: 3, value: dataPort),
            stringNode(tag: 4, value: key),
            byteNode(tag: 5, value: 8)
        ])
        return oneOfNode(tag: 0xFFFF, selectedTag: 1, child: handshake)
    }

    private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
