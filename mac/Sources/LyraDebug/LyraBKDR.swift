import Foundation

enum BKDRScanner {
    static let windowSize = 32
    static let seed: UInt32 = 131

    static func hash(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var h: UInt32 = 0
        for b in bytes { h = h &* seed &+ UInt32(b) }
        return h
    }

    private static let pow31: UInt32 = {
        var p: UInt32 = 1
        for _ in 0..<(windowSize - 1) { p &*= seed }
        return p
    }()

    struct Hit {
        let file: String
        let offset: Int
        let hash: UInt32
        let key: Data
    }

    static func scan(dumpDir: String, targets: Set<UInt32>, progress: Bool = true) -> [Hit] {
        guard !targets.isEmpty else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dumpDir))?.filter { $0.hasSuffix(".bin") }.sorted() ?? []
        var hits: [Hit] = []
        let lock = NSLock()
        let scanned = ManagedCounter()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let name = files[index]
            let path = (dumpDir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path), data.count >= windowSize else { return }
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var localHits: [Hit] = []
                var h: UInt32 = 0
                for i in 0..<windowSize { h = h &* seed &+ UInt32(bytes[i]) }
                if targets.contains(h) {
                    localHits.append(Hit(file: name, offset: 0, hash: h, key: Data(bytes[0..<windowSize])))
                }
                if bytes.count > windowSize {
                    for i in 1...(bytes.count - windowSize) {
                        h = (h &- UInt32(bytes[i - 1]) &* pow31) &* seed &+ UInt32(bytes[i + windowSize - 1])
                        if targets.contains(h) {
                            localHits.append(Hit(file: name, offset: i, hash: h, key: Data(bytes[i..<(i + windowSize)])))
                        }
                    }
                }
                if !localHits.isEmpty {
                    lock.lock()
                    hits.append(contentsOf: localHits)
                    lock.unlock()
                }
                scanned.increment()
            }
        }
        if progress {
            print("bkdr-scanned \(files.count) regions for \(targets.count) target hash(es): \(hits.count) raw candidate(s)")
        }
        return hits
    }

    static func transKeyHashes(fromLogcat path: String) -> Set<UInt32> {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"trans_key=(\d+)"#)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out = Set<UInt32>()
        for match in regex.matches(in: text, range: range) {
            if let valueRange = Range(match.range(at: 1), in: text), let value = UInt32(text[valueRange]) {
                out.insert(value)
            }
        }
        return out
    }
}
