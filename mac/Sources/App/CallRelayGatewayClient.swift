import CryptoKit
import EdgeLinkKit
import Foundation
import Network

struct CallRelayGatewaySession: Equatable {
    let sessionId: String
    let relayHost: String
    let relayPort: Int
    let sinkRtpPort: Int
    let sourceRtpPort: Int
    let expiresAt: Int64

    func isFresh(now: Date = Date()) -> Bool {
        Int64(now.timeIntervalSince1970) < expiresAt - 15
    }
}

final class CallRelayGatewayClient: @unchecked Sendable {
    var onSourceStart: ((String) -> Void)?
    var onSourceStop: ((String) -> Void)?

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "EdgeLink.CallRelayGatewayClient")
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pendingSessionContinuation: CheckedContinuation<CallRelayGatewaySession, Error>?
    private var currentSession: CallRelayGatewaySession?
    private let player = CallRelayMPEGTSPlayer()

    init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func startSession(identity: LocalIdentity) async throws -> CallRelayGatewaySession {
        if let currentSession, currentSession.isFresh(), connection != nil {
            DiagnosticsLog.info(
                "callrelay.mac.gateway_reuse sessionId=\(currentSession.sessionId) " +
                    "endpoint=\(currentSession.relayHost):\(currentSession.relayPort)"
            )
            return currentSession
        }

        close(reason: "start_new_session")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.pendingSessionContinuation = continuation
                    self.open(identity: identity)
                }
            }
        } onCancel: {
            self.close(reason: "cancelled")
        }
    }

    func close(reason: String) {
        queue.async {
            DiagnosticsLog.info("callrelay.mac.gateway_close reason=\(reason)")
            self.onSourceStop?(reason)
            self.pendingSessionContinuation?.resume(throwing: CancellationError())
            self.pendingSessionContinuation = nil
            self.currentSession = nil
            self.receiveBuffer.removeAll(keepingCapacity: true)
            self.connection?.cancel()
            self.connection = nil
            self.player.stop(reason: reason)
        }
    }

    func sendSourceRTPPacket(_ packet: Data) {
        queue.async {
            do {
                try self.sendJSON([
                    "t": "source.rtp",
                    "b": [
                        "bytes": packet.count,
                        "data": packet.base64EncodedString()
                    ]
                ])
            } catch {
                DiagnosticsLog.error("callrelay.mac.gateway_source_rtp_send_failed", error)
            }
        }
    }

    private func open(identity: LocalIdentity) {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, self.connection === connection else {
                return
            }
            switch state {
            case .ready:
                DiagnosticsLog.info("callrelay.mac.gateway_connected endpoint=\(self.host):\(self.port)")
                self.sendHello(identity: identity)
                self.receive()
            case .failed(let error):
                self.failPending(error)
                self.close(reason: "connection_failed")
            case .cancelled:
                self.failPending(CancellationError())
            default:
                break
            }
        }
        DiagnosticsLog.info("callrelay.mac.gateway_connect_start endpoint=\(host):\(port)")
        connection.start(queue: queue)
    }

    private func sendHello(identity: LocalIdentity) {
        do {
            let timestamp = Int64(Date().timeIntervalSince1970)
            let signature = try identity.signingKey.signature(
                for: RelayAuth.message(deviceId: identity.deviceId, timestampSeconds: timestamp)
            )
            try sendJSON([
                "t": "hello",
                "b": [
                    "version": 1,
                    "deviceId": identity.deviceId,
                    "ts": timestamp,
                    "sig": signature.base64EncodedString()
                ]
            ])
        } catch {
            failPending(error)
            close(reason: "hello_failed")
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.drainLines()
                }
                if let error {
                    DiagnosticsLog.warn("callrelay.mac.gateway_receive_failed error=\(error)")
                    self.failPending(error)
                    self.close(reason: "receive_failed")
                    return
                }
                if isComplete {
                    self.close(reason: "remote_closed")
                    return
                }
                self.receive()
            }
        }
    }

    private func drainLines() {
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer[..<newlineIndex]
            receiveBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else {
                continue
            }
            handleLine(Data(lineData))
        }
    }

    private func handleLine(_ line: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["t"] as? String,
            let body = object["b"] as? [String: Any]
        else {
            DiagnosticsLog.warn("callrelay.mac.gateway_bad_message")
            return
        }

        switch type {
        case "session.ready":
            handleSessionReady(body)
        case "rtp.in":
            handleRTPIn(body)
        case "source.destination":
            DiagnosticsLog.info(
                "callrelay.mac.gateway_source_destination host=\(body["host"] ?? "unknown") " +
                    "port=\(body["port"] ?? "unknown")"
            )
        case "source.start":
            let reason = body["reason"] as? String ?? "unknown"
            DiagnosticsLog.info("callrelay.mac.gateway_source_start reason=\(reason)")
            onSourceStart?(reason)
        case "source.stop":
            let reason = body["reason"] as? String ?? "unknown"
            DiagnosticsLog.info("callrelay.mac.gateway_source_stop reason=\(reason)")
            onSourceStop?(reason)
        case "rtsp.log":
            DiagnosticsLog.info("callrelay.mac.gateway_rtsp \(body)")
        case "error":
            let message = body["error"] as? String ?? "unknown"
            failPending(CallRelayGatewayError.server(message))
        default:
            break
        }
    }

    private func handleSessionReady(_ body: [String: Any]) {
        guard
            let sessionId = body["sessionId"] as? String,
            let relayHost = body["relayHost"] as? String,
            let relayPort = Self.intValue(body["relayPort"]),
            let sinkRtpPort = Self.intValue(body["sinkRtpPort"]),
            let sourceRtpPort = Self.intValue(body["sourceRtpPort"]),
            let expiresAt = Self.int64Value(body["expiresAt"])
        else {
            failPending(CallRelayGatewayError.invalidSession)
            return
        }
        let session = CallRelayGatewaySession(
            sessionId: sessionId,
            relayHost: relayHost,
            relayPort: relayPort,
            sinkRtpPort: sinkRtpPort,
            sourceRtpPort: sourceRtpPort,
            expiresAt: expiresAt
        )
        currentSession = session
        DiagnosticsLog.info(
            "callrelay.mac.gateway_session_ready sessionId=\(sessionId) " +
                "endpoint=\(relayHost):\(relayPort) sinkRtp=\(sinkRtpPort) sourceRtp=\(sourceRtpPort)"
        )
        pendingSessionContinuation?.resume(returning: session)
        pendingSessionContinuation = nil
    }

    private func handleRTPIn(_ body: [String: Any]) {
        guard let dataText = body["data"] as? String,
              let packet = Data(base64Encoded: dataText) else {
            return
        }
        player.writeRTPPacket(packet)
    }

    private func sendJSON(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CallRelayGatewayError.invalidJSON
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error {
                DiagnosticsLog.warn("callrelay.mac.gateway_send_failed error=\(error)")
            }
        })
    }

    private func failPending(_ error: Error) {
        pendingSessionContinuation?.resume(throwing: error)
        pendingSessionContinuation = nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        return nil
    }
}

private final class CallRelayMPEGTSPlayer {
    private var process: Process?
    private var input: FileHandle?
    private var devNull: FileHandle?
    private var packets = 0
    private var payloadBytes = 0

    func writeRTPPacket(_ packet: Data) {
        guard let payload = rtpPayload(in: packet), !payload.isEmpty else {
            return
        }
        if process?.isRunning != true {
            start()
        }
        guard let input else {
            return
        }
        do {
            try input.write(contentsOf: payload)
            packets += 1
            payloadBytes += payload.count
            if packets == 1 || packets % 100 == 0 {
                DiagnosticsLog.info("callrelay.mac.gateway_rtp_playback packets=\(packets) payloadBytes=\(payloadBytes)")
            }
        } catch {
            DiagnosticsLog.error("callrelay.mac.gateway_rtp_write_failed", error)
            stop(reason: "write_failed")
        }
    }

    func stop(reason: String) {
        if process != nil || input != nil {
            DiagnosticsLog.info("callrelay.mac.gateway_player_stop reason=\(reason) packets=\(packets) payloadBytes=\(payloadBytes)")
        }
        try? input?.close()
        input = nil
        process?.terminate()
        process = nil
        try? devNull?.close()
        devNull = nil
        packets = 0
        payloadBytes = 0
    }

    private func start() {
        guard let ffplay = Self.ffplayPath else {
            DiagnosticsLog.warn("callrelay.mac.gateway_player_unavailable ffplay_missing")
            return
        }
        let inputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffplay)
        process.arguments = [
            "-nodisp",
            "-autoexit",
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-probesize", "32",
            "-analyzeduration", "0",
            "-f", "mpegts",
            "-"
        ]
        process.standardInput = inputPipe
        if let devNull = FileHandle(forWritingAtPath: "/dev/null") {
            self.devNull = devNull
            process.standardOutput = devNull
            process.standardError = devNull
        }
        do {
            try process.run()
            self.process = process
            input = inputPipe.fileHandleForWriting
            DiagnosticsLog.info("callrelay.mac.gateway_player_start ffplay=\(ffplay)")
        } catch {
            DiagnosticsLog.error("callrelay.mac.gateway_player_start_failed", error)
        }
    }

    private func rtpPayload(in packet: Data) -> Data? {
        guard packet.count >= 12 else {
            return nil
        }
        let bytes = [UInt8](packet.prefix(min(packet.count, 20)))
        guard bytes[0] >> 6 == 2 else {
            return nil
        }
        let hasExtension = (bytes[0] & 0x10) != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        var offset = 12 + csrcCount * 4
        guard packet.count >= offset else {
            return nil
        }
        if hasExtension {
            guard packet.count >= offset + 4 else {
                return nil
            }
            let lengthOffset = packet.index(packet.startIndex, offsetBy: offset + 2)
            let length = (UInt16(packet[lengthOffset]) << 8) | UInt16(packet[packet.index(after: lengthOffset)])
            offset += 4 + Int(length) * 4
            guard packet.count >= offset else {
                return nil
            }
        }
        return Data(packet.dropFirst(offset))
    }

    private static var ffplayPath: String? {
        ["/opt/homebrew/bin/ffplay", "/usr/local/bin/ffplay", "/usr/bin/ffplay"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}

private enum CallRelayGatewayError: Error, CustomStringConvertible {
    case invalidJSON
    case invalidSession
    case server(String)

    var description: String {
        switch self {
        case .invalidJSON:
            return "Invalid JSON."
        case .invalidSession:
            return "Invalid call relay gateway session."
        case .server(let message):
            return "Call relay gateway error: \(message)"
        }
    }
}
