import Foundation

public struct LyraExpressTLVNode: Equatable, Sendable {
    public var type: UInt16
    public var tag: UInt16
    public var payload: Data

    public init(type: UInt16, tag: UInt16, payload: Data) {
        self.type = type
        self.tag = tag
        self.payload = payload
    }

    public var int32Value: UInt32? {
        guard type == LyraExpressTLV.typeInt32 || type == LyraExpressTLV.typeInt64, payload.count >= 4 else {
            return nil
        }
        var value: UInt32 = 0
        for byte in payload.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    public var int64Value: UInt64? {
        guard type == LyraExpressTLV.typeInt64, payload.count == 8 else {
            return nil
        }
        var value: UInt64 = 0
        for byte in payload {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    public var byteValue: UInt8? {
        guard type == LyraExpressTLV.typeByte, payload.count == 1 else {
            return nil
        }
        return payload.first
    }
}

public enum LyraExpressTLVParser {
    public enum ParseError: Error, Equatable, Sendable {
        case truncated
    }

    public static func parseNode(_ data: Data) throws -> (node: LyraExpressTLVNode, consumed: Int) {
        let bytes = Array(data)
        guard bytes.count >= 8 else {
            throw ParseError.truncated
        }
        let type = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        let tag = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let length = (Int(bytes[4]) << 24) | (Int(bytes[5]) << 16) | (Int(bytes[6]) << 8) | Int(bytes[7])
        guard bytes.count >= 8 + length else {
            throw ParseError.truncated
        }
        return (LyraExpressTLVNode(type: type, tag: tag, payload: Data(bytes[8..<(8 + length)])), 8 + length)
    }

    public static func parseChildren(_ data: Data) throws -> [LyraExpressTLVNode] {
        var nodes: [LyraExpressTLVNode] = []
        var index = data.startIndex
        while index < data.endIndex {
            let (node, consumed) = try parseNode(Data(data[index...]))
            nodes.append(node)
            index += consumed
        }
        return nodes
    }

    public static func parseOneOf(_ data: Data) throws -> (selectedTag: UInt16, child: LyraExpressTLVNode)? {
        let (node, _) = try parseNode(data)
        guard node.type == LyraExpressTLV.typeOneOf, node.payload.count >= 2 else {
            return nil
        }
        let bytes = Array(node.payload)
        let selectedTag = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        let (child, _) = try parseNode(Data(bytes[2...]))
        return (selectedTag, child)
    }

    public static func children(of node: LyraExpressTLVNode) -> [LyraExpressTLVNode] {
        guard node.type == LyraExpressTLV.typeContainer else {
            return []
        }
        return (try? parseChildren(node.payload)) ?? []
    }

    public static func firstChild(_ tag: UInt16, in nodes: [LyraExpressTLVNode]) -> LyraExpressTLVNode? {
        nodes.first { $0.tag == tag }
    }
}
