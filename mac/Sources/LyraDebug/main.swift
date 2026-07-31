import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage
    case message(String)

    var description: String {
        switch self {
        case .usage: return Self.usageText
        case .message(let text): return text
        }
    }

    static let usageText = """
    lyra-debug — Lyra (Xiaomi HyperConnect) protocol analysis harness

    Usage:
      lyra-debug keys extract [--storage <path>] [--key-hex <hex>] [--out keys.json]
          Decrypt the official Mac storage.lyra identity store and export a keyring.
          Default storage: ~/Library/Caches/com.xiaomi.hyperConnect/storage.lyra
          Key source: --key-hex, else login keychain (com.xiaomi.hyperConnect.storage).

      lyra-debug keys merge <base.json> <extra.json> [--out merged.json]

      lyra-debug parse <capture.pcap|pcapng> [--keys keys.json] [--raw] [--flow <substr>]
          Reassemble KCP mesh streams, decode TransPackMesh / MiConnectFrame /
          LogiConn / PhysConn / payload-v2 / auth handshakes (all families),
          and attempt decryption with every key in the keyring.
          --raw also dumps non-KCP UDP datagrams. --flow filters flow keys.

      lyra-debug keyscan <capture.pcap> --dump-dir <dir> [--keys base.json] [--out keys.json] [--align N]
          Extract encrypted blobs from the capture, then sweep process-memory
          dumps (files named <base-hex>.bin) for 32-byte AES keys that open them
          (read-only GCM oracle). Hits are merged into the keyring.

      Exit status for `parse`: 0 if every auth handshake with sufficient key
      material passed (session key derived / blobs decrypted), 2 otherwise.
    """
}

struct CLIOptions {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    static func parse(_ args: [String]) -> CLIOptions {
        var options = CLIOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                    options.values[name] = args[index + 1]
                    index += 2
                } else {
                    options.flags.insert(name)
                    index += 1
                }
            } else {
                options.positional.append(arg)
                index += 1
            }
        }
        return options
    }
}

func main() throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        print(CLIError.usageText)
        return 1
    }
    let options = CLIOptions.parse(Array(args.dropFirst()))
    switch command {
    case "keys":
        return try runKeys(options)
    case "parse":
        return try runParse(options)
    case "keyscan":
        return try runKeyscan(options)
    case "help", "--help", "-h":
        print(CLIError.usageText)
        return 0
    default:
        print("unknown command: \(command)\n")
        print(CLIError.usageText)
        return 1
    }
}

func runKeys(_ options: CLIOptions) throws -> Int32 {
    guard let subcommand = options.positional.first else {
        print(CLIError.usageText)
        return 1
    }
    switch subcommand {
    case "extract":
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let storage = options.values["storage"] ?? "\(home)/Library/Caches/com.xiaomi.hyperConnect/storage.lyra"
        let (keyring, entries) = try LyraStoreExtractor.extract(storagePath: storage, keyHex: options.values["key-hex"])
        print("decrypted \(storage)")
        for (name, size) in entries {
            print("  \(name) (\(size)B)")
        }
        print("keyring: \(keyring.ticketKeys.count) tickets, \(keyring.identityPubKeys.count) identity pubs, \(keyring.identityPrivKeys.count) identity privs, \(keyring.uidHashes.count) uid hashes")
        let outPath = options.values["out"] ?? "lyra-keys.json"
        try keyring.save(path: outPath)
        print("wrote \(outPath)")
        return 0
    case "merge":
        guard options.positional.count >= 3 else {
            print("usage: lyra-debug keys merge <base.json> <extra.json> [--out merged.json]")
            return 1
        }
        var base = try Keyring.load(path: options.positional[1])
        let extra = try Keyring.load(path: options.positional[2])
        func merge(_ lhs: inout [KeyEntry], _ rhs: [KeyEntry]) {
            for entry in rhs where !lhs.contains(where: { $0.key == entry.key }) {
                lhs.append(entry)
            }
        }
        merge(&base.sessionKeys, extra.sessionKeys)
        merge(&base.ticketKeys, extra.ticketKeys)
        merge(&base.ephemeralPrivKeys, extra.ephemeralPrivKeys)
        merge(&base.identityPubKeys, extra.identityPubKeys)
        merge(&base.identityPrivKeys, extra.identityPrivKeys)
        merge(&base.uidHashes, extra.uidHashes)
        let outPath = options.values["out"] ?? options.positional[1]
        try base.save(path: outPath)
        print("wrote \(outPath)")
        return 0
    default:
        print("unknown keys subcommand: \(subcommand)")
        return 1
    }
}

func runKeyscan(_ options: CLIOptions) throws -> Int32 {
    guard let capturePath = options.positional.first, let dumpDir = options.values["dump-dir"] else {
        print("usage: lyra-debug keyscan <capture.pcap> --dump-dir <dir> [--keys base.json] [--out keys.json] [--align N]")
        return 1
    }
    let blobs = try KeyScanner.extractEncryptedBlobs(pcapPath: capturePath)
        .sorted { lhs, rhs in
            lhs.label.hasPrefix("encrypted_cred") && !rhs.label.hasPrefix("encrypted_cred")
        }
    print("extracted \(blobs.count) unique encrypted blobs from capture:")
    for blob in blobs.prefix(12) {
        print("  \(blob.label) (\(blob.blob.count)B)")
    }
    guard !blobs.isEmpty else { return 2 }
    let alignment = Int(options.values["align"] ?? "8") ?? 8
    let primaryCount = Int(options.values["primaries"] ?? "3") ?? 3
    var keyring = Keyring()
    if let base = options.values["keys"], FileManager.default.fileExists(atPath: base) {
        keyring = try Keyring.load(path: base)
    }
    let unsolved = blobs.filter { blob in
        !keyring.decryptionCandidates.contains(where: { LyraCrypto.aesGcmDecrypt(key: $0.key, blob: blob.blob) != nil })
    }
    print("\(unsolved.count) blob(s) not covered by existing keyring; using \(min(primaryCount, unsolved.count)) as primaries")
    let primaries = Array(unsolved.prefix(primaryCount))
    let found = KeyScanner.scan(dumpDir: dumpDir, primaries: primaries, alignment: alignment)
    guard !found.isEmpty else {
        print("no key found (try --align 1 for a full byte-level sweep, or --primaries higher)")
        return 2
    }
    for hit in found {
        keyring.addSessionKey(label: "memscan via \(hit.blob.label)", key: hit.key)
    }
    let outPath = options.values["out"] ?? options.values["keys"] ?? "lyra-keys.json"
    try keyring.save(path: outPath)
    print("added \(found.count) key(s) -> \(outPath)")
    return 0
}

func runParse(_ options: CLIOptions) throws -> Int32 {
    guard let capturePath = options.positional.first else {
        print(CLIError.usageText)
        return 1
    }
    var keyring = Keyring()
    if let keysPath = options.values["keys"] {
        keyring = try Keyring.load(path: keysPath)
        print("loaded keyring: \(keyring.decryptionCandidates.count) decryption candidates, \(keyring.ephemeralPrivKeys.count) ephemeral privkeys, \(keyring.identityPubKeys.count) identity pubs")
    }
    let packets = try PcapReader.read(path: capturePath)
    print("read \(packets.count) UDP packets from \(capturePath)")
    var flows = FlowAssembler.assemble(packets: packets)
    if let filter = options.values["flow"] {
        flows = flows.filter { $0.key.contains(filter) }
    }
    let analyzer = LyraAnalyzer(keyring: keyring)
    var allFrames: [MeshFrameRecord] = []
    var rawNotes: [String] = []
    let sortedKeys = flows.keys.sorted()
    for key in sortedKeys {
        guard let flow = flows[key] else { continue }
        if flow.sawKCP {
            let missing = flow.missingSNs
            let gapNote = missing.isEmpty ? "" : " MISSING SN: \(missing.prefix(10).map(String.init).joined(separator: ","))\(missing.count > 10 ? "…" : "")"
            rawNotes.append("flow \(key): KCP \(flow.pushCount) PUSH / \(flow.ackCount) ACK, \(flow.segments.count) unique segments\(gapNote)")
            let (frames, trailing, skipped) = MeshFrameSplitter.split(flow: flow)
            rawNotes.append("  -> \(frames.count) mesh frames, \(skipped) skipped bytes, \(trailing) trailing")
            allFrames.append(contentsOf: frames)
        } else if options.flags.contains("raw") {
            rawNotes.append("flow \(key): non-KCP, \(flow.rawDatagrams.count) datagrams")
            for datagram in flow.rawDatagrams {
                rawNotes.append("  \(LyraAnalyzer.timeFormatter.string(from: datagram.timestamp)) \(datagram.payload.hexString)")
            }
        }
    }
    allFrames.sort { $0.timestamp < $1.timestamp }
    for note in rawNotes {
        print(note)
    }
    print("--- frame stream (\(allFrames.count) frames) ---")
    for frame in allFrames {
        analyzer.analyzeFrame(frame, direction: frame.flowKey)
    }
    print(analyzer.out.lines.joined(separator: "\n"))
    let summary = analyzer.summary()
    print(summary)
    let handshakesComplete = analyzer.handshakes.values.filter { !$0.steps.isEmpty }
    let handshakesWithKeys = analyzer.handshakes.values.filter { $0.derivedSessionKey != nil }
    if analyzer.failedBlobCount > 0 {
        return 2
    }
    if !handshakesComplete.isEmpty, handshakesWithKeys.count < handshakesComplete.filter({ $0.clientPubKey != nil && $0.serverPubKey != nil }).count {
        return 2
    }
    return 0
}

do {
    let code = try main()
    exit(code)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
