import Foundation

// lyra-server: a standalone virtual Xiaomi phone (lyra mesh endpoint +
// DevRepo oracle + sync task + TeleService relayCall) for local test loops.
//
//   lyra-server [--port 43181] [--identity phone.json] [--name "Xiaomi 15"]
//
// stdin commands:
//   ring <number>   simulate an incoming call (dials relayCall, sends ring)
//   idle            call_state_idle
//   sync <port>     run the reverse sync task against a Mac responder port
//   status          dump oracle records
//   quit

let args = CommandLine.arguments
var port: UInt16 = 43181
var identityURL = URL(fileURLWithPath: "lyra-phone.json")
var name = "Xiaomi 15 Ultra"

var index = 1
while index < args.count {
    switch args[index] {
    case "--port":
        index += 1
        if index < args.count { port = UInt16(args[index]) ?? port }
    case "--identity":
        index += 1
        if index < args.count { identityURL = URL(fileURLWithPath: args[index]) }
    case "--name":
        index += 1
        if index < args.count { name = args[index] }
    default:
        break
    }
    index += 1
}

let identity = LyraPhoneIdentity.loadOrGenerate(at: identityURL, displayName: name)
let phone = LyraPhoneServer(identity: identity)
phone.onEvent = { event in
    switch event {
    case .log(let text):
        print("[phone] \(text)")
    case .physSynced:
        print("[phone] phys synced")
    case .announceAuthenticated:
        print("[phone] announce authenticated")
    case .deviceUpdated(let record):
        print(
            "[phone] device \(record.device.deviceName) trustedType=\(record.trustedType) " +
                "online=\(record.online) reasons=\(record.rejectionReasons.joined(separator: "; "))"
        )
    case .relayCallState(let state):
        print("[phone] relayCall \(state)")
    case .syncTaskState(let state):
        print("[phone] syncTask \(state)")
    }
}

do {
    try phone.start(port: port)
    print("[phone] listening on mesh port \(phone.boundPort.map(String.init) ?? "?") as \(identity.displayName) (\(identity.deviceIdHex))")
} catch {
    print("[phone] failed to start: \(error)")
    exit(1)
}

DispatchQueue.global().async {
    while let line = readLine() {
        let parts = line.split(separator: " ").map(String.init)
        guard let command = parts.first else { continue }
        switch command {
        case "ring":
            let number = parts.count > 1 ? parts[1] : "0912345678"
            phone.simulateIncomingCall(number: number)
        case "idle":
            phone.relayCall.sendCallStateIdle()
        case "sync":
            let target = parts.count > 1 ? UInt16(parts[1]) ?? 0 : 0
            if target != 0 {
                phone.runSyncTask(host: "127.0.0.1", port: target)
            } else {
                print("usage: sync <mac-responder-port>")
            }
        case "status":
            for record in phone.oracle.records.values {
                print(
                    "[status] \(record.device.deviceName) online=\(record.online) " +
                        "trustedType=\(record.trustedType) services=\(record.device.services.map(\.name))"
                )
            }
        case "quit":
            exit(0)
        default:
            print("commands: ring <number> | idle | sync <port> | status | quit")
        }
    }
}

dispatchMain()
