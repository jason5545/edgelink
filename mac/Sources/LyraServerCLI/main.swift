import EdgeLinkKit
import Foundation

// lyra-server: a standalone virtual Xiaomi phone (lyra mesh endpoint +
// DevRepo oracle + sync task + TeleService relayCall) for local test loops.
//
//   lyra-server [--port 43181] [--identity phone.json] [--name "Xiaomi 15"]
//
// Relay mode (EdgeLink secure channel over the Cloudflare worker, same
// registration + relay.auth + handshake the real Mac app speaks):
//
//   lyra-server --worker https://edgelink-worker.black-hill-f944.workers.dev \
//     --role client --host-id <mac-device-id> --peer-pk <host-pk-b64> \
//     [--dev-secret <secret>] [--relay-identity relay-identity.json]
//
//   lyra-server --worker <url> --role host --peer-pk <client-pk-b64>
//   lyra-server --worker <url> --register-only [--relay-identity x.json]
//
// stdin commands:
//   ring <number>   simulate an incoming call (dials relayCall, sends ring)
//   idle            call_state_idle
//   sync <port>     run the reverse sync task against a Mac responder port
//   ping            (relay mode) send status.ping, prints RTT on pong
//   say <text>      (relay mode) send a debug.echo envelope to the peer
//   status          dump oracle records
//   quit

struct EchoBody: Codable, Sendable {
    let text: String
}

setvbuf(stdout, nil, _IONBF, 0)

final class RelayModeBox: @unchecked Sendable {
    var session: LyraRelaySession?
}

let args = CommandLine.arguments
var port: UInt16 = 43181
var identityURL = URL(fileURLWithPath: "lyra-phone.json")
var name = "Xiaomi 15 Ultra"
var workerArg: String?
var roleArg = "client"
var hostIdArg: String?
var peerPkArg: String?
var devSecretArg: String?
var hostNameArg: String?
var relayIdentityURL = URL(fileURLWithPath: "relay-identity.json")
var registerOnly = false
var meshEnabled = true

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
    case "--worker":
        index += 1
        if index < args.count { workerArg = args[index] }
    case "--role":
        index += 1
        if index < args.count { roleArg = args[index] }
    case "--host-id":
        index += 1
        if index < args.count { hostIdArg = args[index] }
    case "--peer-pk":
        index += 1
        if index < args.count { peerPkArg = args[index] }
    case "--dev-secret":
        index += 1
        if index < args.count { devSecretArg = args[index] }
    case "--host-name":
        index += 1
        if index < args.count { hostNameArg = args[index] }
    case "--relay-identity":
        index += 1
        if index < args.count { relayIdentityURL = URL(fileURLWithPath: args[index]) }
    case "--register-only":
        registerOnly = true
    case "--no-mesh":
        meshEnabled = false
    default:
        break
    }
    index += 1
}

let relayBox = RelayModeBox()

if let workerArg {
    guard let workerBaseURL = URL(string: workerArg) else {
        print("[relay] invalid --worker URL")
        exit(1)
    }
    let platform = roleArg == "host" ? "macos" : "android"
    let store = LyraRelayIdentityStore(url: relayIdentityURL)
    let registrar = WorkerDeviceRegistrar(baseURL: workerBaseURL)

    Task {
        do {
            let identity = try await store.loadOrRegister(
                registrar: registrar,
                name: name,
                platform: platform
            )
            print(
                "[relay] registered deviceId=\(identity.deviceId) " +
                    "pk=\(identity.publicKey.base64EncodedString()) platform=\(platform)"
            )
            if registerOnly {
                exit(0)
            }

            guard let peerPkArg, let peerPk = Data(base64Encoded: peerPkArg), peerPk.count == 32 else {
                print("[relay] --peer-pk <base64-32B> is required in relay mode")
                exit(1)
            }
            let hostId: String
            if roleArg == "host" {
                hostId = identity.deviceId
            } else {
                guard let hostIdArg else {
                    print("[relay] --host-id is required for --role client")
                    exit(1)
                }
                hostId = hostIdArg
            }

            if roleArg == "client", let devSecretArg {
                try await LyraDevPairClient(workerBaseURL: workerBaseURL).pair(
                    secret: devSecretArg,
                    hostId: hostId,
                    hostPk: peerPk,
                    hostName: hostNameArg ?? "dev-host",
                    clientId: identity.deviceId,
                    clientPk: identity.publicKey,
                    clientName: identity.name
                )
                print("[relay] dev-paired hostId=\(hostId) clientId=\(identity.deviceId)")
            }

            guard var components = URLComponents(url: workerBaseURL, resolvingAgainstBaseURL: false) else {
                print("[relay] invalid --worker URL")
                exit(1)
            }
            components.scheme = components.scheme == "http" ? "ws" : "wss"
            components.path = "/v1/connect"
            guard let connectURL = components.url else {
                print("[relay] invalid --worker URL")
                exit(1)
            }

            let channel = try await LyraRelayChannel.connect(
                endpoint: connectURL,
                hostId: hostId,
                identity: identity,
                log: { print("[relay] \($0)") }
            )
            let session = LyraRelaySession(
                channel: channel,
                identity: identity,
                log: { print("[relay] \($0)") },
                onEnvelope: { type, plaintext in
                    if type == "debug.echo",
                       let echo = try? JSONDecoder().decode(Envelope<EchoBody>.self, from: plaintext) {
                        print("[relay] echo: \(echo.b.text)")
                    } else if type != EnvelopeType.statusPing && type != EnvelopeType.statusPong {
                        print("[relay] envelope \(type) bytes=\(plaintext.count)")
                    }
                },
                onPong: { rttMs, offsetMs in
                    print("[relay] pong rttMs=\(rttMs) offsetMs=\(offsetMs)")
                }
            )
            relayBox.session = session

            if roleArg == "host" {
                try await session.acceptAsHost(pinnedClientPublicKey: peerPk)
                print("[relay] secure session established (host role)")
            } else {
                try await session.connectAsClient(pinnedHostPublicKey: peerPk)
                print("[relay] secure session established (client role)")
            }

            do {
                try await session.receiveLoop()
            } catch {
                print("[relay] receive loop ended: \(error)")
            }
        } catch {
            print("[relay] failed: \(error)")
        }
    }
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

if meshEnabled {
    do {
        try phone.start(port: port)
        print("[phone] listening on mesh port \(phone.boundPort.map(String.init) ?? "?") as \(identity.displayName) (\(identity.deviceIdHex))")
    } catch {
        print("[phone] failed to start: \(error)")
        exit(1)
    }
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
        case "ping":
            guard let session = relayBox.session else {
                print("[relay] not in relay mode")
                continue
            }
            Task {
                do {
                    try await session.sendPing()
                } catch {
                    print("[relay] ping failed: \(error)")
                }
            }
        case "say":
            let text = parts.dropFirst().joined(separator: " ")
            guard let session = relayBox.session else {
                print("[relay] not in relay mode")
                continue
            }
            Task {
                do {
                    try await session.sendEnvelope("debug.echo", EchoBody(text: text))
                } catch {
                    print("[relay] say failed: \(error)")
                }
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
            print("commands: ring <number> | idle | sync <port> | ping | say <text> | status | quit")
        }
    }
}

dispatchMain()
