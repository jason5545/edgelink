import CryptoKit
import Foundation

struct ProtoField {
    let number: Int
    let wireType: Int
    let varintValue: UInt64?
    let bytesValue: Data?

    var asString: String? {
        guard let bytesValue, !bytesValue.isEmpty,
              let string = String(data: bytesValue, encoding: .utf8),
              string.allSatisfy({ $0.isASCII && !$0.isControlCharacter || $0 == " " }) else { return nil }
        return string
    }
}

enum Proto {
    static func fields(_ data: Data) -> [ProtoField]? {
        var out: [ProtoField] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let tag = readVarint(data, &index) else { return nil }
            let number = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            guard number > 0 else { return nil }
            switch wireType {
            case 0:
                guard let value = readVarint(data, &index) else { return nil }
                out.append(ProtoField(number: number, wireType: wireType, varintValue: value, bytesValue: nil))
            case 1:
                guard data.endIndex - index >= 8 else { return nil }
                out.append(ProtoField(number: number, wireType: wireType, varintValue: nil, bytesValue: Data(data[index..<(index + 8)])))
                index += 8
            case 2:
                guard let length = readVarint(data, &index) else { return nil }
                let end = index + Int(length)
                guard end <= data.endIndex else { return nil }
                out.append(ProtoField(number: number, wireType: wireType, varintValue: nil, bytesValue: Data(data[index..<end])))
                index = end
            case 5:
                guard data.endIndex - index >= 4 else { return nil }
                out.append(ProtoField(number: number, wireType: wireType, varintValue: nil, bytesValue: Data(data[index..<(index + 4)])))
                index += 4
            default:
                return nil
            }
        }
        return out
    }

    static func readVarint(_ data: Data, _ index: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { return nil }
        }
        return nil
    }

    static func varint(_ fields: [ProtoField], _ number: Int) -> UInt64? {
        fields.first(where: { $0.number == number && $0.wireType == 0 })?.varintValue
    }

    static func bytes(_ fields: [ProtoField], _ number: Int) -> Data? {
        fields.first(where: { $0.number == number && $0.wireType == 2 })?.bytesValue
    }

    static func allBytes(_ fields: [ProtoField], _ number: Int) -> [Data] {
        fields.filter { $0.number == number && $0.wireType == 2 }.compactMap(\.bytesValue)
    }
}

extension Character {
    var isControlCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return CharacterSet.controlCharacters.contains(scalar)
    }
}

struct Dump {
    var lines: [String] = []
    private var depth = 0

    mutating func line(_ text: String) {
        lines.append(String(repeating: "  ", count: depth) + text)
    }

    mutating func section(_ title: String, _ body: (inout Dump) -> Void) {
        line(title)
        depth += 1
        body(&self)
        depth -= 1
    }

    mutating func hex(_ label: String, _ data: Data, maxBytes: Int = 64) {
        let shown: String
        if data.count > maxBytes {
            shown = data.prefix(maxBytes).hexString + "…(\(data.count)B)"
        } else {
            shown = data.hexString
        }
        line("\(label): \(shown)")
    }
}

enum LyraNames {
    static func packType(_ type: UInt8) -> String {
        switch type {
        case 1: return "PHYS"
        case 2: return "LOGI"
        case 3: return "AUTH"
        case 4: return "PAYLOAD"
        case 5: return "PAYLOAD_V2"
        case 6: return "TUNNEL"
        default: return "TYPE\(type)"
        }
    }

    static func innerFrameType(_ type: UInt64) -> String {
        switch type {
        case 1: return "LOGI_CONN_REQUEST"
        case 2: return "LOGI_CONN_RESPONSE"
        case 3: return "LOGI_CONN_RESPONSE_ACK"
        case 4: return "LOGI_CONN_DISCONNECT"
        case 5: return "LOGI_CONN_SYNC_INFO"
        case 6: return "LOGI_CONN_AUTH_HANDSHAKE"
        case 7: return "LOGI_CONN_UPGRADE/DATA"
        default: return "INNER_TYPE\(type)"
        }
    }

    static func handshakeFamily(_ family: UInt64) -> String {
        switch family {
        case 1: return "PasskeyPair"
        case 2: return "AccountPair"
        case 4: return "AuthHandshake"
        case 5: return "KeyAgree"
        case 6: return "AccountPair(v2)"
        default: return "family\(family)"
        }
    }

    static func handshakeMessageType(_ type: UInt64) -> String {
        switch type {
        case 1: return "ALERT"
        case 2: return "PASSKEY_ENTRY_PAIR"
        case 3: return "NUMERIC_COMPARISON"
        case 4: return "ACCOUNT"
        case 5: return "AUTH"
        case 6: return "KEY_AGREE"
        default: return "msgType\(type)"
        }
    }

    static func alertCode(_ code: UInt64) -> String {
        switch code {
        case 3: return "3(bad message type)"
        case 5: return "5(bad server notify)"
        case 101: return "101(INCORRECT_PIN_CODE)"
        case 201: return "201(NOT_SAME_ACCOUNT)"
        case 301: return "301(NOT_PAIRED)"
        default: return "\(code)"
        }
    }

    static func authStep(_ step: UInt64) -> String {
        switch step {
        case 1: return "client_notify"
        case 2: return "server_notify"
        case 3: return "client_finished"
        case 4: return "server_finished"
        default: return "step\(step)"
        }
    }

    static func passkeyStep(_ step: UInt64) -> String {
        switch step {
        case 1: return "client_notify"
        case 2: return "server_confirm"
        case 3: return "client_confirm"
        case 4: return "server_verify"
        case 5: return "client_verify"
        case 6: return "server_key_exchange"
        case 7: return "client_key_exchange"
        case 8: return "server_finished"
        default: return "msg\(step)"
        }
    }
}

struct HandshakeObservation {
    var family: UInt64 = 0
    var handshakeId: UInt64 = 0
    var flowPair: String = ""
    var steps: [String] = []
    var alerts: [String] = []
    var clientRandom: Data?
    var serverRandom: Data?
    var clientPubKey: Data?
    var serverPubKey: Data?
    var derivedZ: Data?
    var derivedSessionKey: Data?
    var derivedTicket: Data?
    var serverSigVerified: Bool?
    var clientSigVerified: Bool?
    var compareNumber: String?
    var pendingServerSig: (blob: Data, z: Data)?
    var pendingClientSig: (blob: Data, z: Data)?
}

final class LyraAnalyzer {
    var keyring: Keyring
    var handshakes: [String: HandshakeObservation] = [:]
    var handshakeOrder: [String] = []
    var decryptedBlobCount = 0
    var failedBlobCount = 0
    var out: Dump = Dump()

    init(keyring: Keyring) {
        self.keyring = keyring
    }

    private func handshakeKey(flowKey: String, id: UInt64) -> String {
        let parts = flowKey.components(separatedBy: ">")
        let pair = parts.count == 2 ? parts.sorted().joined(separator: "<>") : flowKey
        return "\(pair)#\(id)"
    }

    private func observation(for flowKey: String, id: UInt64) -> HandshakeObservation {
        let key = handshakeKey(flowKey: flowKey, id: id)
        if let existing = handshakes[key] { return existing }
        var fresh = HandshakeObservation()
        fresh.handshakeId = id
        fresh.flowPair = flowKey
        handshakes[key] = fresh
        handshakeOrder.append(key)
        return fresh
    }

    private func update(_ flowKey: String, _ id: UInt64, _ mutate: (inout HandshakeObservation) -> Void) {
        let key = handshakeKey(flowKey: flowKey, id: id)
        var value = observation(for: flowKey, id: id)
        mutate(&value)
        handshakes[key] = value
    }

    func analyzeFrame(_ record: MeshFrameRecord, direction: String) {
        let typeName = LyraNames.packType(record.frame.packType)
        let time = Self.timeFormatter.string(from: record.timestamp)
        out.section("[\(time)] \(direction) packType=\(record.frame.packType) \(typeName) len=\(record.frame.payload.count)") { dump in
            switch record.frame.packType {
            case 1:
                dumpMiConnect(record.frame.payload, flowKey: record.flowKey, dump: &dump)
            case 2, 3:
                dumpMiConnect(record.frame.payload, flowKey: record.flowKey, dump: &dump)
            case 5:
                dumpPayloadV2(record.frame.payload, flowKey: record.flowKey, dump: &dump)
            case 6:
                dump.hex("tunnel payload", record.frame.payload)
                dumpProtoGeneric(record.frame.payload, dump: &dump, depthLimit: 2)
            default:
                dump.hex("payload", record.frame.payload)
            }
        }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func analyzeChannelFlow(_ flow: KCPFlow) {
        for segment in flow.orderedPayloads {
            let time = Self.timeFormatter.string(from: segment.timestamp)
            let payload = segment.payload
            if LyraChannelPlane.isTLVFrame(payload) {
                out.section("[\(time)] \(flow.key) CHANNEL TLV sn=\(segment.sn)") { dump in
                    LyraChannelPlane.dumpTLVFrame(payload, dump: &dump)
                }
                continue
            }
            guard let fragment = LyraChannelPlane.parseFragment(payload) else {
                out.section("[\(time)] \(flow.key) CHANNEL raw sn=\(segment.sn)") { dump in
                    dump.hex("payload", payload, maxBytes: 64)
                }
                continue
            }
            let encrypted = LyraChannelPlane.encryptedFlags.contains(fragment.flags)
            out.section("[\(time)] \(flow.key) CHANNEL frag flags=\(String(fragment.flags, radix: 16)) off=\(fragment.offset) cnt=\(fragment.count) body=\(fragment.body.count)B sn=\(segment.sn)") { dump in
                if encrypted {
                    var opened = false
                    for candidate in keyring.decryptionCandidates {
                        if let plain = LyraCrypto.aesGcmDecrypt(key: candidate.key, blob: fragment.body) {
                            decryptedBlobCount += 1
                            opened = true
                            dump.line("decrypt OK key=\"\(candidate.label)\" (\(plain.count)B)")
                            if LyraChannelPlane.isTLVFrame(plain) {
                                LyraChannelPlane.dumpTLVFrame(plain, dump: &dump)
                            } else {
                                dump.hex("plaintext", plain, maxBytes: 96)
                                dumpProtoGeneric(plain, dump: &dump, depthLimit: 2)
                            }
                            break
                        }
                    }
                    if !opened {
                        failedBlobCount += 1
                        dump.hex("encrypted fragment NO KEY", fragment.body, maxBytes: 48)
                    }
                } else {
                    if LyraChannelPlane.isTLVFrame(fragment.body) {
                        LyraChannelPlane.dumpTLVFrame(fragment.body, dump: &dump)
                    } else {
                        dump.hex("body", fragment.body, maxBytes: 96)
                    }
                }
            }
        }
    }

    private func dumpMiConnect(_ payload: Data, flowKey: String, dump: inout Dump) {
        guard let top = Proto.fields(payload) else {
            dump.hex("unparsed MiConnectFrame", payload)
            return
        }
        if let version = Proto.varint(top, 1) {
            dump.line("version: \(version)")
        }
        for v0Data in Proto.allBytes(top, 2) {
            guard let v0 = Proto.fields(v0Data) else { continue }
            for logiData in Proto.allBytes(v0, 1) {
                dump.section("LogiConnFrame") { dump in
                    dumpLogiConn(logiData, flowKey: flowKey, dump: &dump)
                }
            }
            if let physData = Proto.bytes(v0, 2) {
                dump.section("PhysConnFrame") { dump in
                    dumpPhysConn(physData, dump: &dump)
                }
            }
        }
    }

    private func dumpPhysConn(_ data: Data, dump: inout Dump) {
        guard let fields = Proto.fields(data) else {
            dump.hex("unparsed phys", data)
            return
        }
        if let id = Proto.varint(fields, 1) { dump.line("phys_conn_id: \(String(id, radix: 16))") }
        if let role = Proto.varint(fields, 2) {
            dump.line("field2: \(role) \(role == 1 ? "(client)" : role == 2 ? "(server)" : "")")
        }
        for field in fields where field.wireType == 2 && field.number >= 3 {
            let name: String
            switch field.number {
            case 3: name = "sync_device_info_request"
            case 4: name = "sync_device_info_response"
            case 5: name = "update_device_info"
            case 6: name = "keep_alive_request"
            case 7: name = "keep_alive_response"
            case 8: name = "disconnect_request"
            case 9: name = "disconnect_response"
            default: name = "field\(field.number)"
            }
            guard let body = field.bytesValue else { continue }
            dump.section(name) { dump in
                switch field.number {
                case 3, 4:
                    dumpSyncDeviceInfo(body, dump: &dump)
                case 6, 7:
                    if let sub = Proto.fields(body) {
                        for entry in sub {
                            if let value = entry.varintValue {
                                dump.line("f\(entry.number): \(value)")
                            } else if let bytes = entry.bytesValue {
                                dump.hex("f\(entry.number)", bytes, maxBytes: 32)
                            }
                        }
                    } else {
                        dump.hex("raw", body, maxBytes: 32)
                    }
                case 8, 9:
                    if let sub = Proto.fields(body), let ms = Proto.varint(sub, 1) {
                        dump.line("unix_ms: \(ms) (\(Date(timeIntervalSince1970: TimeInterval(ms) / 1000)))")
                    } else {
                        dump.hex("raw", body, maxBytes: 32)
                    }
                default:
                    dumpProtoGeneric(body, dump: &dump, depthLimit: 2)
                }
            }
        }
    }

    private func dumpSyncDeviceInfo(_ data: Data, dump: inout Dump) {
        guard let fields = Proto.fields(data) else {
            dump.hex("unparsed sync info", data, maxBytes: 96)
            return
        }
        if let ts = Proto.varint(fields, 1) { dump.line("ts_ms: \(ts)") }
        if let deviceData = Proto.bytes(fields, 2), let device = Proto.fields(deviceData) {
            dump.section("DeviceInfo") { dump in
                for field in device {
                    switch field.number {
                    case 2: dump.line("device_id: \(field.asString ?? field.bytesValue?.hexString ?? "?")")
                    case 3: dump.line("f3: \(field.varintValue ?? 0)")
                    case 4: dump.line("uid_hash: \(field.asString ?? field.bytesValue?.hexString ?? "?")")
                    case 5: dump.line("device_type: \(field.varintValue ?? 0) \(deviceTypeName(field.varintValue ?? 0))")
                    case 6: dump.line("display_name: \(field.asString ?? "?")")
                    case 8: dump.line("os_version: \(field.asString ?? "?")")
                    case 9:
                        if let mediums = field.varintValue {
                            dump.line("conn_mediums: \(String(mediums, radix: 16))")
                        }
                    case 11: dump.line("rom_version: \(field.asString ?? "?")")
                    default:
                        if let value = field.varintValue {
                            dump.line("f\(field.number): \(value)")
                        } else if let bytes = field.bytesValue {
                            dump.hex("f\(field.number)", bytes, maxBytes: 24)
                        }
                    }
                }
            }
        }
        for field in fields where field.number >= 3 {
            if let value = field.varintValue {
                dump.line("f\(field.number): \(value)")
            } else if let bytes = field.bytesValue {
                if let sub = Proto.fields(bytes), !sub.isEmpty, field.number != 2 {
                    dump.section("f\(field.number)") { dump in
                        dumpProtoFields(sub, dump: &dump, depthLimit: 1)
                    }
                } else {
                    dump.hex("f\(field.number)", bytes, maxBytes: 32)
                }
            }
        }
    }

    private func deviceTypeName(_ type: UInt64) -> String {
        switch type {
        case 1: return "(phone)"
        case 14: return "(MacBook)"
        default: return ""
        }
    }

    private func dumpLogiConn(_ data: Data, flowKey: String, dump: inout Dump) {
        guard let fields = Proto.fields(data) else {
            dump.hex("unparsed logi", data, maxBytes: 96)
            return
        }
        let localNet = Proto.varint(fields, 1) ?? 0
        let remoteNet = Proto.varint(fields, 2) ?? 0
        let connId = Proto.varint(fields, 3) ?? 0
        let encrypted = (Proto.varint(fields, 4) ?? 0) != 0
        dump.line("conn=\(String(connId, radix: 16)) localNet=\(localNet) remoteNet=\(remoteNet) \(encrypted ? "ENCRYPTED" : "plain")")
        guard let inner = Proto.bytes(fields, 5) else { return }
        if encrypted {
            dumpEncryptedInner(inner, context: "logi conn \(String(connId, radix: 16))", flowKey: flowKey, dump: &dump)
        } else {
            dumpInnerFrame(inner, flowKey: flowKey, dump: &dump)
        }
    }

    private func dumpEncryptedInner(_ blob: Data, context: String, flowKey: String, dump: inout Dump) {
        for candidate in keyring.decryptionCandidates {
            if let plain = LyraCrypto.aesGcmDecrypt(key: candidate.key, blob: blob) {
                decryptedBlobCount += 1
                dump.line("decrypt OK key=\"\(candidate.label)\" (\(plain.count)B)")
                dumpInnerFrame(plain, flowKey: flowKey, dump: &dump)
                return
            }
        }
        failedBlobCount += 1
        dump.hex("encrypted inner (\(context)) NO KEY", blob, maxBytes: 48)
    }

    private func dumpPayloadV2(_ payload: Data, flowKey: String, dump: inout Dump) {
        guard payload.count >= 2 else {
            dump.hex("short payload-v2", payload)
            return
        }
        let netId = payload[payload.startIndex]
        let flag = payload[payload.startIndex + 1]
        let body = payload.subdata(in: (payload.startIndex + 2)..<payload.endIndex)
        dump.line("netId=\(netId) flag=\(flag)")
        if flag == 1 {
            for candidate in keyring.decryptionCandidates {
                if let plain = LyraCrypto.aesGcmDecrypt(key: candidate.key, blob: body) {
                    decryptedBlobCount += 1
                    dump.line("decrypt OK key=\"\(candidate.label)\" (\(plain.count)B)")
                    dump.hex("channel plaintext", plain, maxBytes: 96)
                    dumpProtoGeneric(plain, dump: &dump, depthLimit: 2)
                    return
                }
            }
            failedBlobCount += 1
            dump.hex("encrypted payload NO KEY", body, maxBytes: 48)
        } else {
            if let fields = Proto.fields(body) {
                dump.section("LogiConnFrame (plain)") { dump in
                    dumpLogiConn(body, flowKey: flowKey, dump: &dump)
                }
                _ = fields
            } else {
                dump.hex("raw", body, maxBytes: 96)
            }
        }
    }

    private func dumpInnerFrame(_ data: Data, flowKey: String, dump: inout Dump) {
        guard let fields = Proto.fields(data) else {
            dump.hex("non-proto inner (\(data.count)B)", data, maxBytes: 96)
            return
        }
        let frameType = Proto.varint(fields, 1) ?? 0
        dump.line("inner frame_type=\(frameType) \(LyraNames.innerFrameType(frameType))")
        for field in fields where field.wireType == 2 && field.number >= 2 {
            guard let body = field.bytesValue else { continue }
            switch field.number {
            case 2:
                dump.section("request") { dump in dumpLogiRequest(body, dump: &dump) }
            case 3:
                dump.section("response") { dump in dumpLogiResponse(body, dump: &dump) }
            case 4:
                dump.section("response_ack") { dump in dumpProtoGeneric(body, dump: &dump, depthLimit: 2) }
            case 5:
                dump.section("disconnect") { dump in dumpProtoGeneric(body, dump: &dump, depthLimit: 1) }
            case 6:
                dump.section("sync_info") { dump in dumpSyncInfo(body, flowKey: flowKey, dump: &dump) }
            case 7, 8:
                if let handled = tryDumpAuthHandshake(body, flowKey: flowKey, dump: &dump), handled {
                } else {
                    dump.section("field\(field.number)") { dump in
                        dump.hex("raw", body, maxBytes: 96)
                        dumpProtoGeneric(body, dump: &dump, depthLimit: 2)
                    }
                }
            default:
                dump.hex("field\(field.number)", body, maxBytes: 64)
            }
        }
        if frameType == 0, let first = fields.first, first.number == 1, first.wireType == 2 {
            dump.hex("opaque data", first.bytesValue ?? Data(), maxBytes: 96)
        }
    }

    private func dumpLogiRequest(_ data: Data, dump: inout Dump) {
        guard let fields = Proto.fields(data) else {
            dump.hex("unparsed request", data, maxBytes: 96)
            return
        }
        for field in fields {
            if let string = field.asString, field.wireType == 2 {
                dump.line("f\(field.number): \"\(string)\"")
            } else if let value = field.varintValue {
                dump.line("f\(field.number): \(value)")
            } else if let bytes = field.bytesValue {
                if field.number == 10, let sub = Proto.fields(bytes) {
                    dump.section("f10 RequestOfPeerPort") { dump in
                        if let channel = Proto.varint(sub, 1) { dump.line("channel_id: \(channel)") }
                        if let key = Proto.bytes(sub, 4) { dump.hex("trans_key", key) }
                        if let random = Proto.bytes(sub, 5) { dump.hex("random", random) }
                        for entry in sub where ![1, 4, 5].contains(entry.number) {
                            dump.line("f\(entry.number): \(entry.varintValue.map(String.init) ?? entry.bytesValue?.hexString ?? "?")")
                        }
                    }
                } else if let sub = Proto.fields(bytes), sub.count >= 2 {
                    dump.section("f\(field.number) (\(bytes.count)B)") { dump in
                        dumpProtoFields(sub, dump: &dump, depthLimit: 1)
                    }
                } else {
                    dump.hex("f\(field.number)", bytes, maxBytes: 48)
                }
            }
        }
    }

    private func dumpLogiResponse(_ data: Data, dump: inout Dump) {
        guard let fields = Proto.fields(data) else {
            dump.hex("unparsed response", data, maxBytes: 96)
            return
        }
        if let status = Proto.varint(fields, 1) { dump.line("status: \(status)") }
        for field in fields where field.number != 1 {
            if let bytes = field.bytesValue {
                dump.section("f\(field.number) (\(bytes.count)B)") { dump in
                    dumpProtoGeneric(bytes, dump: &dump, depthLimit: 2)
                }
            } else if let value = field.varintValue {
                dump.line("f\(field.number): \(value)")
            }
        }
    }

    private func dumpSyncInfo(_ data: Data, flowKey: String, dump: inout Dump) {
        guard let fields = Proto.fields(data) else {
            dump.hex("unparsed sync_info", data, maxBytes: 96)
            return
        }
        if let timeout = Proto.varint(fields, 1) { dump.line("timeout: \(timeout)") }
        if let trust = Proto.varint(fields, 2) {
            let label = trust == 48 ? "EVERY_ONE" : trust == 16 ? "SAME_ACCOUNT" : trust == 32 ? "PAIRED" : "?"
            dump.line("trustLevel: \(trust) (\(label))")
        }
        if let keyIndex = Proto.varint(fields, 3) { dump.line("key_index: \(keyIndex)") }
        if let serviceData = Proto.bytes(fields, 4), let service = String(data: serviceData, encoding: .utf8) {
            dump.line("service: \(service)")
        }
        if let uidFeature = Proto.bytes(fields, 5), let sub = Proto.fields(uidFeature) {
            dump.section("UidFeatureInfo") { dump in
                let nonce = Proto.bytes(sub, 1) ?? Data()
                let hash = Proto.bytes(sub, 2) ?? Data()
                dump.hex("nonce", nonce)
                dump.hex("hash", hash)
                for candidate in keyring.uidHashes {
                    if let uid = Data(hexString: candidate.key), LyraCrypto.sha256(nonce + uid) == hash {
                        dump.line("uid hash MATCHES \"\(candidate.label)\"")
                    }
                }
            }
        }
        if let encCred = Proto.bytes(fields, 6) {
            dump.section("encrypted_cred (\(encCred.count)B)") { dump in
                var opened = false
                for candidate in keyring.decryptionCandidates {
                    if let plain = LyraCrypto.aesGcmDecrypt(key: candidate.key, blob: encCred) {
                        decryptedBlobCount += 1
                        opened = true
                        dump.line("decrypt OK key=\"\(candidate.label)\"")
                        dumpTrustedGroupInfo(plain, dump: &dump)
                        break
                    }
                }
                if !opened {
                    failedBlobCount += 1
                    dump.line("NO KEY (in-memory session key; key_index refs DeviceKeyManager)")
                }
            }
        }
        if let quickConn = Proto.bytes(fields, 8) {
            dump.section("f8 quick-conn ConnRequestFrame (\(quickConn.count)B)") { dump in
                dumpProtoGeneric(quickConn, dump: &dump, depthLimit: 2)
            }
        }
    }

    private func dumpTrustedGroupInfo(_ data: Data, dump: inout Dump) {
        dump.hex("tdif raw", data, maxBytes: 128)
        guard let fields = Proto.fields(data) else {
            dump.hex("TrustedGroupInfoFrame unparsed", data, maxBytes: 96)
            return
        }
        if let bits = Proto.varint(fields, 1) {
            dump.line("trusted_type_bits: \(String(bits, radix: 2))")
        }
        let identityPubs = keyring.identityPub()
        for number in [2, 3, 5] {
            guard let cred = Proto.bytes(fields, number), let credFeature = Proto.fields(cred) else { continue }
            let typeName = number == 2 ? "type2" : number == 3 ? "type1" : "type8"
            dump.section("cred \(typeName)") { dump in
                let inner = Proto.bytes(credFeature, 3) ?? Proto.bytes(credFeature, 2)
                let sub = inner.flatMap { Proto.fields($0) } ?? credFeature
                let nonce = Proto.bytes(sub, 1) ?? Data()
                let sig = Proto.bytes(sub, 2) ?? Data()
                dump.hex("nonce", nonce)
                dump.hex("signature(DER)", sig, maxBytes: 80)
                for pub in identityPubs {
                    if LyraCrypto.verifyECDSA(derSignature: sig, publicKeyX963: pub.key, message: nonce) {
                        dump.line("signature VALID under \"\(pub.label)\"")
                    }
                }
            }
        }
    }

    private func tryDumpAuthHandshake(_ data: Data, flowKey: String, dump: inout Dump) -> Bool? {
        guard let fields = Proto.fields(data),
              let handshakeId = Proto.varint(fields, 1),
              let handshakeData = Proto.bytes(fields, 2),
              let handshake = Proto.fields(handshakeData)
        else { return nil }
        let family = Proto.varint(handshake, 1) ?? 0
        let messageType = Proto.varint(handshake, 2) ?? 0
        update(flowKey, handshakeId) { $0.family = family }
        dump.section("AuthHandshake id=\(handshakeId) family=\(family) \(LyraNames.handshakeFamily(family)) msg=\(messageType) \(LyraNames.handshakeMessageType(messageType))") { dump in
            if let alert = Proto.bytes(handshake, 3), let sub = Proto.fields(alert) {
                let code = Proto.varint(sub, 1) ?? 0
                let message = Proto.bytes(sub, 2).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                dump.line("ALERT \(LyraNames.alertCode(code)) \"\(message)\"")
                update(flowKey, handshakeId) { $0.alerts.append("\(code) \(message)") }
            }
            if let passkey = Proto.bytes(handshake, 4) {
                dumpPasskeyPair(passkey, flowKey: flowKey, handshakeId: handshakeId, dump: &dump)
            }
            if let numCmp = Proto.bytes(handshake, 5) {
                dump.section("NumericComparisonPair (dormant)") { dump in
                    dumpProtoGeneric(numCmp, dump: &dump, depthLimit: 2)
                }
            }
            if let account = Proto.bytes(handshake, 6) {
                dump.section("AccountPairFrame") { dump in
                    dumpStepFrame(account, flowKey: flowKey, handshakeId: handshakeId, kind: "account", dump: &dump)
                }
            }
            if let auth = Proto.bytes(handshake, 7) {
                dump.section("AuthFrame") { dump in
                    dumpStepFrame(auth, flowKey: flowKey, handshakeId: handshakeId, kind: "auth", dump: &dump)
                }
            }
            if let keyAgree = Proto.bytes(handshake, 8) {
                dump.section("KeyAgreeFrame") { dump in
                    dumpStepFrame(keyAgree, flowKey: flowKey, handshakeId: handshakeId, kind: "keyagree", dump: &dump)
                }
            }
        }
        return true
    }

    private func dumpPasskeyPair(_ data: Data, flowKey: String, handshakeId: UInt64, dump: inout Dump) {
        guard let fields = Proto.fields(data) else { return }
        let msgType = Proto.varint(fields, 1) ?? 0
        dump.line("passkey step=\(msgType) \(LyraNames.passkeyStep(msgType))")
        update(flowKey, handshakeId) { $0.steps.append(LyraNames.passkeyStep(msgType)) }
        for field in fields where field.wireType == 2 && field.number >= 2 {
            guard let body = field.bytesValue, let sub = Proto.fields(body) else { continue }
            switch field.number {
            case 2:
                dump.section("client_notify") { dump in
                    if let suites = Proto.bytes(sub, 1) {
                        dumpCipherSuites(suites, isServer: false, flowKey: flowKey, handshakeId: handshakeId, dump: &dump)
                    }
                }
            case 3:
                dump.section("server_confirm") { dump in
                    if let selected = Proto.bytes(sub, 1) {
                        dumpCipherSuites(selected, isServer: true, flowKey: flowKey, handshakeId: handshakeId, dump: &dump)
                    }
                    if let hmac = Proto.bytes(sub, 2) { dump.hex("H (HMAC-SHA256)", hmac) }
                }
            default:
                if let blob = Proto.bytes(sub, 1) {
                    dump.hex("\(LyraNames.passkeyStep(UInt64(field.number - 1))) blob", blob, maxBytes: 80)
                } else {
                    dumpProtoFields(sub, dump: &dump, depthLimit: 1)
                }
            }
        }
    }

    private func dumpStepFrame(_ data: Data, flowKey: String, handshakeId: UInt64, kind: String, dump: inout Dump) {
        guard let fields = Proto.fields(data) else { return }
        let step = Proto.varint(fields, 1) ?? 0
        dump.line("step=\(step) \(LyraNames.authStep(step))")
        update(flowKey, handshakeId) { $0.steps.append("\(kind):\(LyraNames.authStep(step))") }
        for field in fields where field.wireType == 2 && field.number >= 2 {
            guard let body = field.bytesValue, let sub = Proto.fields(body) else { continue }
            switch (step, field.number) {
            case (1, 2):
                dump.section("client_notify") { dump in
                    if let suites = Proto.bytes(sub, 1) {
                        dumpCipherSuites(suites, isServer: false, flowKey: flowKey, handshakeId: handshakeId, dump: &dump)
                    }
                    if let ext = Proto.bytes(sub, 3) { dump.hex("AuthExtParam", ext, maxBytes: 16) }
                }
            case (2, 3):
                dump.section("server_notify") { dump in
                    if let selected = Proto.bytes(sub, 1) {
                        dumpCipherSuites(selected, isServer: true, flowKey: flowKey, handshakeId: handshakeId, dump: &dump)
                    }
                    if let encSig = Proto.bytes(sub, 2) {
                        dump.hex("enc_sig", encSig, maxBytes: 48)
                        stashPendingSig(flowKey: flowKey, handshakeId: handshakeId, blob: encSig, isServer: true)
                    }
                    for extra in sub where extra.number >= 3 {
                        if let bytes = extra.bytesValue { dump.hex("f\(extra.number)", bytes, maxBytes: 24) }
                        else if let value = extra.varintValue { dump.line("f\(extra.number): \(value)") }
                    }
                }
            case (3, 4):
                dump.section("client_finished") { dump in
                    if let blob = Proto.bytes(sub, 1) {
                        dump.hex("client blob (encSig | pubkey+commitment)", blob, maxBytes: 64)
                        stashPendingSig(flowKey: flowKey, handshakeId: handshakeId, blob: blob, isServer: false)
                        verifyPendingSigs(flowKey: flowKey, handshakeId: handshakeId, dump: &dump)
                    }
                    for extra in sub where extra.number != 1 {
                        if let bytes = extra.bytesValue { dump.hex("f\(extra.number)", bytes, maxBytes: 48) }
                    }
                }
            case (4, 5):
                dump.section("server_finished") { dump in
                    if let blob = Proto.bytes(sub, 1) {
                        dump.hex("server_finished blob", blob, maxBytes: 64)
                    }
                }
                finalizeHandshake(flowKey: flowKey, handshakeId: handshakeId, dump: &dump)
            default:
                dump.section("f\(field.number)") { dump in
                    dumpProtoFields(sub, dump: &dump, depthLimit: 1)
                }
            }
        }
        if step == 2 {
            finalizeHandshake(flowKey: flowKey, handshakeId: handshakeId, dump: &dump)
        }
    }

    private func dumpCipherSuites(_ data: Data, isServer: Bool, flowKey: String, handshakeId: UInt64, dump: inout Dump) {
        guard let fields = Proto.fields(data) else { return }
        let title = isServer ? "SelectedCipherSuite" : "SupportedCipherSuites"
        dump.section(title) { dump in
            if let version = Proto.varint(fields, 1) { dump.line("version/sel: \(version)") }
            if let random = Proto.bytes(fields, 2) {
                dump.hex(isServer ? "server_random" : "client_random", random)
                update(flowKey, handshakeId) { obs in
                    if isServer { obs.serverRandom = random } else { obs.clientRandom = random }
                }
            }
            for number in [3, 4] {
                if let cipher = Proto.varint(fields, number) { dump.line("cipher\(number): \(cipher)") }
            }
            for pubData in Proto.allBytes(fields, 5) {
                if let pub = Proto.fields(pubData) {
                    let keyType = Proto.varint(pub, 1) ?? 0
                    let keyBytes = Proto.bytes(pub, 2) ?? Data()
                    dump.line("GenericPublicKey type=\(keyType) len=\(keyBytes.count)")
                    dump.hex("pub", keyBytes, maxBytes: 70)
                    if keyBytes.count == 65, keyBytes.first == 0x04 {
                        update(flowKey, handshakeId) { obs in
                            if isServer { obs.serverPubKey = keyBytes } else { obs.clientPubKey = keyBytes }
                        }
                    }
                }
            }
        }
    }

    private func stashPendingSig(flowKey: String, handshakeId: UInt64, blob: Data, isServer: Bool) {
        update(flowKey, handshakeId) { obs in
            if let z = obs.derivedZ {
                if isServer { obs.pendingServerSig = (blob, z) } else { obs.pendingClientSig = (blob, z) }
            } else {
                if isServer { obs.pendingServerSig = (blob, Data()) } else { obs.pendingClientSig = (blob, Data()) }
            }
        }
    }

    private func finalizeHandshake(flowKey: String, handshakeId: UInt64, dump: inout Dump) {
        let key = handshakeKey(flowKey: flowKey, id: handshakeId)
        guard var obs = handshakes[key], obs.derivedSessionKey == nil else { return }
        guard let clientRandom = obs.clientRandom, let serverRandom = obs.serverRandom,
              let clientPub = obs.clientPubKey, let serverPub = obs.serverPubKey else { return }
        for entry in keyring.ephemeralPrivKeys {
            guard let priv = Data(hexString: entry.key) else { continue }
            var z: Data?
            var ownedSide: String?
            if let candidate = LyraCrypto.ecdh(privateKeyData: priv, peerPublicKeyX963: serverPub),
               (try? pubFromRawPriv(priv)) == clientPub {
                z = candidate
                ownedSide = "client"
            } else if let candidate = LyraCrypto.ecdh(privateKeyData: priv, peerPublicKeyX963: clientPub),
                      (try? pubFromRawPriv(priv)) == serverPub {
                z = candidate
                ownedSide = "server"
            }
            guard let sharedZ = z, let side = ownedSide else { continue }
            let sessionKey = LyraCrypto.hkdf(ikm: sharedZ, salt: LyraCrypto.keyAgreeSessionSalt, info: clientRandom + serverRandom)
            let ticket = LyraCrypto.hkdf(ikm: sharedZ, salt: LyraCrypto.authTicketSalt, info: clientRandom + serverRandom)
            obs.derivedZ = sharedZ
            obs.derivedSessionKey = sessionKey
            obs.derivedTicket = ticket
            obs.compareNumber = LyraCrypto.compareNum(z: sharedZ, clientRandom: clientRandom, serverRandom: serverRandom)
            handshakes[key] = obs
            keyring.addSessionKey(label: "derived hs\(handshakeId) (\(side) eph \"\(entry.label)\")", key: sessionKey)
            keyring.ticketKeys.append(KeyEntry(label: "derived-ticket hs\(handshakeId)", key: ticket.hexString))
            dump.section("SESSION KEY DERIVED (hs\(handshakeId), \(side) ephemeral \"\(entry.label)\")") { dump in
                dump.hex("Z", sharedZ)
                dump.hex("session_key", sessionKey)
                dump.hex("ticket", ticket)
                if let compare = obs.compareNumber {
                    dump.line("compare_num: \(compare)")
                }
                verifyPendingSigs(flowKey: flowKey, handshakeId: handshakeId, dump: &dump)
            }
            return
        }
        handshakes[key] = obs
    }

    private func pubFromRawPriv(_ priv: Data) throws -> Data {
        try P256.Signing.PrivateKey(rawRepresentation: priv).publicKey.x963Representation
    }

    private func verifyPendingSigs(flowKey: String, handshakeId: UInt64, dump: inout Dump) {
        let key = handshakeKey(flowKey: flowKey, id: handshakeId)
        guard var obs = handshakes[key], let z = obs.derivedZ else { return }
        let identityPubs = keyring.identityPub()
        if let pending = obs.pendingServerSig, let plain = LyraCrypto.aesGcmDecrypt(key: z, blob: pending.blob) {
            dump.hex("server sig (decrypted DER)", plain, maxBytes: 80)
            if let serverPub = obs.serverPubKey, let clientPub = obs.clientPubKey {
                for pub in identityPubs {
                    if LyraCrypto.verifyECDSA(derSignature: plain, publicKeyX963: pub.key, message: serverPub + clientPub) {
                        obs.serverSigVerified = true
                        dump.line("server identity signature VALID under \"\(pub.label)\"")
                    }
                }
                if obs.serverSigVerified == nil { obs.serverSigVerified = false }
            }
            obs.pendingServerSig = nil
        }
        if let pending = obs.pendingClientSig, let plain = LyraCrypto.aesGcmDecrypt(key: z, blob: pending.blob) {
            dump.hex("client sig (decrypted DER)", plain, maxBytes: 80)
            if let serverPub = obs.serverPubKey, let clientPub = obs.clientPubKey {
                for pub in identityPubs {
                    if LyraCrypto.verifyECDSA(derSignature: plain, publicKeyX963: pub.key, message: clientPub + serverPub) {
                        obs.clientSigVerified = true
                        dump.line("client identity signature VALID under \"\(pub.label)\"")
                    }
                }
                if obs.clientSigVerified == nil { obs.clientSigVerified = false }
            }
            obs.pendingClientSig = nil
        }
        handshakes[key] = obs
    }

    private func dumpProtoGeneric(_ data: Data, dump: inout Dump, depthLimit: Int) {
        guard depthLimit > 0, let fields = Proto.fields(data) else {
            if !data.isEmpty { dump.hex("raw", data, maxBytes: 48) }
            return
        }
        dumpProtoFields(fields, dump: &dump, depthLimit: depthLimit)
    }

    private func dumpProtoFields(_ fields: [ProtoField], dump: inout Dump, depthLimit: Int) {
        for field in fields {
            if let value = field.varintValue {
                dump.line("f\(field.number): \(value)")
            } else if let bytes = field.bytesValue {
                if let string = field.asString, string.count >= 3 {
                    dump.line("f\(field.number): \"\(string)\"")
                } else if depthLimit > 1, let sub = Proto.fields(bytes), !sub.isEmpty {
                    dump.section("f\(field.number) (\(bytes.count)B)") { dump in
                        dumpProtoFields(sub, dump: &dump, depthLimit: depthLimit - 1)
                    }
                } else {
                    dump.hex("f\(field.number)", bytes, maxBytes: 32)
                }
            }
        }
    }

    func summary() -> String {
        var dump = Dump()
        dump.section("=== SUMMARY ===") { dump in
            dump.line("encrypted blobs: \(decryptedBlobCount) decrypted, \(failedBlobCount) without key")
            for key in handshakeOrder {
                guard let obs = handshakes[key] else { continue }
                dump.section("handshake \(obs.handshakeId) [\(LyraNames.handshakeFamily(obs.family))] \(obs.flowPair)") { dump in
                    dump.line("steps: \(obs.steps.joined(separator: " -> "))")
                    if !obs.alerts.isEmpty {
                        dump.line("ALERTS: \(obs.alerts.joined(separator: "; "))")
                    }
                    if obs.derivedSessionKey != nil {
                        dump.line("crypto: SESSION KEY DERIVED")
                        dump.line("server sig: \(obs.serverSigVerified.map { $0 ? "VALID" : "INVALID" } ?? "n/a")")
                        dump.line("client sig: \(obs.clientSigVerified.map { $0 ? "VALID" : "INVALID" } ?? "n/a")")
                        if let compare = obs.compareNumber {
                            dump.line("compare_num: \(compare)")
                        }
                    } else if obs.clientPubKey != nil && obs.serverPubKey != nil {
                        dump.line("crypto: both pubkeys seen but no matching ephemeral privkey in keyring")
                    } else {
                        dump.line("crypto: incomplete material (client random/pub: \(obs.clientRandom != nil)/\(obs.clientPubKey != nil), server: \(obs.serverRandom != nil)/\(obs.serverPubKey != nil))")
                    }
                }
            }
        }
        return dump.lines.joined(separator: "\n")
    }
}
