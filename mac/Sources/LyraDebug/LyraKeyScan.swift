import CryptoKit
import Foundation

enum KeyScanner {
    struct LabeledBlob {
        let label: String
        let blob: Data
    }

    static func extractEncryptedBlobs(pcapPath: String, limit: Int = 64) throws -> [LabeledBlob] {
        let packets = try PcapReader.read(path: pcapPath)
        let flows = FlowAssembler.assemble(packets: packets)
        var blobs: [LabeledBlob] = []
        var seen = Set<Data>()
        func add(_ label: String, _ blob: Data) {
            guard blob.count > 28, blobs.count < limit else { return }
            let hash = Data(SHA256.hash(data: blob))
            if seen.insert(hash).inserted {
                blobs.append(LabeledBlob(label: label, blob: blob))
            }
        }
        func walkLogiConn(_ data: Data, flow: String) {
            guard let fields = Proto.fields(data) else { return }
            let encrypted = (Proto.varint(fields, 4) ?? 0) != 0
            let connId = Proto.varint(fields, 3) ?? 0
            guard let inner = Proto.bytes(fields, 5) else { return }
            if encrypted {
                add("logi-enc conn=\(String(connId, radix: 16)) @\(flow)", inner)
                return
            }
            guard let innerFields = Proto.fields(inner) else { return }
            for field in innerFields where field.wireType == 2 {
                guard let body = field.bytesValue else { continue }
                if field.number == 6, let syncFields = Proto.fields(body), let encCred = Proto.bytes(syncFields, 6) {
                    add("encrypted_cred @\(flow)", encCred)
                }
            }
        }
        for key in flows.keys.sorted() {
            guard let flow = flows[key], flow.sawKCP else { continue }
            if LyraChannelPlane.looksLikeChannelFlow(flow) {
                for segment in flow.orderedPayloads {
                    if blobs.count >= limit { return blobs }
                    if let fragment = LyraChannelPlane.parseFragment(segment.payload),
                       LyraChannelPlane.encryptedFlags.contains(fragment.flags) {
                        add("channel-frag @\(key)", fragment.body)
                    }
                }
                continue
            }
            let (frames, _, _) = MeshFrameSplitter.split(flow: flow)
            for record in frames {
                if blobs.count >= limit { return blobs }
                switch record.frame.packType {
                case 2, 3:
                    guard let top = Proto.fields(record.frame.payload) else { continue }
                    for v0Data in Proto.allBytes(top, 2) {
                        guard let v0 = Proto.fields(v0Data) else { continue }
                        for logiData in Proto.allBytes(v0, 1) {
                            walkLogiConn(logiData, flow: key)
                        }
                    }
                case 5:
                    let payload = record.frame.payload
                    if payload.count > 2, payload[payload.startIndex + 1] == 1 {
                        add("payload-v2 @\(key)", payload.subdata(in: (payload.startIndex + 2)..<payload.endIndex))
                    }
                default:
                    continue
                }
            }
        }
        return blobs
    }

    static func scan(dumpDir: String, primaries: [LabeledBlob], alignment: Int = 8, progress: Bool = true) -> [(key: Data, blob: LabeledBlob)] {
        guard !primaries.isEmpty else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dumpDir))?.filter { $0.hasSuffix(".bin") }.sorted() ?? []
        var found: [(key: Data, blob: LabeledBlob)] = []
        let lock = NSLock()
        let nonzeroPages = ManagedCounter()
        let tested = ManagedCounter()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let path = (dumpDir as NSString).appendingPathComponent(files[index])
            guard let data = FileManager.default.contents(atPath: path) else { return }
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var page = 0
                while page < bytes.count {
                    let end = min(page + 4096, bytes.count)
                    var allZero = true
                    for i in page..<end where bytes[i] != 0 {
                        allZero = false
                        break
                    }
                    if !allZero {
                        nonzeroPages.increment()
                        var offset = page
                        while offset + 32 <= end {
                            let candidate = Data(bytes[offset..<(offset + 32)])
                            tested.increment()
                            for primary in primaries {
                                if let plain = LyraCrypto.aesGcmDecrypt(key: candidate, blob: primary.blob) {
                                    if let fields = Proto.fields(plain), !fields.isEmpty {
                                        lock.lock()
                                        if !found.contains(where: { $0.key == candidate }) {
                                            found.append((candidate, primary))
                                            FileHandle.standardOutput.write(Data("HIT \(files[index])@0x\(String(offset, radix: 16)) key=\(candidate.hexString) opens \"\(primary.label)\"\n".utf8))
                                        }
                                        lock.unlock()
                                    }
                                    break
                                }
                            }
                            offset += alignment
                        }
                    }
                    page += 4096
                }
            }
        }
        if progress {
            print("scanned \(files.count) regions, \(nonzeroPages.value) non-zero pages, \(tested.value) candidates (align \(alignment)) x \(primaries.count) primary blob(s)")
        }
        return found
    }
}

final class ManagedCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
