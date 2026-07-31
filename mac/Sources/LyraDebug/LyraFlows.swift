import Foundation

struct KCPFlow {
    let key: String
    var pushCount = 0
    var ackCount = 0
    var segments: [UInt32: (payload: Data, timestamp: Date)] = [:]
    var firstTimestamp: Date?
    var sawKCP = false
    var rawDatagrams: [(timestamp: Date, payload: Data)] = []

    var orderedPayloads: [(sn: UInt32, payload: Data, timestamp: Date)] {
        segments.keys.sorted().map { sn in
            let entry = segments[sn]!
            return (sn, entry.payload, entry.timestamp)
        }
    }

    var missingSNs: [UInt32] {
        guard let minSN = segments.keys.min(), let maxSN = segments.keys.max() else { return [] }
        var missing: [UInt32] = []
        var sn = minSN
        while sn < maxSN {
            if segments[sn] == nil { missing.append(sn) }
            sn &+= 1
        }
        return missing
    }
}

enum FlowAssembler {
    static func assemble(packets: [UDPPacket]) -> [String: KCPFlow] {
        var flows: [String: KCPFlow] = [:]
        for packet in packets {
            var flow = flows[packet.flowKey, default: KCPFlow(key: packet.flowKey)]
            if flow.firstTimestamp == nil { flow.firstTimestamp = packet.timestamp }
            do {
                let segment = try LyraMeshDatagram.decodeSegment(packet.payload)
                flow.sawKCP = true
                if segment.command == LyraMeshDatagram.commandPush {
                    flow.pushCount += 1
                    if flow.segments[segment.sn] == nil, !segment.payload.isEmpty {
                        flow.segments[segment.sn] = (segment.payload, packet.timestamp)
                    }
                } else if segment.command == LyraMeshDatagram.commandAck {
                    flow.ackCount += 1
                }
            } catch {
                flow.rawDatagrams.append((packet.timestamp, packet.payload))
            }
            flows[packet.flowKey] = flow
        }
        return flows
    }
}

struct MeshFrameRecord {
    let timestamp: Date
    let flowKey: String
    let frame: LyraMeshPack.Frame
    let streamOffset: Int
    let skippedBytesBefore: Int
}

enum MeshFrameSplitter {
    static func split(flow: KCPFlow) -> (frames: [MeshFrameRecord], trailingBytes: Int, totalSkipped: Int) {
        var records: [MeshFrameRecord] = []
        var stream = Data()
        var chunkStarts: [(streamOffset: Int, timestamp: Date)] = []
        for entry in flow.orderedPayloads {
            chunkStarts.append((stream.count, entry.timestamp))
            stream.append(entry.payload)
        }
        var offset = 0
        var totalSkipped = 0
        while offset + LyraMeshPack.headerLength <= stream.count {
            let slice = stream.subdata(in: offset..<stream.count)
            do {
                let result = try LyraMeshPack.decode(slice)
                let ts = timestamp(forStreamOffset: offset, chunkStarts: chunkStarts)
                records.append(MeshFrameRecord(
                    timestamp: ts,
                    flowKey: flow.key,
                    frame: result.frame,
                    streamOffset: offset,
                    skippedBytesBefore: totalSkipped
                ))
                offset += result.consumedBytes
            } catch {
                offset += 1
                totalSkipped += 1
            }
        }
        return (records, stream.count - offset, totalSkipped)
    }

    private static func timestamp(forStreamOffset offset: Int, chunkStarts: [(streamOffset: Int, timestamp: Date)]) -> Date {
        var result = chunkStarts.first?.timestamp ?? Date(timeIntervalSince1970: 0)
        for chunk in chunkStarts where chunk.streamOffset <= offset {
            result = chunk.timestamp
        }
        return result
    }
}
