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

struct CallRelayGatewayPlaybackStats: Equatable {
    let rtpPackets: Int
    let tsBytes: Int
    let pcmBytes: Int
    let totalPCMBytes: Int
    let pesPacketCount: Int
    let samples: Int
    let nonzeroSamples: Int
    let maxAbs: Int
    let averageAbs: Int
    let fingerprint: String
    let prefix: String

    var hasValidStream: Bool {
        totalPCMBytes >= 16_000 && nonzeroSamples > 0 && maxAbs >= 256
    }

    var diagnosticSummary: String {
        "rtpPackets=\(rtpPackets) tsBytes=\(tsBytes) pcmBytes=\(pcmBytes) pcmTotal=\(totalPCMBytes) " +
            "pes=\(pesPacketCount) samples=\(samples) nonzero=\(nonzeroSamples) " +
            "maxAbs=\(maxAbs) avgAbs=\(averageAbs) fp=\(fingerprint)"
    }
}

final class CallRelayGatewayClient: @unchecked Sendable {
    var onSourceStart: ((String) -> Void)?
    var onSourceStop: ((String) -> Void)?
    var onPlaybackStats: ((CallRelayGatewayPlaybackStats) -> Void)?

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
        if let stats = player.writeRTPPacket(packet) {
            onPlaybackStats?(stats)
        }
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
    private var errorOutput: FileHandle?
    private var devNull: FileHandle?
    private var rtpPackets = 0
    private var tsBytes = 0
    private var pcmBytes = 0
    private var pesPacketCount = 0
    private var stderrBytesLogged = 0
    private var validStreamReported = false

    func writeRTPPacket(_ packet: Data) -> CallRelayGatewayPlaybackStats? {
        guard let payload = rtpPayload(in: packet),
              payload.first == 0x47 else {
            return nil
        }
        rtpPackets += 1
        tsBytes += payload.count
        let pcmPayload = extractPhoneRelayPCM(fromMPEGTS: payload)
        guard !pcmPayload.isEmpty else {
            return nil
        }
        if process?.isRunning != true {
            start()
        }
        guard let input else {
            return nil
        }
        do {
            let previousPCMTotal = pcmBytes
            try input.write(contentsOf: pcmPayload)
            pcmBytes += pcmPayload.count
            let sampleStats = pcmS16LEStats(pcmPayload)
            let stats = CallRelayGatewayPlaybackStats(
                rtpPackets: rtpPackets,
                tsBytes: tsBytes,
                pcmBytes: pcmPayload.count,
                totalPCMBytes: pcmBytes,
                pesPacketCount: pesPacketCount,
                samples: sampleStats.samples,
                nonzeroSamples: sampleStats.nonzeroSamples,
                maxAbs: sampleStats.maxAbs,
                averageAbs: sampleStats.averageAbs,
                fingerprint: DiagnosticsLog.fingerprint(pcmPayload),
                prefix: hexPrefix(pcmPayload)
            )
            let isFirstValidStream = stats.hasValidStream && !validStreamReported
            if isFirstValidStream {
                validStreamReported = true
                DiagnosticsLog.info("callrelay.mac.gateway_pcm_valid \(stats.diagnosticSummary)")
            }
            let shouldLogStats = previousPCMTotal == 0 ||
                pcmBytes % 64_000 < pcmPayload.count ||
                isFirstValidStream
            if shouldLogStats {
                DiagnosticsLog.info(
                    "callrelay.mac.gateway_pcm_playback_write \(stats.diagnosticSummary) prefix=\(stats.prefix)"
                )
            }
            return stats
        } catch {
            DiagnosticsLog.error("callrelay.mac.gateway_rtp_write_failed", error)
            stop(reason: "write_failed")
            return nil
        }
    }

    func stop(reason: String) {
        if process != nil || input != nil {
            DiagnosticsLog.info(
                "callrelay.mac.gateway_player_stop reason=\(reason) " +
                    "rtpPackets=\(rtpPackets) tsBytes=\(tsBytes) pcmBytes=\(pcmBytes)"
            )
        }
        try? input?.close()
        input = nil
        errorOutput?.readabilityHandler = nil
        try? errorOutput?.close()
        errorOutput = nil
        process?.terminate()
        process = nil
        try? devNull?.close()
        devNull = nil
        rtpPackets = 0
        tsBytes = 0
        pcmBytes = 0
        pesPacketCount = 0
        stderrBytesLogged = 0
        validStreamReported = false
    }

    private func start() {
        guard let ffplay = Self.ffplayPath else {
            DiagnosticsLog.warn("callrelay.mac.gateway_player_unavailable ffplay_missing")
            return
        }
        let inputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffplay)
        process.arguments = [
            "-nodisp",
            "-loglevel", "warning",
            "-nostats",
            "-autoexit",
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-f", "s16le",
            "-ar", "8000",
            "-ch_layout", "mono",
            "-i", "pipe:0"
        ]
        process.standardInput = inputPipe
        process.standardError = errorPipe
        if let devNull = FileHandle(forWritingAtPath: "/dev/null") {
            self.devNull = devNull
            process.standardOutput = devNull
        }
        let output = errorPipe.fileHandleForReading
        output.readabilityHandler = { [weak self, weak output] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            guard let self, let output, self.errorOutput === output else {
                return
            }
            self.logPlayerStderr(data)
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            guard self?.process === terminatedProcess else {
                return
            }
            DiagnosticsLog.info("callrelay.mac.gateway_player_exit status=\(terminatedProcess.terminationStatus)")
            self?.errorOutput?.readabilityHandler = nil
        }
        do {
            try process.run()
            self.process = process
            input = inputPipe.fileHandleForWriting
            errorOutput = output
            DiagnosticsLog.info(
                "callrelay.mac.gateway_player_start ffplay=\(ffplay) " +
                    "format=s16le sampleRate=8000 channelLayout=mono"
            )
        } catch {
            output.readabilityHandler = nil
            try? output.close()
            DiagnosticsLog.error("callrelay.mac.gateway_player_start_failed", error)
        }
    }

    private func extractPhoneRelayPCM(fromMPEGTS payload: Data) -> Data {
        let bytes = Array(payload)
        var output = Data()
        var offset = 0
        while offset + Self.mpegTSPacketSize <= bytes.count {
            guard bytes[offset] == 0x47 else {
                offset += 1
                continue
            }
            let packetStart = offset
            let packetEnd = offset + Self.mpegTSPacketSize
            let payloadUnitStart = (bytes[packetStart + 1] & 0x40) != 0
            let pid = (UInt16(bytes[packetStart + 1] & 0x1f) << 8) | UInt16(bytes[packetStart + 2])
            let adaptationFieldControl = (bytes[packetStart + 3] >> 4) & 0x03
            var payloadStart = packetStart + 4

            if adaptationFieldControl == 2 || adaptationFieldControl == 3 {
                guard payloadStart < packetEnd else {
                    offset = packetEnd
                    continue
                }
                payloadStart += 1 + Int(bytes[payloadStart])
            }
            guard (adaptationFieldControl == 1 || adaptationFieldControl == 3),
                  pid == Self.phoneRelayAudioTSPID,
                  payloadStart < packetEnd else {
                offset = packetEnd
                continue
            }

            if payloadUnitStart,
               payloadStart + 9 <= packetEnd,
               bytes[payloadStart] == 0x00,
               bytes[payloadStart + 1] == 0x00,
               bytes[payloadStart + 2] == 0x01 {
                let headerLength = Int(bytes[payloadStart + 8])
                let pcmStart = payloadStart + 9 + headerLength
                if pcmStart < packetEnd {
                    output.append(contentsOf: bytes[pcmStart..<packetEnd])
                    pesPacketCount += 1
                }
            } else {
                output.append(contentsOf: bytes[payloadStart..<packetEnd])
            }
            offset = packetEnd
        }
        return output
    }

    private func pcmS16LEStats(_ data: Data) -> (samples: Int, nonzeroSamples: Int, maxAbs: Int, averageAbs: Int) {
        let bytes = Array(data)
        var sampleCount = 0
        var nonzeroSamples = 0
        var maxAbs = 0
        var absTotal = 0
        var index = 0
        while index + 1 < bytes.count {
            let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            let sample = Int(Int16(bitPattern: raw))
            let magnitude = abs(sample)
            sampleCount += 1
            if sample != 0 {
                nonzeroSamples += 1
            }
            maxAbs = max(maxAbs, magnitude)
            absTotal += magnitude
            index += 2
        }
        return (
            samples: sampleCount,
            nonzeroSamples: nonzeroSamples,
            maxAbs: maxAbs,
            averageAbs: sampleCount > 0 ? absTotal / sampleCount : 0
        )
    }

    private func hexPrefix(_ data: Data, count: Int = 16) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined()
    }

    private func logPlayerStderr(_ data: Data) {
        guard stderrBytesLogged < Self.stderrLogLimitBytes else {
            return
        }
        let remaining = Self.stderrLogLimitBytes - stderrBytesLogged
        let chunk = data.prefix(remaining)
        stderrBytesLogged += chunk.count
        let text = String(decoding: chunk, as: UTF8.self)
        DiagnosticsLog.warn("callrelay.mac.gateway_player_stderr preview=\(sanitizeLogValue(text))")
        if stderrBytesLogged >= Self.stderrLogLimitBytes {
            DiagnosticsLog.warn("callrelay.mac.gateway_player_stderr_truncated bytes=\(stderrBytesLogged)")
        }
    }

    private func sanitizeLogValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
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

    private static let mpegTSPacketSize = 188
    private static let phoneRelayAudioTSPID: UInt16 = 0x1100
    private static let stderrLogLimitBytes = 4 * 1024
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
